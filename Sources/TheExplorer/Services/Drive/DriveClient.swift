import Foundation
import UniformTypeIdentifiers

struct DriveError: LocalizedError, Sendable {
    var status = 0
    /// Google's reason, e.g. "notFound" or "rateLimitExceeded".
    var reason = ""
    let message: String

    var errorDescription: String? { message }
}

/// A file or folder in Drive, with what the list, the inspector and transfers need.
struct DriveFile: Sendable, Hashable {
    static let folderType = "application/vnd.google-apps.folder"
    static let googlePrefix = "application/vnd.google-apps."

    var id: String
    var name: String
    var mimeType: String
    var size: Int64?
    var modified: Date?
    var created: Date?
    var parents: [String] = []
    /// The shared drive it's in; nil in My Drive.
    var driveID: String?
    var webLink: String?
    var owner: String?
    /// Where a shortcut points.
    var targetID: String?
    var targetType: String?
    var canAddChildren = true
    var canRename = true
    var canTrash = true

    /// The file a shortcut points at, or the file itself.
    var contentID: String { targetID ?? id }
    var contentType: String { targetType ?? mimeType }
    var isFolder: Bool { contentType == Self.folderType }
    /// Docs, Sheets, Slides and the like: they only exist in Drive, and download as an export.
    var isGoogleDoc: Bool { !isFolder && contentType.hasPrefix(Self.googlePrefix) }
    var isShortcut: Bool { targetID != nil }

    /// What the list shows it as: its own extension's type, or a Google type for Docs and the like.
    var uniformType: UTType? {
        if isFolder { return .folder }
        if isGoogleDoc { return UTType(mimeType: contentType) }
        return UTType(filenameExtension: (name as NSString).pathExtension)
    }

    /// "Google Docs", "Google Sheets"…, or nil for ordinary files.
    var googleKind: String? {
        guard isGoogleDoc else { return nil }
        return DriveFile.googleKinds[String(contentType.dropFirst(Self.googlePrefix.count))] ?? "Google file"
    }

    static let googleKinds = [
        "document": "Google Docs", "spreadsheet": "Google Sheets", "presentation": "Google Slides",
        "form": "Google Forms", "drawing": "Google Drawings", "script": "Apps Script", "site": "Google Sites",
        "jam": "Jamboard", "map": "My Maps", "vid": "Google Vids",
    ]

    init(id: String, name: String, mimeType: String, size: Int64? = nil, modified: Date? = nil, created: Date? = nil) {
        self.id = id
        self.name = name
        self.mimeType = mimeType
        self.size = size
        self.modified = modified
        self.created = created
    }

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String else { return nil }
        self.id = id
        name = json["name"] as? String ?? "Untitled"
        mimeType = json["mimeType"] as? String ?? "application/octet-stream"
        size = (json["size"] as? String).flatMap { Int64($0) }
        modified = (json["modifiedTime"] as? String).flatMap(DriveClient.date)
        created = (json["createdTime"] as? String).flatMap(DriveClient.date)
        parents = json["parents"] as? [String] ?? []
        driveID = json["driveId"] as? String
        webLink = json["webViewLink"] as? String
        owner = ((json["owners"] as? [[String: Any]])?.first?["displayName"] as? String)
        if let shortcut = json["shortcutDetails"] as? [String: Any] {
            targetID = shortcut["targetId"] as? String
            targetType = shortcut["targetMimeType"] as? String
        }
        if let capabilities = json["capabilities"] as? [String: Any] {
            canAddChildren = capabilities["canAddChildren"] as? Bool ?? true
            canRename = capabilities["canRename"] as? Bool ?? true
            canTrash = capabilities["canTrash"] as? Bool ?? true
        }
    }
}

struct DriveListing: Sendable {
    var files: [DriveFile] = []
    var nextToken: String?
}

struct SharedDrive: Sendable, Hashable {
    let id: String
    let name: String
    let created: Date?
}

/// Who's signed in and how full their Drive is.
struct DriveAbout: Sendable, Hashable, Codable {
    var name: String
    var email: String
    /// Nil for unlimited storage.
    var limit: Int64?
    var usage: Int64

    /// Storage the way Google counts it, so a free account's 15 GB reads as 15 GB.
    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
    }
}

/// A format Google's own files (Docs, Sheets, Slides…) download as.
struct DriveExport: Sendable, Hashable {
    let title: String
    let mimeType: String
    let fileExtension: String

    static let pdf = DriveExport(title: "PDF", mimeType: "application/pdf", fileExtension: "pdf")

    /// The formats a Google file can be exported as, the usual one first. Empty for ones that
    /// can't be (Forms, Sites, My Maps…).
    static func formats(for type: String) -> [DriveExport] {
        switch type {
        case DriveFile.googlePrefix + "document":
            [DriveExport(title: "Word", mimeType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document", fileExtension: "docx"),
             .pdf, DriveExport(title: "Markdown", mimeType: "text/markdown", fileExtension: "md"),
             DriveExport(title: "Plain Text", mimeType: "text/plain", fileExtension: "txt")]
        case DriveFile.googlePrefix + "spreadsheet":
            [DriveExport(title: "Excel", mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", fileExtension: "xlsx"),
             .pdf, DriveExport(title: "CSV (first sheet)", mimeType: "text/csv", fileExtension: "csv")]
        case DriveFile.googlePrefix + "presentation":
            [DriveExport(title: "PowerPoint", mimeType: "application/vnd.openxmlformats-officedocument.presentationml.presentation", fileExtension: "pptx"),
             .pdf]
        case DriveFile.googlePrefix + "drawing":
            [DriveExport(title: "PNG", mimeType: "image/png", fileExtension: "png"), .pdf,
             DriveExport(title: "SVG", mimeType: "image/svg+xml", fileExtension: "svg")]
        case DriveFile.googlePrefix + "script":
            [DriveExport(title: "JSON", mimeType: "application/vnd.google-apps.script+json", fileExtension: "json")]
        case DriveFile.googlePrefix + "jam":
            [.pdf]
        default:
            []
        }
    }

    /// The name the download gets: "Budget" becomes "Budget.xlsx".
    func fileName(for name: String) -> String {
        name.lowercased().hasSuffix("." + fileExtension) ? name : name + "." + fileExtension
    }
}

/// Google Drive's REST API (v3), signed in with an account's tokens. Requests that hit a rate
/// limit or a server hiccup are retried; an expired token is refreshed and the request repeated.
final class DriveClient: Sendable {
    let auth: GoogleAuth
    private let transfers = TransferSession()

    static var api: String { (GoogleOAuth.testEndpoint ?? "https://www.googleapis.com") + "/drive/v3" }
    static var uploadAPI: String { (GoogleOAuth.testEndpoint ?? "https://www.googleapis.com") + "/upload/drive/v3" }

    static let fileFields = "id,name,mimeType,size,modifiedTime,createdTime,parents,driveId,webViewLink,owners(displayName),shortcutDetails(targetId,targetMimeType),capabilities(canAddChildren,canRename,canTrash)"

    init(auth: GoogleAuth) {
        self.auth = auth
    }

    // MARK: Reading

    func about() async throws -> DriveAbout {
        let json = try await object(request("GET", Self.api, "/about", query: [("fields", "user(displayName,emailAddress),storageQuota(limit,usage)")]))
        let user = json["user"] as? [String: Any] ?? [:]
        let quota = json["storageQuota"] as? [String: Any] ?? [:]
        return DriveAbout(name: user["displayName"] as? String ?? "", email: user["emailAddress"] as? String ?? "",
                          limit: (quota["limit"] as? String).flatMap { Int64($0) },
                          usage: (quota["usage"] as? String).flatMap { Int64($0) } ?? 0)
    }

    func file(_ id: String) async throws -> DriveFile {
        let json = try await object(request("GET", Self.api, "/files/" + Self.encode(id), query: [("fields", Self.fileFields)]))
        guard let file = DriveFile(json: json) else { throw DriveError(message: "Drive sent back something unexpected.") }
        return file
    }

    /// One page of a folder, folders first.
    func list(in folderID: String, token: String? = nil) async throws -> DriveListing {
        try await list(query: "\(Self.quoted(folderID)) in parents and trashed = false", orderBy: "folder,name_natural", token: token)
    }

    func sharedWithMe(token: String? = nil) async throws -> DriveListing {
        try await list(query: "sharedWithMe = true and trashed = false", orderBy: "folder,name_natural", token: token)
    }

    func starred(token: String? = nil) async throws -> DriveListing {
        try await list(query: "starred = true and trashed = false", orderBy: "folder,name_natural", token: token)
    }

    /// Drive's own search, in names and inside documents, across My Drive, shared files and
    /// shared drives. Results come in Drive's relevance order.
    func search(_ text: String, token: String? = nil) async throws -> DriveListing {
        let value = Self.quoted(text)
        return try await list(query: "trashed = false and (name contains \(value) or fullText contains \(value))", orderBy: nil, token: token)
    }

    func list(query: String, orderBy: String?, token: String?) async throws -> DriveListing {
        var items = [("q", query), ("pageSize", "1000"), ("fields", "nextPageToken,files(\(Self.fileFields))"),
                     ("includeItemsFromAllDrives", "true"), ("corpora", "allDrives")]
        if let orderBy { items.append(("orderBy", orderBy)) }
        if let token { items.append(("pageToken", token)) }
        let json = try await object(request("GET", Self.api, "/files", query: items))
        let files = (json["files"] as? [[String: Any]] ?? []).compactMap(DriveFile.init(json:))
        return DriveListing(files: files, nextToken: json["nextPageToken"] as? String)
    }

    /// Every page of a folder.
    func listAll(in folderID: String) async throws -> [DriveFile] {
        var files: [DriveFile] = []
        var token: String?
        repeat {
            try Task.checkCancellation()
            let page = try await list(in: folderID, token: token)
            files += page.files
            token = page.nextToken
        } while token != nil
        return files
    }

    func drives(token: String? = nil) async throws -> (drives: [SharedDrive], nextToken: String?) {
        var items = [("pageSize", "100"), ("fields", "nextPageToken,drives(id,name,createdTime)")]
        if let token { items.append(("pageToken", token)) }
        let json = try await object(request("GET", Self.api, "/drives", query: items, allDrives: false))
        let drives = (json["drives"] as? [[String: Any]] ?? []).compactMap { drive -> SharedDrive? in
            guard let id = drive["id"] as? String else { return nil }
            return SharedDrive(id: id, name: drive["name"] as? String ?? "Shared drive",
                               created: (drive["createdTime"] as? String).flatMap(Self.date))
        }
        return (drives, json["nextPageToken"] as? String)
    }

    func sharedDrive(_ id: String) async throws -> SharedDrive {
        let json = try await object(request("GET", Self.api, "/drives/" + Self.encode(id), query: [("fields", "id,name,createdTime")], allDrives: false))
        return SharedDrive(id: id, name: json["name"] as? String ?? "Shared drive", created: (json["createdTime"] as? String).flatMap(Self.date))
    }

    // MARK: Changing

    func createFolder(named name: String, in parent: String) async throws -> DriveFile {
        try await fileResponse(request("POST", Self.api, "/files", query: [("fields", Self.fileFields)],
                                       json: ["name": name, "mimeType": DriveFile.folderType, "parents": [parent]]))
    }

    func rename(_ id: String, to name: String) async throws -> DriveFile {
        try await fileResponse(request("PATCH", Self.api, "/files/" + Self.encode(id), query: [("fields", Self.fileFields)], json: ["name": name]))
    }

    /// Moves to Drive's trash, where it can be restored for 30 days.
    func trash(_ id: String) async throws {
        _ = try await send(request("PATCH", Self.api, "/files/" + Self.encode(id), query: [("fields", "id")], json: ["trashed": true]))
    }

    func move(_ id: String, from parents: [String], to parent: String) async throws -> DriveFile {
        var items = [("addParents", parent), ("fields", Self.fileFields)]
        if !parents.isEmpty { items.append(("removeParents", parents.joined(separator: ","))) }
        return try await fileResponse(request("PATCH", Self.api, "/files/" + Self.encode(id), query: items, json: [:]))
    }

    /// Copies a file (not a folder; Drive can't) into `parent`.
    func copy(_ id: String, named name: String, to parent: String) async throws -> DriveFile {
        try await fileResponse(request("POST", Self.api, "/files/" + Self.encode(id) + "/copy", query: [("fields", Self.fileFields)],
                                       json: ["name": name, "parents": [parent]]))
    }

    // MARK: Transfers

    /// Uploads a file in one resumable session. `progress` gets the bytes sent so far.
    func upload(file: URL, named name: String, into parent: String, progress: @escaping @Sendable (Int64) -> Void) async throws -> DriveFile {
        let size = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let type = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        var start = request("POST", Self.uploadAPI, "/files", query: [("uploadType", "resumable"), ("fields", Self.fileFields)],
                            json: ["name": name, "parents": [parent]])
        start.setValue(type, forHTTPHeaderField: "X-Upload-Content-Type")
        start.setValue(String(size), forHTTPHeaderField: "X-Upload-Content-Length")
        let (_, response) = try await send(start)
        guard let session = response.value(forHTTPHeaderField: "Location").flatMap(URL.init(string:)) else {
            throw DriveError(message: "Drive didn't start the upload.")
        }
        var put = URLRequest(url: session)
        put.httpMethod = "PUT"
        put.setValue(type, forHTTPHeaderField: "Content-Type")
        put.setValue("Bearer " + (try await auth.token()), forHTTPHeaderField: "Authorization")
        let (data, http) = try await transfers.upload(put, fromFile: file, progress: progress)
        guard (200..<300).contains(http.statusCode) else { throw Self.error(http.statusCode, data) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let uploaded = DriveFile(json: json) else {
            throw DriveError(message: "Drive sent back something unexpected.")
        }
        return uploaded
    }

    func download(_ id: String, to destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        try await fetch(request("GET", Self.api, "/files/" + Self.encode(id), query: [("alt", "media")]), to: destination, progress: progress)
    }

    /// Saves a Google Doc, Sheet or the like as `format`. Google exports up to 10 MB.
    func export(_ id: String, as format: DriveExport, to destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        try await fetch(request("GET", Self.api, "/files/" + Self.encode(id) + "/export", query: [("mimeType", format.mimeType)], allDrives: false),
                        to: destination, progress: progress)
    }

    private func fetch(_ request: URLRequest, to destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        var refreshed = false
        while true {
            var signed = request
            signed.setValue("Bearer " + (try await auth.token(forceRefresh: refreshed)), forHTTPHeaderField: "Authorization")
            let (response, errorBody) = try await transfers.download(signed, to: destination, progress: progress)
            guard let errorBody else { return }
            if response.statusCode == 401 && !refreshed {
                refreshed = true
                continue
            }
            if (200..<300).contains(response.statusCode) {
                throw DriveError(message: "Couldn't save “\(destination.lastPathComponent)”.")
            }
            throw Self.error(response.statusCode, errorBody)
        }
    }

    // MARK: Requests

    private func request(_ method: String, _ base: String, _ path: String, query: [(String, String)] = [],
                         json: [String: Any]? = nil, allDrives: Bool = true) -> URLRequest {
        let items = query + (allDrives ? [("supportsAllDrives", "true")] : [])
        var components = URLComponents(string: base + path)!
        components.percentEncodedQuery = items.map { Self.encode($0.0) + "=" + Self.encode($0.1) }.joined(separator: "&")
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        if let json {
            request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: json)
        }
        return request
    }

    private func object(_ request: URLRequest) async throws -> [String: Any] {
        let (data, _) = try await send(request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DriveError(message: "Drive sent back something unexpected.")
        }
        return json
    }

    private func fileResponse(_ request: URLRequest) async throws -> DriveFile {
        guard let file = DriveFile(json: try await object(request)) else { throw DriveError(message: "Drive sent back something unexpected.") }
        return file
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var refreshed = false
        var attempt = 0
        while true {
            var signed = request
            signed.setValue("Bearer " + (try await auth.token(forceRefresh: refreshed)), forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: signed)
            guard let http = response as? HTTPURLResponse else { throw DriveError(message: "No response from Google Drive.") }
            if (200..<300).contains(http.statusCode) { return (data, http) }
            if http.statusCode == 401 && !refreshed {
                refreshed = true
                continue
            }
            let error = Self.error(http.statusCode, data)
            if attempt < 3 && Self.isRetryable(error) {
                attempt += 1
                try await Task.sleep(for: .milliseconds(300 << attempt))
                continue
            }
            throw error
        }
    }

    // MARK: Helpers

    nonisolated static func isRetryable(_ error: DriveError) -> Bool {
        error.status == 429 || error.status >= 500 || ["rateLimitExceeded", "userRateLimitExceeded", "backendError"].contains(error.reason)
    }

    /// Google's error, in words that say what to do about it.
    nonisolated static func error(_ status: Int, _ data: Data) -> DriveError {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let body = json?["error"] as? [String: Any]
        let reason = ((body?["errors"] as? [[String: Any]])?.first?["reason"] as? String) ?? (body?["status"] as? String) ?? ""
        let message = body?["message"] as? String ?? String(decoding: data.prefix(300), as: UTF8.self)
        let friendly: String
        switch reason {
        case "accessNotConfigured", "SERVICE_DISABLED":
            friendly = "The Google Drive API isn't turned on for your Google Cloud project. Enable it in Google Cloud Console (APIs & Services → Library → Google Drive API), wait a minute, then try again."
        case "notFound":
            friendly = "Not found in Drive. It may have been moved, deleted or unshared."
        case "exportSizeLimitExceeded":
            friendly = "This file is too big for Google to export (the limit is 10 MB). Open it in the browser and download it from there."
        case "storageQuotaExceeded":
            friendly = "Your Google Drive is full."
        case "rateLimitExceeded", "userRateLimitExceeded":
            friendly = "Google is limiting requests right now. Try again in a moment."
        case "insufficientFilePermissions", "insufficientPermissions", "forbidden":
            friendly = "You don't have permission to do that in Drive. " + message
        case "fileNotDownloadable", "cannotDownloadAbusiveFile":
            friendly = "Drive won't let this file be downloaded. " + message
        default:
            friendly = status == 404 ? "Not found in Drive. It may have been moved, deleted or unshared." : message
        }
        return DriveError(status: status, reason: reason, message: friendly)
    }

    /// A value in a Drive query: 'it\'s here'.
    nonisolated static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
    }

    /// Percent-encodes everything but unreserved characters, so "+" in a name stays a plus.
    nonisolated static func encode(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    nonisolated static func date(_ text: String) -> Date? {
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text)) ?? (try? Date.ISO8601FormatStyle().parse(text))
    }
}
