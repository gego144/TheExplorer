import Foundation
import Observation
import Security

/// An S3 account you've connected: AWS through a profile in ~/.aws or access keys (the secret
/// is kept in the Keychain), or any S3-compatible service through a custom endpoint.
struct S3Connection: Codable, Identifiable, Hashable {
    enum Auth: Codable, Hashable {
        /// A profile from ~/.aws/config and ~/.aws/credentials.
        case profile(String)
        /// An access key ID; the secret is in the Keychain under the connection's id.
        case keys(accessKeyID: String)
    }

    var id = UUID()
    var name: String
    var auth: Auth
    var region: String
    /// For S3-compatible services such as Cloudflare R2 or MinIO. Empty means AWS.
    var endpoint = ""
    /// Opens straight into this bucket; needed when the keys can't list every bucket.
    var bucket = ""

    var config: S3Client.Config {
        S3Client.Config(region: region.isEmpty ? "us-east-1" : region,
                        endpoint: endpoint.isEmpty ? nil : URL(string: endpoint.hasPrefix("http") ? endpoint : "https://" + endpoint))
    }

    var root: S3Location { S3Location(connectionID: id, bucket: bucket.isEmpty ? nil : bucket) }

    /// "AWS profile default · us-east-1"
    var summary: String {
        let source = switch auth {
        case .profile(let name): "AWS profile \(name)"
        case .keys(let key): "Key \(key.prefix(4))…\(key.suffix(4))"
        }
        let place = endpoint.isEmpty ? region : (URL(string: endpoint)?.host ?? endpoint)
        return [source, place, bucket.isEmpty ? nil : bucket].compactMap { $0 }.joined(separator: " · ")
    }
}

/// A place in S3: a connection, a bucket (nil for the list of buckets) and a prefix ("" is the
/// top of the bucket; folders end in "/").
struct S3Location: Hashable, Sendable {
    var connectionID: UUID
    var bucket: String?
    var prefix = ""

    static let scheme = "x-s3"

    /// The URL rows, history and drags use: x-s3://<connection>/<bucket>/<key>.
    var url: URL { Self.url(connectionID: connectionID, bucket: bucket, key: prefix) }

    static func url(connectionID: UUID, bucket: String?, key: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = connectionID.uuidString.lowercased()
        components.percentEncodedPath = bucket.map { "/" + S3Signer.encode($0) + "/" + S3Signer.encode(key, keepSlashes: true) } ?? "/"
        return components.url!
    }

    /// The location a URL points at (for a file, its folder) and the key, if it's an object.
    init?(url: URL) {
        guard url.scheme == Self.scheme, let host = url.host, let id = UUID(uuidString: host) else { return nil }
        connectionID = id
        let path = (url.path(percentEncoded: true).removingPercentEncoding ?? "").dropFirst()
        guard let slash = path.firstIndex(of: "/") else {
            bucket = path.isEmpty ? nil : String(path)
            return
        }
        bucket = String(path[..<slash])
        prefix = String(path[path.index(after: slash)...])
    }

    init(connectionID: UUID, bucket: String?, prefix: String = "") {
        self.connectionID = connectionID
        self.bucket = bucket
        self.prefix = prefix
    }

    /// The last part of the prefix, or the bucket name at the top.
    var name: String {
        prefix.isEmpty ? (bucket ?? "") : String(prefix.dropLast().split(separator: "/").last ?? "")
    }

    /// What the item is called: the file name for an object, otherwise the folder or bucket name.
    var itemName: String {
        prefix.isEmpty || prefix.hasSuffix("/") ? name : (prefix as NSString).lastPathComponent
    }

    var parent: S3Location? {
        guard bucket != nil else { return nil }
        guard !prefix.isEmpty else { return S3Location(connectionID: connectionID, bucket: nil) }
        let parts = prefix.dropLast().split(separator: "/")
        return S3Location(connectionID: connectionID, bucket: bucket,
                          prefix: parts.dropLast().map { $0 + "/" }.joined())
    }

    /// s3://bucket/prefix, as the AWS CLI writes it.
    var uri: String { "s3://" + (bucket ?? "") + "/" + prefix }
}

/// Your connections, saved to Application Support (secrets go to the Keychain), with one
/// client per connection.
@MainActor
@Observable
final class S3Store {
    static let shared = S3Store()

    private(set) var connections: [S3Connection] = []
    @ObservationIgnored private var clients: [UUID: (S3Connection, S3Client)] = [:]
    @ObservationIgnored private let fileURL: URL

    init() {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["EXPLORER_S3_FILE"] {
            fileURL = URL(fileURLWithPath: path)
            load()
            return
        }
        #endif
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TheExplorer", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        fileURL = support.appendingPathComponent("s3.json")
        load()
    }

    func connection(_ id: UUID) -> S3Connection? { connections.first { $0.id == id } }

    func client(for id: UUID) -> S3Client? {
        guard let connection = connection(id) else { return nil }
        if let (cached, client) = clients[id], cached == connection { return client }
        let client = S3Client(config: connection.config) { try await Self.credentials(for: connection) }
        clients[id] = (connection, client)
        return client
    }

    /// Saves a connection, and its secret key when one is given.
    func save(_ connection: S3Connection, secret: String?) {
        if let secret, !secret.isEmpty { Keychain.set(secret, account: connection.id.uuidString) }
        if case .profile = connection.auth { Keychain.delete(account: connection.id.uuidString) }
        if let index = connections.firstIndex(where: { $0.id == connection.id }) {
            connections[index] = connection
        } else {
            connections.append(connection)
        }
        clients[connection.id] = nil
        persist()
    }

    func remove(_ connection: S3Connection) {
        Keychain.delete(account: connection.id.uuidString)
        connections.removeAll { $0.id == connection.id }
        clients[connection.id] = nil
        persist()
    }

    nonisolated static func credentials(for connection: S3Connection) async throws -> S3Credentials {
        switch connection.auth {
        case .profile(let name):
            return try await AWSProfiles.credentials(for: name)
        case .keys(let accessKeyID):
            guard let secret = Keychain.get(account: connection.id.uuidString) else {
                throw S3Error(status: 0, code: "", message: "The secret key for “\(connection.name)” isn't in the Keychain. Edit the connection to add it.")
            }
            return S3Credentials(accessKeyID: accessKeyID, secretAccessKey: secret)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([S3Connection].self, from: data) else { return }
        connections = decoded
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(connections) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// Profiles from the AWS CLI's files (~/.aws/config and ~/.aws/credentials).
enum AWSProfiles {
    private static var home: URL { URL(fileURLWithPath: NSHomeDirectory()) }
    private static var configFile: URL {
        ProcessInfo.processInfo.environment["AWS_CONFIG_FILE"].map(URL.init(fileURLWithPath:)) ?? home.appendingPathComponent(".aws/config")
    }
    private static var credentialsFile: URL {
        ProcessInfo.processInfo.environment["AWS_SHARED_CREDENTIALS_FILE"].map(URL.init(fileURLWithPath:))
            ?? home.appendingPathComponent(".aws/credentials")
    }

    static func names() -> [String] {
        var names = Array(sections(configFile).keys) + Array(sections(credentialsFile).keys)
        names = Array(Set(names)).sorted { $0 == "default" ? true : ($1 == "default" ? false : $0 < $1) }
        return names
    }

    static func region(for profile: String) -> String? { sections(configFile)[profile]?["region"] }
    static func endpoint(for profile: String) -> String? { sections(configFile)[profile]?["endpoint_url"] }

    /// Static keys from the files, or for SSO, assumed roles and credential processes, whatever
    /// the AWS CLI hands back (`aws configure export-credentials`).
    static func credentials(for profile: String) async throws -> S3Credentials {
        let values = sections(credentialsFile)[profile] ?? [:]
        let config = sections(configFile)[profile] ?? [:]
        if let key = values["aws_access_key_id"] ?? config["aws_access_key_id"],
           let secret = values["aws_secret_access_key"] ?? config["aws_secret_access_key"] {
            return S3Credentials(accessKeyID: key, secretAccessKey: secret,
                                 sessionToken: values["aws_session_token"] ?? config["aws_session_token"])
        }
        return try await exportFromCLI(profile)
    }

    private static func exportFromCLI(_ profile: String) async throws -> S3Credentials {
        guard let cli = ["/opt/homebrew/bin/aws", "/usr/local/bin/aws", "/usr/bin/aws"].first(where: FileManager.default.isExecutableFile) else {
            throw S3Error(status: 0, code: "", message: "Profile “\(profile)” has no keys in ~/.aws/credentials, and the AWS CLI (needed for SSO and roles) isn't installed.")
        }
        return try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cli)
            process.arguments = ["configure", "export-credentials", "--profile", profile, "--format", "process"]
            let output = Pipe(), errors = Pipe()
            process.standardOutput = output
            process.standardError = errors
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let errorText = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let key = json["AccessKeyId"] as? String, let secret = json["SecretAccessKey"] as? String else {
                let hint = errorText.contains("sso") || errorText.contains("SSO") ? " Run “aws sso login --profile \(profile)” first." : ""
                throw S3Error(status: 0, code: "", message: "The AWS CLI couldn't get credentials for “\(profile)”.\(hint) \(errorText.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            return S3Credentials(accessKeyID: key, secretAccessKey: secret, sessionToken: json["SessionToken"] as? String,
                                 expiration: (json["Expiration"] as? String).flatMap(S3Client.date))
        }.value
    }

    /// INI sections by profile name: "[default]", "[profile work]" (config) or "[work]" (credentials).
    static func sections(_ file: URL) -> [String: [String: String]] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [:] }
        return parse(text)
    }

    static func parse(_ text: String) -> [String: [String: String]] {
        var result: [String: [String: String]] = [:]
        var current: String?
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                var name = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                if name.hasPrefix("profile ") { name = String(name.dropFirst(8)).trimmingCharacters(in: .whitespaces) }
                // Other sections (sso-session, services) aren't profiles.
                current = name.contains(" ") ? nil : name
                if let current, result[current] == nil { result[current] = [:] }
                continue
            }
            guard let current, let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            result[current]?[key] = value
        }
        return result
    }
}

/// Secret keys in the login Keychain.
enum Keychain {
    private static let service = "TheExplorer S3"

    static func set(_ secret: String, account: String) {
        delete(account: account)
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(secret.utf8),
        ]
        SecItemAdd(item as CFDictionary, nil)
    }

    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
