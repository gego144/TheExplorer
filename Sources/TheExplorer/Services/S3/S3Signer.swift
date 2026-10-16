import CryptoKit
import Foundation

struct S3Credentials: Sendable, Equatable {
    var accessKeyID: String
    var secretAccessKey: String
    var sessionToken: String?
    /// When temporary credentials (SSO, assumed roles) stop working.
    var expiration: Date?
}

/// AWS Signature Version 4, as S3 uses it: header signing for requests and query signing for
/// shareable (presigned) links.
enum S3Signer {
    static let unsignedPayload = "UNSIGNED-PAYLOAD"
    static let emptyPayloadHash = sha256Hex(Data())

    /// Adds the date, token and Authorization headers. `headers` must already hold every other
    /// header to be signed (host is taken from the URL).
    static func sign(_ request: inout URLRequest, credentials: S3Credentials, region: String, service: String = "s3",
                     payloadHash: String, date: Date = Date(), signContentHash: Bool = true) {
        let amzDate = timestamp(date)
        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        if signContentHash { request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256") }
        if let token = credentials.sessionToken { request.setValue(token, forHTTPHeaderField: "x-amz-security-token") }
        guard let url = request.url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }

        var headers: [String: String] = ["host": hostHeader(components)]
        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            headers[name.lowercased()] = value.trimmingCharacters(in: .whitespaces)
        }
        let names = headers.keys.sorted()
        let signedHeaders = names.joined(separator: ";")
        let canonicalRequest = [
            request.httpMethod ?? "GET",
            components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath,
            canonicalQuery(components),
            names.map { "\($0):\(headers[$0]!)\n" }.joined(),
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")

        let scope = "\(String(amzDate.prefix(8)))/\(region)/\(service)/aws4_request"
        let signature = self.signature(canonicalRequest: canonicalRequest, amzDate: amzDate, scope: scope,
                                       secret: credentials.secretAccessKey, region: region, service: service)
        request.setValue("AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
                         forHTTPHeaderField: "Authorization")
    }

    /// A URL anyone can GET until it expires (at most 7 days).
    static func presign(_ url: URL, method: String = "GET", credentials: S3Credentials, region: String, service: String = "s3",
                        expires: Int, date: Date = Date()) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let amzDate = timestamp(date)
        let scope = "\(String(amzDate.prefix(8)))/\(region)/\(service)/aws4_request"
        var query = components.percentEncodedQueryItems ?? []
        query += [
            URLQueryItem(name: "X-Amz-Algorithm", value: "AWS4-HMAC-SHA256"),
            URLQueryItem(name: "X-Amz-Credential", value: encode("\(credentials.accessKeyID)/\(scope)")),
            URLQueryItem(name: "X-Amz-Date", value: amzDate),
            URLQueryItem(name: "X-Amz-Expires", value: String(min(max(expires, 1), 604_800))),
            URLQueryItem(name: "X-Amz-SignedHeaders", value: "host"),
        ]
        if let token = credentials.sessionToken {
            query.append(URLQueryItem(name: "X-Amz-Security-Token", value: encode(token)))
        }
        components.percentEncodedQueryItems = query
        let canonicalRequest = [
            method,
            components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath,
            canonicalQuery(components),
            "host:\(hostHeader(components))\n",
            "host",
            unsignedPayload,
        ].joined(separator: "\n")
        let signature = self.signature(canonicalRequest: canonicalRequest, amzDate: amzDate, scope: scope,
                                       secret: credentials.secretAccessKey, region: region, service: service)
        components.percentEncodedQueryItems = query + [URLQueryItem(name: "X-Amz-Signature", value: signature)]
        return components.url
    }

    /// RFC 3986 encoding as AWS wants it: only unreserved characters stay as they are.
    static func encode(_ text: String, keepSlashes: Bool = false) -> String {
        var allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
        if keepSlashes { allowed.insert("/") }
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func signature(canonicalRequest: String, amzDate: String, scope: String, secret: String,
                                  region: String, service: String) -> String {
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            scope,
            sha256Hex(Data(canonicalRequest.utf8)),
        ].joined(separator: "\n")
        var key = SymmetricKey(data: Data("AWS4\(secret)".utf8))
        for part in [String(amzDate.prefix(8)), region, service, "aws4_request"] {
            key = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(part.utf8), using: key)))
        }
        return HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: key).map { String(format: "%02x", $0) }.joined()
    }

    /// Query parameters sorted by name, with names and values encoded (already encoded ones are
    /// decoded first, so nothing is encoded twice).
    private static func canonicalQuery(_ components: URLComponents) -> String {
        let items = (components.percentEncodedQueryItems ?? []).map { item in
            (encode(item.name.removingPercentEncoding ?? item.name), encode((item.value ?? "").removingPercentEncoding ?? item.value ?? ""))
        }
        return items.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
    }

    private static func hostHeader(_ components: URLComponents) -> String {
        let host = components.host ?? ""
        guard let port = components.port else { return host }
        let isDefault = (components.scheme == "https" && port == 443) || (components.scheme == "http" && port == 80)
        return isDefault ? host : "\(host):\(port)"
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }
}
