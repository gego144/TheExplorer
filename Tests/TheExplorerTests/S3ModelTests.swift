import AppKit
import Testing
@testable import TheExplorer

struct S3ModelTests {
    private let connection = UUID()

    @Test func locationsRoundTripThroughURLs() throws {
        let folder = S3Location(connectionID: connection, bucket: "media-assets", prefix: "2026 trip/raw+edits/")
        let parsed = try #require(S3Location(url: folder.url))
        #expect(parsed == folder)
        #expect(parsed.name == "raw+edits")
        #expect(parsed.uri == "s3://media-assets/2026 trip/raw+edits/")
        #expect(parsed.parent == S3Location(connectionID: connection, bucket: "media-assets", prefix: "2026 trip/"))
        #expect(parsed.parent?.parent == S3Location(connectionID: connection, bucket: "media-assets"))
        #expect(parsed.parent?.parent?.parent == S3Location(connectionID: connection, bucket: nil))

        let object = S3Location.url(connectionID: connection, bucket: "media-assets", key: "videos/teaser cut.mp4")
        #expect(object.lastPathComponent == "teaser cut.mp4")
        #expect(S3Location(url: object)?.prefix == "videos/teaser cut.mp4")
        #expect(S3Location(url: URL(fileURLWithPath: "/tmp")) == nil)
    }

    @Test func parsesAWSProfileFiles() {
        let config = """
        [default]
        region = us-west-2

        [profile work]
        region=eu-central-1
        sso_session = corp
        # a comment
        [sso-session corp]
        sso_region = us-east-1
        """
        let sections = AWSProfiles.parse(config)
        #expect(sections["default"]?["region"] == "us-west-2")
        #expect(sections["work"]?["region"] == "eu-central-1")
        #expect(sections["work"]?["sso_session"] == "corp")
        #expect(sections["sso-session corp"] == nil)
        #expect(sections.count == 2)
    }

    @Test func uploadKeysKeepFolderStructure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("S3ModelTests-\(UUID().uuidString)")
        let project = root.appendingPathComponent("project/src", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "a".write(to: root.appendingPathComponent("project/README.md"), atomically: true, encoding: .utf8)
        try "b".write(to: project.appendingPathComponent("main.py"), atomically: true, encoding: .utf8)
        try "c".write(to: root.appendingPathComponent("report.pdf"), atomically: true, encoding: .utf8)
        try Data().write(to: root.appendingPathComponent("project/.DS_Store"))

        let files = S3Transfers.expand([root.appendingPathComponent("project"), root.appendingPathComponent("report.pdf")], under: "uploads/")
        #expect(Set(files.map(\.key)) == ["uploads/project/README.md", "uploads/project/src/main.py", "uploads/report.pdf"])
    }

    @Test func downloadsStayInsideTheirFolder() {
        let folder = URL(fileURLWithPath: "/tmp/downloads")
        #expect(S3Transfers.safeDestination("a/../../etc/passwd", in: folder).path == "/tmp/downloads/a/etc/passwd")
        #expect(S3Transfers.safeDestination("photos/2026/x.jpg", in: folder).path == "/tmp/downloads/photos/2026/x.jpg")
    }

    @Test func addressingStyle() {
        #expect(S3Client.isVirtualHostable("media-assets"))
        #expect(!S3Client.isVirtualHostable("my.bucket.example"))
        let aws = S3Client.url(config: .init(region: "eu-west-1"), region: "eu-west-1", bucket: "media-assets", key: "a b/c.txt", query: [])
        #expect(aws?.absoluteString == "https://media-assets.s3.eu-west-1.amazonaws.com/a%20b/c.txt")
        let custom = S3Client.url(config: .init(region: "auto", endpoint: URL(string: "https://acct.r2.cloudflarestorage.com")), region: "auto",
                                  bucket: "media", key: "x.txt", query: [("list-type", "2")])
        #expect(custom?.absoluteString == "https://acct.r2.cloudflarestorage.com/media/x.txt?list-type=2")
    }
}

struct S3ItemNameTests {
    private let id = UUID()

    @Test func namesFilesFoldersAndBuckets() {
        #expect(S3Location(connectionID: id, bucket: "media", prefix: "videos/teaser cut.mp4").itemName == "teaser cut.mp4")
        #expect(S3Location(connectionID: id, bucket: "media", prefix: "videos/clips/").itemName == "clips")
        #expect(S3Location(connectionID: id, bucket: "media").itemName == "media")
    }

    @Test @MainActor func promisesFilesAndFoldersAndCarriesTheURL() throws {
        let file = S3Location.url(connectionID: id, bucket: "media", key: "videos/teaser cut.mp4")
        let promise = try #require(S3FilePromise(file))
        #expect(promise.fileType == "public.mpeg-4")
        #expect(promise.delegate?.filePromiseProvider(promise, fileNameForType: promise.fileType) == "teaser cut.mp4")
        let folder = try #require(S3FilePromise(S3Location.url(connectionID: id, bucket: "media", key: "videos/")))
        #expect(folder.fileType == "public.folder")
        // Drops inside the app still read the S3 address off the drag.
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("S3ItemNameTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([promise])
        #expect(pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] == [file])
        // A connection's top level (no bucket) can't be dropped as a file.
        #expect(S3FilePromise(S3Location.url(connectionID: id, bucket: nil, key: "")) == nil)
    }
}
