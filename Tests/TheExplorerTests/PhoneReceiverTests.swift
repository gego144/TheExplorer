import Foundation
import Testing
@testable import TheExplorer

struct PhoneReceiverTests {
    @Test func parsesRequestHeads() throws {
        let raw = "POST /upload?t=abc&name=IMG%201.HEIC HTTP/1.1\r\nHost: mac.local:47391\r\nContent-Length: 1234\r\nX-Thing:  spaced  "
        let head = try #require(HTTPRequestHead(Data(raw.utf8)))
        #expect(head.method == "POST")
        #expect(head.path == "/upload")
        #expect(head.query["t"] == "abc")
        #expect(head.query["name"] == "IMG 1.HEIC")
        #expect(head.contentLength == 1234)
        #expect(head.headers["x-thing"] == "spaced")
        #expect(HTTPRequestHead(Data("garbage".utf8)) == nil)
    }

    @Test func namesStayInTheFolder() {
        #expect(PhoneReceiver.safeName("IMG_0001.HEIC") == "IMG_0001.HEIC")
        #expect(PhoneReceiver.safeName("../../etc/passwd") == "passwd")
        #expect(PhoneReceiver.safeName(".hidden") == "hidden")
        #expect(PhoneReceiver.safeName("..") == "Photo")
        #expect(PhoneReceiver.safeName("") == "Photo")
        #expect(PhoneReceiver.safeName(nil) == "Photo")
        #expect(PhoneReceiver.safeName("a:b.jpg") == "a-b.jpg")
    }

    @Test func tokensMustMatchExactly() {
        #expect(PhoneReceiver.tokenMatches("abc123", "abc123"))
        #expect(!PhoneReceiver.tokenMatches("abc124", "abc123"))
        #expect(!PhoneReceiver.tokenMatches("abc12", "abc123"))
        #expect(!PhoneReceiver.tokenMatches(nil, "abc123"))
        #expect(!PhoneReceiver.tokenMatches("", ""))
    }

    // MARK: The running server

    private struct Running {
        let server: PhoneReceiver
        let base: URL
        let folder: URL
        let token = "0123456789abcdef0123456789abcdef"
    }

    private func startServer() async throws -> Running {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PhoneReceiverTests-\(UUID().uuidString)")
        let port = UInt16.random(in: 50_000...60_000)
        let token = "0123456789abcdef0123456789abcdef"
        let server = PhoneReceiver(config: .init(port: port, token: token, folder: folder, macName: "Test Mac"), events: .init())
        server.start()
        let base = URL(string: "http://127.0.0.1:\(port)")!
        // Waits for it to listen.
        for _ in 0..<50 {
            if (try? await URLSession.shared.data(from: base.appending(path: "ping"))) != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        return Running(server: server, base: base, folder: folder)
    }

    private func upload(_ data: Data, name: String, to running: Running, token: String? = nil) async throws -> (Int, Data) {
        var components = URLComponents(url: running.base.appending(path: "upload"), resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "t", value: token ?? running.token), .init(name: "name", value: name),
                                 .init(name: "modified", value: "1757840079000")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        let (body, response) = try await URLSession.shared.upload(for: request, from: data)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, body)
    }

    @Test func receivesFilesIntoTheFolder() async throws {
        let running = try await startServer()
        defer {
            running.server.stop()
            try? FileManager.default.removeItem(at: running.folder)
        }
        // Big enough to arrive in many pieces.
        let photo = Data((0..<5_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let (status, _) = try await upload(photo, name: "IMG_0001.HEIC", to: running)
        #expect(status == 200)
        #expect(try Data(contentsOf: running.folder.appendingPathComponent("IMG_0001.HEIC")) == photo)
        // Dated now, so it's at the top of the folder; when it was taken is its creation date.
        let values = try running.folder.appendingPathComponent("IMG_0001.HEIC").resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
        #expect(try #require(values.contentModificationDate).timeIntervalSinceNow > -60)
        #expect(try #require(values.creationDate).timeIntervalSince1970 == 1_757_840_079)

        // The same name again keeps both.
        let (again, body) = try await upload(Data("second".utf8), name: "IMG_0001.HEIC", to: running)
        #expect(again == 200)
        #expect(String(decoding: body, as: UTF8.self).contains("IMG_0001 2.HEIC"))
        #expect(try String(contentsOf: running.folder.appendingPathComponent("IMG_0001 2.HEIC"), encoding: .utf8) == "second")

        // A name that tries to climb out lands inside, and no temporary files are left.
        let (climb, _) = try await upload(Data("x".utf8), name: "../../escape.jpg", to: running)
        #expect(climb == 200)
        #expect(FileManager.default.fileExists(atPath: running.folder.appendingPathComponent("escape.jpg").path))
        let names = try FileManager.default.contentsOfDirectory(atPath: running.folder.path)
        #expect(!names.contains { $0.hasSuffix(".part") })
    }

    @Test func refusesTheWrongToken() async throws {
        let running = try await startServer()
        defer {
            running.server.stop()
            try? FileManager.default.removeItem(at: running.folder)
        }
        let (status, _) = try await upload(Data("x".utf8), name: "a.jpg", to: running, token: "wrong")
        #expect(status == 403)
        #expect(!FileManager.default.fileExists(atPath: running.folder.appendingPathComponent("a.jpg").path))

        let (page, _) = try await URLSession.shared.data(from: running.base)
        #expect(!String(decoding: page, as: UTF8.self).contains("Choose Photos"))
    }

    @Test func servesThePageWithTheToken() async throws {
        let running = try await startServer()
        defer { running.server.stop() }
        let (page, response) = try await URLSession.shared.data(from: URL(string: running.base.absoluteString + "/?t=\(running.token)")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let html = String(decoding: page, as: UTF8.self)
        #expect(html.contains("Send to Test Mac"))
        #expect(html.contains("Choose Photos"))
    }
}
