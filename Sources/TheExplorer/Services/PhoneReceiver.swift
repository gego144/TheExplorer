import Foundation
import Network

/// A small web server on the local network that an iPhone sends photos to: its page (from a
/// QR code, kept on the Home Screen) picks photos and uploads them one at a time, and each
/// lands in a folder on this Mac. Every request needs the pairing token from the QR code, so
/// nothing else on the network can read the page or write files.
///
/// It runs on its own queue; file bodies stream to disk a megabyte at a time, so a long video
/// never sits in memory.
final class PhoneReceiver: @unchecked Sendable {
    struct Config: Sendable {
        var port: UInt16
        var token: String
        var folder: URL
        var macName: String
    }

    /// What happens to one incoming file, reported on the main thread.
    struct Events: Sendable {
        var started: @Sendable @MainActor (_ id: UUID, _ name: String, _ bytes: Int64, _ folder: URL) -> Void = { _, _, _, _ in }
        var progress: @Sendable @MainActor (_ id: UUID, _ bytes: Int64) -> Void = { _, _ in }
        var finished: @Sendable @MainActor (_ id: UUID, _ file: URL?, _ error: String?) -> Void = { _, _, _ in }
        var state: @Sendable @MainActor (_ listening: Bool, _ error: String?) -> Void = { _, _ in }
    }

    private let queue = DispatchQueue(label: "TheExplorer.PhoneReceiver")
    private var listener: NWListener?
    private var config: Config
    private let events: Events

    init(config: Config, events: Events) {
        self.config = config
        self.events = events
    }

    func start() {
        queue.async { self.listen() }
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
        }
    }

    /// A new folder (or name) for files from now on.
    func update(_ change: @escaping @Sendable (inout Config) -> Void) {
        queue.async { change(&self.config) }
    }

    private func listen() {
        listener?.cancel()
        guard let port = NWEndpoint.Port(rawValue: config.port) else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: port)
            listener.stateUpdateHandler = { [events] state in
                switch state {
                case .ready: Task { @MainActor in events.state(true, nil) }
                case .failed(let error): Task { @MainActor in events.state(false, Self.describe(error)) }
                case .cancelled: Task { @MainActor in events.state(false, nil) }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return connection.cancel() }
                HTTPExchange(connection: connection, receiver: self).begin(on: self.queue)
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            let message = Self.describe(error)
            Task { @MainActor [events] in events.state(false, message) }
        }
    }

    private static func describe(_ error: Error) -> String {
        if case NWError.posix(.EADDRINUSE) = error { return "Another app is using this port." }
        return error.localizedDescription
    }

    // MARK: Requests

    fileprivate var current: Config { config }
    fileprivate var callbacks: Events { events }

    /// Constant-time, so the token can't be guessed a character at a time.
    static func tokenMatches(_ given: String?, _ expected: String) -> Bool {
        guard let given, !expected.isEmpty else { return false }
        let a = Array(given.utf8), b = Array(expected.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// A file name safe to save: no folders, no hidden files, nothing empty.
    static func safeName(_ raw: String?) -> String {
        let last = (raw ?? "").replacingOccurrences(of: ":", with: "-").split(separator: "/").last.map(String.init) ?? ""
        let trimmed = last.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        let cleaned = String(trimmed.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        return cleaned.isEmpty ? "Photo" : String(cleaned.prefix(200))
    }
}

/// The start of an HTTP request: method, path, query and headers.
struct HTTPRequestHead: Equatable {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]

    var contentLength: Int64? { headers["content-length"].flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) } }

    /// Parses everything before the blank line, or nil if it isn't a request.
    init?(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        var lines = text.components(separatedBy: "\r\n")
        let parts = lines.removeFirst().split(separator: " ")
        guard parts.count >= 2 else { return nil }
        method = String(parts[0]).uppercased()
        let components = URLComponents(string: String(parts[1]))
        path = components?.path ?? "/"
        query = Dictionary((components?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        self.headers = headers
    }
}

/// One request and its response, then the connection closes.
private final class HTTPExchange: @unchecked Sendable {
    private let connection: NWConnection
    private let receiver: PhoneReceiver
    private var queue: DispatchQueue!
    private var buffer = Data()
    private static let headLimit = 64 * 1024

    // A file being received.
    private var file: FileHandle?
    private var partURL: URL?
    private var remaining: Int64 = 0
    private var received: Int64 = 0
    private var total: Int64 = 0
    private var name = ""
    private var folder: URL?
    private var modified: Date?
    private var transfer = UUID()
    private var lastReport = Date.distantPast
    /// Keeps the exchange alive until the connection is done with it.
    private var keepAlive: HTTPExchange?

    init(connection: NWConnection, receiver: PhoneReceiver) {
        self.connection = connection
        self.receiver = receiver
    }

    func begin(on queue: DispatchQueue) {
        self.queue = queue
        keepAlive = self
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.ended()
            default: break
            }
        }
        connection.start(queue: queue)
        readHead()
    }

    private func readHead() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { self.buffer.append(data) }
            if let end = self.buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = self.buffer[..<end.lowerBound]
                let rest = self.buffer[end.upperBound...]
                guard let request = HTTPRequestHead(Data(head)) else { return self.respond(400, text: "Bad request") }
                self.handle(request, body: Data(rest))
            } else if error != nil || isComplete || self.buffer.count > Self.headLimit {
                self.close()
            } else {
                self.readHead()
            }
        }
    }

    private func handle(_ request: HTTPRequestHead, body: Data) {
        let config = receiver.current
        if request.method == "GET" && request.path == "/icon.png" {
            return respond(200, type: "image/png", body: ReceivePage.icon, cache: true)
        }
        let token = request.query["t"] ?? request.headers["x-token"]
        guard PhoneReceiver.tokenMatches(token, config.token) else {
            return respond(403, type: "text/html; charset=utf-8", body: Data(ReceivePage.forbidden.utf8))
        }
        switch (request.method, request.path) {
        case ("GET", "/"):
            respond(200, type: "text/html; charset=utf-8", body: Data(ReceivePage.html(macName: config.macName, folderName: config.folder.lastPathComponent).utf8))
        case ("GET", "/ping"):
            respond(200, type: "application/json", body: Data(#"{"ok":true}"#.utf8))
        case ("POST", "/upload"):
            guard let length = request.contentLength, length >= 0 else { return respond(411, text: "Length required") }
            receive(length: length, name: PhoneReceiver.safeName(request.query["name"] ?? request.headers["x-filename"]),
                    modified: request.query["modified"].flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) },
                    first: body, into: config.folder)
        default:
            respond(404, text: "Not found")
        }
    }

    // MARK: Receiving a file

    private func receive(length: Int64, name: String, modified: Date?, first: Data, into folder: URL) {
        let part = folder.appendingPathComponent(".\(UUID().uuidString).part")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: part.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            file = try FileHandle(forWritingTo: part)
        } catch {
            return respond(500, text: "Can't write to \(folder.lastPathComponent): \(error.localizedDescription)")
        }
        partURL = part
        self.folder = folder
        self.name = name
        self.modified = modified
        total = length
        remaining = length
        let (events, id) = (receiver.callbacks, transfer)
        Task { @MainActor in events.started(id, name, length, folder) }
        write(first)
        if remaining <= 0 { return complete() }
        readBody()
    }

    private func readBody() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.write(data) }
            if self.remaining <= 0 {
                self.complete()
            } else if error != nil || isComplete {
                self.abandon("The iPhone stopped sending before the end.")
            } else {
                self.readBody()
            }
        }
    }

    private func write(_ data: Data) {
        guard !data.isEmpty, let file else { return }
        let chunk = data.count > remaining ? data.prefix(Int(remaining)) : data
        do { try file.write(contentsOf: chunk) } catch { return abandon(error.localizedDescription) }
        remaining -= Int64(chunk.count)
        received += Int64(chunk.count)
        // A few updates a second is plenty for the status bar.
        if Date().timeIntervalSince(lastReport) > 0.15 {
            lastReport = Date()
            let (events, id, bytes) = (receiver.callbacks, transfer, received)
            Task { @MainActor in events.progress(id, bytes) }
        }
    }

    private func complete() {
        try? file?.close()
        file = nil
        guard let partURL, let folder else { return }
        let destination = FileTransfer.uniqueDestination(for: name, in: folder)
        do {
            try FileManager.default.moveItem(at: partURL, to: destination)
            self.partURL = nil
            // When it was taken is kept as the file's creation date. It's modified now, so it's
            // at the top of a folder sorted by date rather than back with the day it was taken.
            if let modified {
                try? FileManager.default.setAttributes([.creationDate: modified], ofItemAtPath: destination.path)
            }
        } catch {
            return abandon(error.localizedDescription)
        }
        let (events, id) = (receiver.callbacks, transfer)
        Task { @MainActor in events.finished(id, destination, nil) }
        let reply = try? JSONSerialization.data(withJSONObject: ["name": destination.lastPathComponent])
        respond(200, type: "application/json", body: reply ?? Data())
    }

    private func abandon(_ message: String) {
        try? file?.close()
        file = nil
        if let partURL { try? FileManager.default.removeItem(at: partURL) }
        partURL = nil
        let (events, id) = (receiver.callbacks, transfer)
        Task { @MainActor in events.finished(id, nil, message) }
        respond(500, text: message)
    }

    // MARK: Responding

    private func respond(_ status: Int, text: String) {
        respond(status, type: "text/plain; charset=utf-8", body: Data(text.utf8))
    }

    private func respond(_ status: Int, type: String, body: Data, cache: Bool = false) {
        let reason = [200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 411: "Length Required", 500: "Internal Server Error"][status] ?? "OK"
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        head += cache ? "Cache-Control: max-age=86400\r\n" : "Cache-Control: no-store\r\n"
        head += "\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { [weak self] _ in self?.close() })
    }

    private func close() {
        connection.cancel()
    }

    private func ended() {
        if file != nil { abandon("The connection closed.") }
        keepAlive = nil
    }
}
