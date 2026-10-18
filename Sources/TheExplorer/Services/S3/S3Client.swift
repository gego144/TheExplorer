import CryptoKit
import Foundation
import UniformTypeIdentifiers

struct S3Bucket: Sendable, Hashable {
    var name: String
    var created: Date?
}

struct S3Object: Sendable, Hashable {
    var key: String
    var size: Int64
    var modified: Date?
    var storageClass: String?
}

struct S3Listing: Sendable {
    var prefixes: [String] = []
    var objects: [S3Object] = []
    var nextToken: String?
}

struct S3Error: LocalizedError, Sendable {
    var status: Int
    var code: String
    var message: String
    var region: String?

    var errorDescription: String? {
        switch code {
        case "AccessDenied": "Access denied. The credentials don't allow this (\(message))."
        case "InvalidAccessKeyId": "The access key isn't valid."
        case "SignatureDoesNotMatch": "The secret key doesn't match the access key."
        case "NoSuchBucket": "That bucket doesn't exist."
        case "ExpiredToken": "The credentials have expired. Sign in again (for SSO: aws sso login)."
        default: message.isEmpty ? "S3 returned \(code.isEmpty ? "HTTP \(status)" : code)." : message
        }
    }
}

/// Talks to S3 (or anything S3-compatible) directly over HTTPS, signing requests itself.
actor S3Client {
    struct Config: Sendable, Hashable {
        var region: String
        /// For S3-compatible services (R2, MinIO…); nil means AWS.
        var endpoint: URL?
    }

    /// Files over this size upload in parts, 4 at a time.
    static let multipartThreshold: Int64 = 64 << 20

    let config: Config
    private let credentialsProvider: @Sendable () async throws -> S3Credentials
    private var credentials: S3Credentials?
    /// Buckets that live in a different region than the connection's.
    private var bucketRegions: [String: String] = [:]
    private let transfers = TransferSession()

    init(config: Config, credentials: @escaping @Sendable () async throws -> S3Credentials) {
        self.config = config
        credentialsProvider = credentials
    }

    // MARK: Listing

    func listBuckets() async throws -> [S3Bucket] {
        let (data, _) = try await send("GET", bucket: nil, key: nil)
        let root = try XMLTree.parse(data)
        return root.all("Bucket").map { bucket in
            S3Bucket(name: bucket.text("Name") ?? "", created: bucket.text("CreationDate").flatMap(Self.date))
        }.filter { !$0.name.isEmpty }
    }

    /// One page of a "folder": sub-prefixes and objects directly inside `prefix`.
    func list(bucket: String, prefix: String, delimiter: String? = "/", token: String? = nil) async throws -> S3Listing {
        var query = [("list-type", "2"), ("prefix", prefix), ("max-keys", "1000")]
        if let delimiter { query.append(("delimiter", delimiter)) }
        if let token { query.append(("continuation-token", token)) }
        let (data, _) = try await send("GET", bucket: bucket, key: nil, query: query)
        let root = try XMLTree.parse(data)
        var listing = S3Listing()
        listing.prefixes = root.all("CommonPrefixes").compactMap { $0.text("Prefix") }
        listing.objects = root.all("Contents").compactMap { item in
            guard let key = item.text("Key") else { return nil }
            return S3Object(key: key, size: Int64(item.text("Size") ?? "") ?? 0,
                            modified: item.text("LastModified").flatMap(Self.date), storageClass: item.text("StorageClass"))
        }
        if root.text("IsTruncated") == "true" { listing.nextToken = root.text("NextContinuationToken") }
        return listing
    }

    /// Every object under `prefix`, however deep (for downloading or deleting a folder).
    func listAll(bucket: String, prefix: String) async throws -> [S3Object] {
        var objects: [S3Object] = []
        var token: String?
        repeat {
            try Task.checkCancellation()
            let page = try await list(bucket: bucket, prefix: prefix, delimiter: nil, token: token)
            objects += page.objects
            token = page.nextToken
        } while token != nil
        return objects
    }

    // MARK: Changing things

    func createBucket(_ bucket: String) async throws {
        let region = config.region
        let body = region == "us-east-1" || config.endpoint != nil ? nil
            : Data("<CreateBucketConfiguration><LocationConstraint>\(region)</LocationConstraint></CreateBucketConfiguration>".utf8)
        _ = try await send("PUT", bucket: bucket, key: nil, body: body)
    }

    /// An empty object ending in "/", which S3 consoles show as a folder.
    func createFolder(bucket: String, key: String) async throws {
        _ = try await send("PUT", bucket: bucket, key: key.hasSuffix("/") ? key : key + "/", body: Data())
    }

    func delete(bucket: String, keys: [String]) async throws {
        for batch in stride(from: 0, to: keys.count, by: 1000).map({ Array(keys[$0..<min($0 + 1000, keys.count)]) }) {
            let objects = batch.map { "<Object><Key>\(XMLTree.escape($0))</Key></Object>" }.joined()
            let body = Data("<Delete><Quiet>true</Quiet>\(objects)</Delete>".utf8)
            let md5 = Data(Insecure.MD5.hash(data: body)).base64EncodedString()
            let (data, _) = try await send("POST", bucket: bucket, key: nil, query: [("delete", "")], body: body,
                                           headers: ["Content-MD5": md5, "Content-Type": "application/xml"])
            let failed = try XMLTree.parse(data).all("Error")
            if let first = failed.first {
                throw S3Error(status: 200, code: first.text("Code") ?? "", message: "\(failed.count) couldn't be deleted: \(first.text("Message") ?? "")")
            }
        }
    }

    /// An object's bytes straight into memory: all of it, or just `range` (inclusive), for
    /// previews that only need the start of a file.
    func data(bucket: String, key: String, range: ClosedRange<Int64>? = nil) async throws -> Data {
        let headers = range.map { ["Range": "bytes=\($0.lowerBound)-\($0.upperBound)"] } ?? [:]
        return try await send("GET", bucket: bucket, key: key, headers: headers).0
    }

    /// A link anyone can download from until it expires (S3 allows up to 7 days).
    func shareURL(bucket: String, key: String, expires: Int = 604_800) async throws -> URL {
        let credentials = try await currentCredentials()
        let region = bucketRegions[bucket] ?? config.region
        guard let url = Self.url(config: config, region: region, bucket: bucket, key: key, query: []),
              let signed = S3Signer.presign(url, credentials: credentials, region: region, expires: expires) else {
            throw S3Error(status: 0, code: "", message: "Couldn't make a link for that object.")
        }
        return signed
    }

    // MARK: Transfers

    /// Uploads a file, in parts when it's large. `progress` gets the bytes sent so far.
    func upload(file: URL, bucket: String, key: String, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let size = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let type = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        if size <= Self.multipartThreshold {
            let request = try await signedRequest("PUT", bucket: bucket, key: key, headers: ["Content-Type": type])
            let (data, response) = try await transfers.upload(request, fromFile: file, progress: progress)
            try Self.check(response, data)
            return
        }
        try await multipartUpload(file: file, size: size, type: type, bucket: bucket, key: key, progress: progress)
    }

    func download(bucket: String, key: String, to destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let request = try await signedRequest("GET", bucket: bucket, key: key)
        let (response, errorBody) = try await transfers.download(request, to: destination, progress: progress)
        if let errorBody { try Self.check(response, errorBody) }
    }

    private func multipartUpload(file: URL, size: Int64, type: String, bucket: String, key: String,
                                 progress: @escaping @Sendable (Int64) -> Void) async throws {
        let (created, _) = try await send("POST", bucket: bucket, key: key, query: [("uploads", "")], headers: ["Content-Type": type])
        guard let uploadID = try XMLTree.parse(created).text("UploadId") else {
            throw S3Error(status: 0, code: "", message: "S3 didn't start the upload.")
        }
        // At most 10,000 parts, each at least 8 MB.
        let partSize = max(Int64(8 << 20), (size + 9_999) / 10_000)
        let count = Int((size + partSize - 1) / partSize)
        let sent = SentBytes(parts: count)
        do {
            var etags = [String](repeating: "", count: count)
            try await withThrowingTaskGroup(of: (Int, String).self) { group in
                var next = 0
                func addPart() {
                    let index = next
                    next += 1
                    group.addTask {
                        let offset = Int64(index) * partSize
                        let length = Int(min(partSize, size - offset))
                        let handle = try FileHandle(forReadingFrom: file)
                        defer { try? handle.close() }
                        try handle.seek(toOffset: UInt64(offset))
                        let data = try handle.read(upToCount: length) ?? Data()
                        let request = try await self.signedRequest("PUT", bucket: bucket, key: key,
                                                                   query: [("partNumber", String(index + 1)), ("uploadId", uploadID)])
                        let (body, response) = try await self.transfers.upload(request, data: data) { partSent in
                            progress(sent.update(part: index, bytes: partSent))
                        }
                        try Self.check(response, body)
                        return (index, response.value(forHTTPHeaderField: "ETag") ?? "")
                    }
                }
                for _ in 0..<min(4, count) { addPart() }
                while let (index, etag) = try await group.next() {
                    etags[index] = etag
                    if next < count { addPart() }
                }
            }
            let parts = etags.enumerated().map { "<Part><PartNumber>\($0.offset + 1)</PartNumber><ETag>\(XMLTree.escape($0.element))</ETag></Part>" }
            let body = Data("<CompleteMultipartUpload>\(parts.joined())</CompleteMultipartUpload>".utf8)
            let (data, _) = try await send("POST", bucket: bucket, key: key, query: [("uploadId", uploadID)], body: body,
                                           headers: ["Content-Type": "application/xml"])
            // S3 can report a failure inside a 200 response.
            if let error = try? XMLTree.parse(data), error.name == "Error" {
                throw S3Error(status: 200, code: error.text("Code") ?? "", message: error.text("Message") ?? "")
            }
        } catch {
            _ = try? await send("DELETE", bucket: bucket, key: key, query: [("uploadId", uploadID)])
            throw error
        }
    }

    // MARK: Requests

    private func currentCredentials() async throws -> S3Credentials {
        if let credentials, (credentials.expiration ?? .distantFuture) > Date().addingTimeInterval(60) { return credentials }
        let fresh = try await credentialsProvider()
        credentials = fresh
        return fresh
    }

    private func signedRequest(_ method: String, bucket: String?, key: String?, query: [(String, String)] = [],
                               headers: [String: String] = [:], payloadHash: String = S3Signer.unsignedPayload) async throws -> URLRequest {
        let region = bucket.flatMap { bucketRegions[$0] } ?? config.region
        guard let url = Self.url(config: config, region: region, bucket: bucket, key: key, query: query) else {
            throw S3Error(status: 0, code: "", message: "That bucket or key can't be turned into a URL.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        S3Signer.sign(&request, credentials: try await currentCredentials(), region: region, payloadHash: payloadHash)
        return request
    }

    /// Sends a small request and returns its body, following S3's "wrong region" answers once.
    private func send(_ method: String, bucket: String?, key: String?, query: [(String, String)] = [], body: Data? = nil,
                      headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        for attempt in 0..<2 {
            var request = try await signedRequest(method, bucket: bucket, key: key, query: query, headers: headers,
                                                  payloadHash: body.map(S3Signer.sha256Hex) ?? S3Signer.emptyPayloadHash)
            request.httpBody = body
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw S3Error(status: 0, code: "", message: "No response from S3.") }
            if (200..<300).contains(http.statusCode) { return (data, http) }
            let error = Self.error(http, data)
            if attempt == 0, let bucket, let region = error.region ?? http.value(forHTTPHeaderField: "x-amz-bucket-region"),
               region != (bucketRegions[bucket] ?? config.region) {
                bucketRegions[bucket] = region
                continue
            }
            throw error
        }
        throw S3Error(status: 0, code: "", message: "S3 kept redirecting the request.")
    }

    nonisolated static func url(config: Config, region: String, bucket: String?, key: String?, query: [(String, String)]) -> URL? {
        var components = URLComponents()
        let encodedKey = key.map { S3Signer.encode($0, keepSlashes: true) } ?? ""
        if let endpoint = config.endpoint {
            // S3-compatible services: path-style, endpoint/bucket/key.
            components.scheme = endpoint.scheme
            components.host = endpoint.host
            components.port = endpoint.port
            let base = endpoint.path.hasSuffix("/") ? String(endpoint.path.dropLast()) : endpoint.path
            components.percentEncodedPath = base + "/" + (bucket.map { S3Signer.encode($0) + "/" } ?? "") + encodedKey
        } else if let bucket, isVirtualHostable(bucket) {
            components.scheme = "https"
            components.host = "\(bucket).s3.\(region).amazonaws.com"
            components.percentEncodedPath = "/" + encodedKey
        } else {
            components.scheme = "https"
            components.host = "s3.\(region).amazonaws.com"
            components.percentEncodedPath = "/" + (bucket.map { S3Signer.encode($0) + "/" } ?? "") + encodedKey
        }
        if !query.isEmpty {
            components.percentEncodedQueryItems = query.map { URLQueryItem(name: S3Signer.encode($0.0), value: S3Signer.encode($0.1)) }
        }
        return components.url
    }

    /// Bucket names with dots (or other odd names) break HTTPS on bucket.s3.amazonaws.com.
    nonisolated static func isVirtualHostable(_ bucket: String) -> Bool {
        bucket.count >= 3 && bucket.count <= 63 && !bucket.contains(".")
            && bucket.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "-" }
    }

    nonisolated static func check(_ response: HTTPURLResponse, _ data: Data) throws {
        guard !(200..<300).contains(response.statusCode) else { return }
        throw error(response, data)
    }

    nonisolated static func error(_ response: HTTPURLResponse, _ data: Data) -> S3Error {
        let root = try? XMLTree.parse(data)
        return S3Error(status: response.statusCode, code: root?.text("Code") ?? "", message: root?.text("Message") ?? "",
                       region: root?.text("Region") ?? response.value(forHTTPHeaderField: "x-amz-bucket-region"))
    }

    nonisolated static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

/// Bytes sent so far for each part of a multipart upload, added up for the progress bar.
private final class SentBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var parts: [Int64]

    init(parts: Int) { self.parts = Array(repeating: 0, count: parts) }

    func update(part: Int, bytes: Int64) -> Int64 {
        lock.withLock {
            parts[part] = bytes
            return parts.reduce(0, +)
        }
    }
}

// MARK: - Transfers with progress

/// URLSession uploads and downloads that report progress and stop when their task is cancelled.
final class TransferSession: NSObject, URLSessionDataDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    private struct Pending {
        var uploadProgress: (@Sendable (Int64) -> Void)?
        var downloadProgress: (@Sendable (Int64, Int64) -> Void)?
        var destination: URL?
        var body = Data()
        var errorBody: Data?
        var finish: (Result<(Data, HTTPURLResponse, Data?), Error>) -> Void
    }

    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    private lazy var session: URLSession = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return URLSession(configuration: .default, delegate: self, delegateQueue: queue)
    }()

    func upload(_ request: URLRequest, fromFile file: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> (Data, HTTPURLResponse) {
        let (data, response, _) = try await run { self.session.uploadTask(with: request, fromFile: file) } setup: {
            $0.uploadProgress = progress
        }
        return (data, response)
    }

    func upload(_ request: URLRequest, data: Data, progress: @escaping @Sendable (Int64) -> Void) async throws -> (Data, HTTPURLResponse) {
        let (body, response, _) = try await run { self.session.uploadTask(with: request, from: data) } setup: {
            $0.uploadProgress = progress
        }
        return (body, response)
    }

    /// Downloads to `destination`. On an error status nothing is written and the body is returned.
    func download(_ request: URLRequest, to destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> (HTTPURLResponse, Data?) {
        let (_, response, errorBody) = try await run { self.session.downloadTask(with: request) } setup: {
            $0.downloadProgress = progress
            $0.destination = destination
        }
        return (response, errorBody)
    }

    private func run(_ make: () -> URLSessionTask, setup: (inout Pending) -> Void) async throws -> (Data, HTTPURLResponse, Data?) {
        let task = make()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                var entry = Pending { continuation.resume(with: $0) }
                setup(&entry)
                lock.withLock { pending[task.taskIdentifier] = entry }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        let progress = lock.withLock { pending[task.taskIdentifier]?.uploadProgress }
        progress?(totalBytesSent)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock { pending[dataTask.taskIdentifier]?.body.append(data) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let progress = lock.withLock { pending[downloadTask.taskIdentifier]?.downloadProgress }
        progress?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file is gone once this returns, so move it (or read the error) now.
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        let destination = lock.withLock { pending[downloadTask.taskIdentifier]?.destination }
        if (200..<300).contains(status), let destination {
            let fm = FileManager.default
            try? fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: destination)
            do {
                try fm.moveItem(at: location, to: destination)
            } catch {
                lock.withLock { pending[downloadTask.taskIdentifier]?.errorBody = Data("<Error><Message>Couldn't save the file: \(error.localizedDescription)</Message></Error>".utf8) }
            }
        } else {
            let body = (try? Data(contentsOf: location)) ?? Data()
            lock.withLock { pending[downloadTask.taskIdentifier]?.errorBody = body }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let entry = lock.withLock({ pending.removeValue(forKey: task.taskIdentifier) }) else { return }
        if let error {
            entry.finish(.failure((error as? URLError)?.code == .cancelled ? CancellationError() : error))
        } else if let response = task.response as? HTTPURLResponse {
            entry.finish(.success((entry.body, response, entry.errorBody)))
        } else {
            entry.finish(.failure(S3Error(status: 0, code: "", message: "No response from S3.")))
        }
    }
}

// MARK: - XML

/// Just enough XML for S3's responses: a tree of elements with their text.
struct XMLTree: Sendable {
    var name: String
    var text = ""
    var children: [XMLTree] = []

    /// The text of the first descendant called `name`.
    func text(_ name: String) -> String? { first(name)?.text }

    func first(_ name: String) -> XMLTree? {
        for child in children {
            if child.name == name { return child }
            if let found = child.first(name) { return found }
        }
        return nil
    }

    /// Every descendant called `name`, in document order.
    func all(_ name: String) -> [XMLTree] {
        children.flatMap { ($0.name == name ? [$0] : []) + $0.all(name) }
    }

    static func parse(_ data: Data) throws -> XMLTree {
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        guard parser.parse(), let root = builder.root else {
            throw S3Error(status: 0, code: "", message: "S3 sent a response that couldn't be read.")
        }
        return root
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var stack: [XMLTree] = []
        var root: XMLTree?

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            stack.append(XMLTree(name: name))
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if !stack.isEmpty { stack[stack.count - 1].text += string }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            var node = stack.removeLast()
            node.text = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if stack.isEmpty { root = node } else { stack[stack.count - 1].children.append(node) }
        }
    }
}
