import AppKit
import CryptoKit
import Foundation
import Network

/// The OAuth client you make in Google Cloud Console ("Desktop app"). Google calls the secret
/// a secret, but for desktop clients it isn't one; it's kept in the Keychain all the same.
struct GoogleClient: Hashable, Sendable {
    var id: String
    var secret: String

    /// Reads the JSON file Google Cloud Console downloads for a client.
    init(json data: Data) throws {
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let fields = (object?["installed"] ?? object?["web"]) as? [String: Any],
              let id = fields["client_id"] as? String, let secret = fields["client_secret"] as? String else {
            throw DriveError(message: "That isn't a Google OAuth client file. Download it from Credentials in Google Cloud Console (the ⤓ next to your Desktop client).")
        }
        self.init(id: id, secret: secret)
    }

    init(id: String, secret: String) {
        self.id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        self.secret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// An access token and when it runs out, plus the refresh token that gets new ones.
struct GoogleTokens: Sendable {
    var accessToken: String
    var expires: Date
    var refreshToken: String?
}

/// Signing in to Google the way desktop apps do: the browser shows Google's page, and Google
/// sends the answer back to a port on this Mac (127.0.0.1), with PKCE so only we can use it.
enum GoogleOAuth {
    /// Everything in your Drive, which a file manager needs. With your own client, Google shows
    /// an "unverified app" page once instead of requiring a security review.
    static let scope = "https://www.googleapis.com/auth/drive"

    /// Google's servers, or a local stand-in for testing (EXPLORER_DRIVE_ENDPOINT, debug builds).
    static var authEndpoint: URL { endpoint("https://accounts.google.com", path: "/o/oauth2/v2/auth") }
    static var tokenEndpoint: URL { endpoint("https://oauth2.googleapis.com", path: "/token") }
    static var revokeEndpoint: URL { endpoint("https://oauth2.googleapis.com", path: "/revoke") }

    static func endpoint(_ google: String, path: String) -> URL {
        URL(string: (testEndpoint ?? google) + path)!
    }

    static var testEndpoint: String? {
        #if DEBUG
        return ProcessInfo.processInfo.environment["EXPLORER_DRIVE_ENDPOINT"]
        #else
        return nil
        #endif
    }

    static func authorizationURL(client: GoogleClient, redirect: String, challenge: String, state: String) -> URL {
        var components = URLComponents(url: authEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: client.id),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            // A refresh token every time, so signing in again after removing an account works.
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent select_account"),
        ]
        return components.url!
    }

    /// PKCE's challenge for a verifier: base64url(SHA-256(verifier)).
    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func randomString(bytes: Int = 32) -> String {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        return base64URL(data)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Signs in through the browser and hands back the tokens. Cancelling the task stops waiting.
    @MainActor
    static func signIn(client: GoogleClient) async throws -> GoogleTokens {
        let receiver = LoopbackReceiver()
        let port = try await receiver.start()
        defer { receiver.stop() }
        let redirect = "http://127.0.0.1:\(port)"
        let verifier = randomString(bytes: 48)
        let state = randomString(bytes: 16)
        let url = authorizationURL(client: client, redirect: redirect, challenge: challenge(for: verifier), state: state)
        if testEndpoint != nil {
            // The test server answers like a browser that's already signed in; never open one.
            Task.detached { _ = try? await URLSession.shared.data(from: url) }
        } else {
            NSWorkspace.shared.open(url)
        }
        let reply = try await receiver.reply()
        let items = Dictionary(reply.queryItems?.map { ($0.name, $0.value ?? "") } ?? [], uniquingKeysWith: { a, _ in a })
        if let error = items["error"] {
            throw DriveError(message: error == "access_denied" ? "Sign-in was cancelled." : "Google didn't sign you in (\(error)).")
        }
        guard items["state"] == state, let code = items["code"] else {
            throw DriveError(message: "Google's answer didn't match this sign-in. Try again.")
        }
        return try await exchange(code: code, verifier: verifier, redirect: redirect, client: client)
    }

    static func exchange(code: String, verifier: String, redirect: String, client: GoogleClient) async throws -> GoogleTokens {
        try await tokenRequest([
            "grant_type": "authorization_code", "code": code, "code_verifier": verifier, "redirect_uri": redirect,
            "client_id": client.id, "client_secret": client.secret,
        ])
    }

    static func refresh(_ refreshToken: String, client: GoogleClient) async throws -> GoogleTokens {
        var tokens = try await tokenRequest([
            "grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": client.id, "client_secret": client.secret,
        ])
        if tokens.refreshToken == nil { tokens.refreshToken = refreshToken }
        return tokens
    }

    /// Tells Google to forget a sign-in, when you remove the account.
    static func revoke(_ token: String) async {
        var request = URLRequest(url: revokeEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(formEncoded(["token": token]).utf8)
        _ = try? await URLSession.shared.data(for: request)
    }

    private static func tokenRequest(_ form: [String: String]) async throws -> GoogleTokens {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(formEncoded(form).utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (response as? HTTPURLResponse)?.statusCode == 200, let access = json["access_token"] as? String else {
            let code = json["error"] as? String ?? ""
            let detail = json["error_description"] as? String ?? code
            switch code {
            case "invalid_grant":
                throw DriveError(status: 401, reason: code, message: "Google signed this account out (the sign-in expired or was revoked). Sign in again in Settings → Cloud.")
            case "invalid_client", "unauthorized_client":
                throw DriveError(status: 401, reason: code, message: "Google didn't accept the OAuth client. Check its ID and secret in Settings → Cloud.")
            default:
                throw DriveError(status: (response as? HTTPURLResponse)?.statusCode ?? 0, reason: code,
                                 message: "Google sign-in failed" + (detail.isEmpty ? "." : ": \(detail)"))
            }
        }
        let lifetime = (json["expires_in"] as? Double) ?? Double(json["expires_in"] as? Int ?? 3600)
        return GoogleTokens(accessToken: access, expires: Date().addingTimeInterval(lifetime),
                            refreshToken: json["refresh_token"] as? String)
    }

    static func formEncoded(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
    }
}

/// Keeps an account's access token fresh, refreshing it (once, however many requests ask) a
/// minute before it runs out.
actor GoogleAuth {
    private let client: GoogleClient
    private let refreshToken: String
    private var tokens: GoogleTokens?
    private var refreshing: Task<GoogleTokens, Error>?

    init(client: GoogleClient, refreshToken: String) {
        self.client = client
        self.refreshToken = refreshToken
    }

    func token(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh, let tokens, tokens.expires.timeIntervalSinceNow > 60 { return tokens.accessToken }
        if let refreshing { return try await refreshing.value.accessToken }
        let task = Task { [client, refreshToken] in try await GoogleOAuth.refresh(refreshToken, client: client) }
        refreshing = task
        defer { refreshing = nil }
        let fresh = try await task.value
        tokens = fresh
        return fresh.accessToken
    }
}

/// Waits on 127.0.0.1 for the browser to come back from Google's sign-in page.
private final class LoopbackReceiver: @unchecked Sendable {
    private let queue = DispatchQueue(label: "TheExplorer.GoogleSignIn")
    private var listener: NWListener?
    private var starting: CheckedContinuation<UInt16, Error>?
    private var waiting: CheckedContinuation<URLComponents, Error>?
    private var received: Result<URLComponents, Error>?

    /// Starts listening on a free port and returns it.
    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
        return try await withCheckedThrowingContinuation { continuation in
            starting = continuation
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, let starting = self.starting else { return }
                switch state {
                case .ready:
                    self.starting = nil
                    starting.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    self.starting = nil
                    starting.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    /// The query Google redirected with. Gives up after 10 minutes, or when the task is cancelled.
    func reply() async throws -> URLComponents {
        let timeout = DispatchWorkItem { [weak self] in
            self?.finish(.failure(DriveError(message: "Sign-in timed out. Try again.")))
        }
        queue.asyncAfter(deadline: .now() + 600, execute: timeout)
        defer { timeout.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    if let received = self.received {
                        continuation.resume(with: received)
                    } else {
                        self.waiting = continuation
                    }
                }
            }
        } onCancel: {
            self.queue.async { self.finish(.failure(CancellationError())) }
        }
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
        }
    }

    private func finish(_ result: Result<URLComponents, Error>) {
        guard received == nil else { return }
        received = result
        waiting?.resume(with: result)
        waiting = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, _ in
            guard let self else { return }
            let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            // "GET /?code=…&state=… HTTP/1.1"
            let target = request.split(separator: "\r\n").first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let components = URLComponents(string: "http://127.0.0.1" + target)
            let isReply = components?.queryItems?.contains { $0.name == "code" || $0.name == "error" } ?? false
            let ok = isReply && !(components?.queryItems?.contains { $0.name == "error" } ?? false)
            let page = isReply ? Self.page(ok: ok) : ""
            let response = "HTTP/1.1 \(isReply ? "200 OK" : "404 Not Found")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(page.utf8.count)\r\nConnection: close\r\n\r\n" + page
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            if isReply, let components { self.finish(.success(components)) }
        }
    }

    private static func page(ok: Bool) -> String {
        let message = ok ? "You're signed in. You can close this tab and go back to TheExplorer."
                         : "Sign-in didn't finish. You can close this tab and try again in TheExplorer."
        return """
        <!doctype html><meta charset="utf-8"><title>TheExplorer</title>
        <body style="font: 15px -apple-system, sans-serif; background: #111; color: #eee; display: grid; place-items: center; height: 90vh">
        <p>\(message)</p></body>
        """
    }
}
