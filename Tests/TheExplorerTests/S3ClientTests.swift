import Foundation
import Testing
@testable import TheExplorer

/// Runs against a local S3-compatible server when EXPLORER_S3_TEST_ENDPOINT is set, e.g.
/// `moto_server -p 5055` and EXPLORER_S3_TEST_ENDPOINT=http://127.0.0.1:5055. Skipped otherwise.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["EXPLORER_S3_TEST_ENDPOINT"] != nil))
struct S3ClientTests {
    private let client: S3Client
    private let bucket = "theexplorer-test-\(UUID().uuidString.prefix(8).lowercased())"
    private let work = FileManager.default.temporaryDirectory.appendingPathComponent("S3ClientTests-\(UUID().uuidString)")

    init() throws {
        let endpoint = URL(string: ProcessInfo.processInfo.environment["EXPLORER_S3_TEST_ENDPOINT"] ?? "http://127.0.0.1:5055")!
        client = S3Client(config: .init(region: "us-east-1", endpoint: endpoint)) {
            S3Credentials(accessKeyID: "test", secretAccessKey: "test")
        }
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    private func file(_ name: String, bytes: Int) throws -> URL {
        let url = work.appendingPathComponent(name)
        var data = Data(count: bytes)
        for index in stride(from: 0, to: bytes, by: 4096) { data[index] = UInt8(index / 4096 % 251) }
        try data.write(to: url)
        return url
    }

    @Test func roundTripsFilesAndFolders() async throws {
        try await client.createBucket(bucket)
        #expect(try await client.listBuckets().contains { $0.name == bucket })

        let small = try file("notes 1.txt", bytes: 1234)
        try await client.upload(file: small, bucket: bucket, key: "docs/notes 1.txt") { _ in }
        try await client.createFolder(bucket: bucket, key: "docs/empty")

        let root = try await client.list(bucket: bucket, prefix: "")
        #expect(root.prefixes == ["docs/"])
        let docs = try await client.list(bucket: bucket, prefix: "docs/")
        #expect(docs.prefixes == ["docs/empty/"])
        #expect(docs.objects.map(\.key) == ["docs/notes 1.txt"])
        #expect(docs.objects.first?.size == 1234)

        let back = work.appendingPathComponent("back.txt")
        try await client.download(bucket: bucket, key: "docs/notes 1.txt", to: back) { _, _ in }
        #expect(try Data(contentsOf: back) == Data(contentsOf: small))

        // Previews read just a range, into memory.
        let head = try await client.data(bucket: bucket, key: "docs/notes 1.txt", range: 0...99)
        #expect(head == (try Data(contentsOf: small)).prefix(100))

        // A share link works without credentials.
        let link = try await client.shareURL(bucket: bucket, key: "docs/notes 1.txt", expires: 600)
        let (shared, response) = try await URLSession.shared.data(from: link)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(shared == (try Data(contentsOf: small)))

        try await client.delete(bucket: bucket, keys: try await client.listAll(bucket: bucket, prefix: "docs/").map(\.key))
        #expect(try await client.listAll(bucket: bucket, prefix: "").isEmpty)
    }

    @Test func uploadsLargeFilesInParts() async throws {
        try await client.createBucket(bucket)
        let big = try file("video.mp4", bytes: Int(S3Client.multipartThreshold) + 6_000_000)
        let progress = Progress()
        try await client.upload(file: big, bucket: bucket, key: "big/video.mp4") { sent in progress.completedUnitCount = sent }
        #expect(progress.completedUnitCount == Int64(Int(S3Client.multipartThreshold) + 6_000_000))
        let listed = try await client.listAll(bucket: bucket, prefix: "big/")
        #expect(listed.first?.size == Int64(Int(S3Client.multipartThreshold) + 6_000_000))

        let back = work.appendingPathComponent("video-back.mp4")
        try await client.download(bucket: bucket, key: "big/video.mp4", to: back) { _, _ in }
        #expect(try Data(contentsOf: back) == Data(contentsOf: big))
    }

    @Test func reportsMissingBuckets() async throws {
        await #expect(throws: S3Error.self) {
            _ = try await client.list(bucket: "no-such-bucket-\(UUID().uuidString.prefix(6).lowercased())", prefix: "")
        }
    }
}
