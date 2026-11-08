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

        let files = Transfers.expand([root.appendingPathComponent("project"), root.appendingPathComponent("report.pdf")], under: "uploads/")
        #expect(Set(files.map(\.key)) == ["uploads/project/README.md", "uploads/project/src/main.py", "uploads/report.pdf"])
    }

    @Test func downloadsStayInsideTheirFolder() {
        let folder = URL(fileURLWithPath: "/tmp/downloads")
        #expect(Transfers.safeDestination("a/../../etc/passwd", in: folder).path == "/tmp/downloads/a/etc/passwd")
        #expect(Transfers.safeDestination("photos/2026/x.jpg", in: folder).path == "/tmp/downloads/photos/2026/x.jpg")
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
        let promise = try #require(RemoteFilePromise(file))
        #expect(promise.fileType == "public.mpeg-4")
        #expect(promise.delegate?.filePromiseProvider(promise, fileNameForType: promise.fileType) == "teaser cut.mp4")
        let folder = try #require(RemoteFilePromise(S3Location.url(connectionID: id, bucket: "media", key: "videos/")))
        #expect(folder.fileType == "public.folder")
        // Drops inside the app still read the S3 address off the drag.
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("S3ItemNameTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([promise])
        #expect(pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] == [file])
        // A connection's top level (no bucket) can't be dropped as a file.
        #expect(RemoteFilePromise(S3Location.url(connectionID: id, bucket: nil, key: "")) == nil)
    }

    /// Find in S3 searches the names read from the bucket: files at any depth, and folders on the
    /// way, by name, under the folder searched from.
    @Test func searchMatchesNamesAtAnyDepth() {
        let page = S3KeyPage([
            S3Object(key: "trips/", size: 0),
            S3Object(key: "trips/Receipts.pdf", size: 10),
            S3Object(key: "trips/2026/rome/receipts-rome.pdf", size: 20),
            S3Object(key: "trips/2026/receipts/taxi.jpg", size: 30),
            S3Object(key: "trips/2026/receipts/hotel.jpg", size: 40),
            S3Object(key: "trips/2026/photos/beach.jpg", size: 50),
            S3Object(key: "other/receipts-elsewhere.pdf", size: 60),
        ])
        let id = UUID()
        var folders = Set<String>()
        let rows = S3KeyMatcher.matches([page][...], connectionID: id, bucket: "media", prefix: "trips/",
                                        terms: S3KeyMatcher.terms("receipts"), limit: 100, folders: &folders)
        // Case doesn't matter; the folder is listed once though two files are in it; "other/" is outside.
        #expect(rows.map(\.item.name) == ["Receipts.pdf", "receipts-rome.pdf", "receipts"])
        #expect(rows.last?.item.isFolder == true)
        #expect(rows.map(\.location) == ["media/trips", "media/trips/2026/rome", "media/trips/2026"])
        #expect(rows[1].size == 20)
        // Every word has to match.
        var none = Set<String>()
        let rome = S3KeyMatcher.matches([page][...], connectionID: id, bucket: "media", prefix: "",
                                        terms: S3KeyMatcher.terms("receipts rome"), limit: 100, folders: &none)
        #expect(rome.map(\.item.name) == ["receipts-rome.pdf"])
        // It stops at the limit.
        var limited = Set<String>()
        #expect(S3KeyMatcher.matches([page][...], connectionID: id, bucket: "media", prefix: "",
                                     terms: S3KeyMatcher.terms("receipts"), limit: 2, folders: &limited).count == 2)
    }

    /// The bucket is read in ranges split at a key between two others; the split must fall
    /// strictly between them (so no key is read twice or missed), whatever the keys look like.
    @Test @MainActor func rangesSplitBetweenTheirEnds() {
        let pairs = [("", "\u{7F}"), ("photos/", "photos/\u{7F}"), ("jestr/creators/0a1b", "jestr/d"),
                     ("a", "b"), ("instagram-thumbnails/3f", "instagram-thumbnails/9"), ("x/a", "x/a0")]
        for (low, high) in pairs {
            guard let middle = S3KeyIndex.midpoint(low, high) else { continue }
            #expect(middle > low && middle < high, "\(low) < \(middle) < \(high)")
        }
        // Wide ranges always split; neighbours don't.
        #expect(S3KeyIndex.midpoint("photos/", "photos/\u{7F}") != nil)
        #expect(S3KeyIndex.midpoint("a", "a ") == nil)
        #expect(S3KeyIndex.width("a", "z") > S3KeyIndex.width("a", "c"))
    }

    /// S3's dates are read straight from their digits; they must match the formatter exactly.
    @Test func listingDatesMatchTheFormatter() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        for text in ["2024-05-01T12:34:56.000Z", "2026-02-28T23:59:59.999Z", "2024-02-29T00:00:00.500Z",
                     "1999-12-31T23:59:59.000Z", "1969-07-20T20:17:40.000Z", "2100-03-01T01:02:03.250Z"] {
            #expect(S3Client.fastDate(text) == formatter.date(from: text), "\(text)")
        }
        #expect(S3Client.fastDate("2024-05-01T12:34:56Z") == plain.date(from: "2024-05-01T12:34:56Z"))
        // Anything else is left to the formatter.
        #expect(S3Client.fastDate("2024-05-01 12:34:56") == nil)
        #expect(S3Client.fastDate("2024-13-01T00:00:00.000Z") == nil)
        #expect(S3Client.date("2024-05-01T12:34:56+02:00") == plain.date(from: "2024-05-01T12:34:56+02:00"))
    }
}
