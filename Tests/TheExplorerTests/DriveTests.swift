import AppKit
import Foundation
import Testing
@testable import TheExplorer

struct DriveModelTests {
    private let account = UUID()

    @Test func locationURLsRoundTripNamesAndFolders() throws {
        let names = ["Q3 report.pdf", "a/b: c?", "Ünïcødé 😀", "C++ & notes #1", "%20 literally"]
        for name in names {
            for isFolder in [true, false] {
                let url = DriveLocation.url(accountID: account, id: "1AbC-_x", name: name, isFolder: isFolder)
                let location = try #require(DriveLocation(url: url))
                #expect(location.accountID == account)
                #expect(location.id == "1AbC-_x")
                #expect(location.name == name)
                #expect(location.isFolder == isFolder)
                #expect(location.url == url)
            }
        }
        // The file's name and extension are what the rest of the app reads off the URL.
        let file = DriveLocation.url(accountID: account, id: "x", name: "teaser cut.mp4", isFolder: false)
        #expect(file.lastPathComponent == "teaser cut.mp4")
        #expect(file.pathExtension == "mp4")
        #expect(DriveLocation(url: URL(string: "x-s3://\(account.uuidString)/bucket/key")!) == nil)
        #expect(DriveLocation(accountID: account, id: DriveLocation.sharedID, name: "Shared with me").isVirtual)
        #expect(!DriveLocation(accountID: account, id: DriveLocation.myDriveID, name: "My Drive").isVirtual)
    }

    @Test func filesParseFromDriveJSON() throws {
        let json: [String: Any] = [
            "id": "f1", "name": "Budget", "mimeType": "application/vnd.google-apps.spreadsheet",
            "modifiedTime": "2026-10-01T10:00:00.123Z", "createdTime": "2026-01-15T08:30:00Z", "parents": ["root-id"],
            "webViewLink": "https://docs.google.com/x", "owners": [["displayName": "Ada"]],
            "capabilities": ["canAddChildren": false, "canRename": true, "canTrash": false],
        ]
        let sheet = try #require(DriveFile(json: json))
        #expect(sheet.isGoogleDoc && !sheet.isFolder)
        #expect(sheet.googleKind == "Google Sheets")
        #expect(sheet.size == nil)
        #expect(sheet.owner == "Ada")
        #expect(!sheet.canTrash && !sheet.canAddChildren)
        #expect(abs((sheet.modified?.timeIntervalSince1970 ?? 0) - 1_790_848_800.123) < 0.001)
        #expect(sheet.created == Date(timeIntervalSince1970: 1_768_465_800))
        #expect(sheet.uniformType?.preferredMIMEType == "application/vnd.google-apps.spreadsheet")

        let shortcut = try #require(DriveFile(json: ["id": "s", "name": "Projects", "mimeType": "application/vnd.google-apps.shortcut",
                                                    "shortcutDetails": ["targetId": "p", "targetMimeType": DriveFile.folderType]]))
        #expect(shortcut.isShortcut && shortcut.isFolder && shortcut.contentID == "p")

        let video = try #require(DriveFile(json: ["id": "v", "name": "clip.mov", "mimeType": "video/quicktime", "size": "123456789"]))
        #expect(video.size == 123_456_789)
        #expect(video.uniformType == .quickTimeMovie)
        #expect(DriveFile(json: ["name": "no id"]) == nil)
    }

    @Test @MainActor func googleFilesGetTheirOwnChips() {
        let doc = FileItem(url: DriveLocation.url(accountID: account, id: "d", name: "Plan", isFolder: false), name: "Plan",
                           isDirectory: false, contentType: DriveFile(id: "d", name: "Plan", mimeType: DriveFile.googlePrefix + "document").uniformType)
        #expect(TypeChip.style(for: doc).label == "DOC")
    }

    @Test func exportsPickOfficeFormatsFirst() {
        let doc = DriveExport.formats(for: DriveFile.googlePrefix + "document")
        #expect(doc.first?.fileExtension == "docx")
        #expect(doc.contains(.pdf))
        #expect(DriveExport.formats(for: DriveFile.googlePrefix + "spreadsheet").first?.fileExtension == "xlsx")
        #expect(DriveExport.formats(for: DriveFile.googlePrefix + "form").isEmpty)
        #expect(DriveExport.pdf.fileName(for: "Q3") == "Q3.pdf")
        #expect(DriveExport.pdf.fileName(for: "Scan.PDF") == "Scan.PDF")
    }

    @Test func queriesAndNamesAreEscaped() {
        #expect(DriveClient.quoted("it's a \\ test") == #"'it\'s a \\ test'"#)
        #expect(DriveClient.encode("a+b c/d") == "a%2Bb%20c%2Fd")
        #expect(Transfers.localName("Q3/Q4 plan") == "Q3:Q4 plan")
        #expect(Transfers.localName("  ") == "Untitled")
        #expect(Transfers.localName("..") == "Untitled")
    }

    @Test func thumbnailLinksAskForBiggerSizes() {
        #expect(DriveClient.sized("https://lh3.googleusercontent.com/drive-storage/AJQ=s220", 900) == "https://lh3.googleusercontent.com/drive-storage/AJQ=s900")
        #expect(DriveClient.sized("https://lh3.googleusercontent.com/abc=s220-c-k-no", 900) == "https://lh3.googleusercontent.com/abc=s900")
        #expect(DriveClient.sized("https://example.com/thumb.png", 900) == "https://example.com/thumb.png")
    }

    @Test func textPreviewsKeepWholeLinesAndSkipBinary() throws {
        guard case .text(let text, true) = try #require(RemotePreviews.text(from: Data("one\ntwo\nthr".utf8), truncated: true)) else {
            Issue.record("Expected text")
            return
        }
        #expect(text == "one\ntwo")
        // A multi-byte character cut in half at the end of the range is dropped with its line.
        let cut = Data("héllo\nwörld".utf8).dropLast(1)
        guard case .text(let partial, _) = try #require(RemotePreviews.text(from: Data(cut), truncated: true)) else { return }
        #expect(partial == "héllo")
        #expect(RemotePreviews.text(from: Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01]), truncated: false) == nil)

        // Only as much as the card shows: a long log stops at a line limit, minified JSON at a length.
        let log = Data((0..<1000).map { "line \($0)\n" }.joined().utf8)
        guard case .text(let head, true) = try #require(RemotePreviews.text(from: log, truncated: false)) else { return }
        #expect(head.split(separator: "\n").count == RemotePreviews.previewLines)
        #expect(head.hasSuffix("line \(RemotePreviews.previewLines - 1)"))
        let minified = Data(("{" + String(repeating: "\"k\":1,", count: 6000) + "}").utf8)
        guard case .text(let json, true) = try #require(RemotePreviews.text(from: minified, truncated: false)) else { return }
        #expect(json.count == RemotePreviews.previewCharacters)
        guard case .text(let short, false) = try #require(RemotePreviews.text(from: Data("a\nb\n".utf8), truncated: false)) else { return }
        #expect(short == "a\nb\n")
    }

    @Test func errorsSayWhatToDo() {
        let disabled = Data(#"{"error": {"code": 403, "message": "Drive API has not been used", "errors": [{"reason": "accessNotConfigured"}]}}"#.utf8)
        let error = DriveClient.error(403, disabled)
        #expect(error.reason == "accessNotConfigured")
        #expect(error.message.contains("Enable it in Google Cloud Console"))
        #expect(DriveClient.isRetryable(DriveClient.error(429, Data())))
        #expect(DriveClient.isRetryable(DriveClient.error(403, Data(#"{"error": {"errors": [{"reason": "userRateLimitExceeded"}]}}"#.utf8))))
        #expect(!DriveClient.isRetryable(error))
    }

    @Test func clientFilesAndSignInRequests() throws {
        let file = Data(#"{"installed": {"client_id": "123-abc.apps.googleusercontent.com", "client_secret": "GOCSPX-xyz", "redirect_uris": ["http://localhost"]}}"#.utf8)
        let client = try GoogleClient(json: file)
        #expect(client == GoogleClient(id: "123-abc.apps.googleusercontent.com", secret: "GOCSPX-xyz"))
        #expect(throws: DriveError.self) { try GoogleClient(json: Data(#"{"type": "service_account"}"#.utf8)) }

        // Computed independently (Python's hashlib): base64url(SHA-256(verifier)), unpadded.
        #expect(GoogleOAuth.challenge(for: "dBjftJeZ4CVP-mJ92IyrJ1rQ6WT0Lsjxe6fHB5gtY2c") == "CqIyJ7dJlI52HLdzxapvdtzEKcP6ROzR_2CfUMxpcMA")
        #expect(GoogleOAuth.randomString(bytes: 32).count == 43)

        let url = GoogleOAuth.authorizationURL(client: client, redirect: "http://127.0.0.1:5000", challenge: "abc", state: "s1")
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items["client_id"] == client.id)
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["scope"] == "https://www.googleapis.com/auth/drive")
        #expect(items["access_type"] == "offline")
        #expect(items["redirect_uri"] == "http://127.0.0.1:5000")
        #expect(GoogleOAuth.formEncoded(["b": "x y", "a": "1+2&"]) == "a=1%2B2%26&b=x%20y")
    }

    @Test @MainActor func promisesExportGoogleDocsAsOfficeFiles() throws {
        let doc = DriveFile(id: "doc-promise", name: "Launch plan", mimeType: DriveFile.googlePrefix + "document")
        DriveStore.shared.remember([doc], in: nil, accountID: account)
        let url = DriveLocation.url(accountID: account, id: doc.id, name: doc.name, isFolder: false)
        let promise = try #require(RemoteFilePromise(url))
        #expect(promise.fileType == "org.openxmlformats.wordprocessingml.document")
        #expect(promise.delegate?.filePromiseProvider(promise, fileNameForType: promise.fileType) == "Launch plan.docx")
        let folder = try #require(RemoteFilePromise(DriveLocation.url(accountID: account, id: "f", name: "Photos", isFolder: true)))
        #expect(folder.fileType == "public.folder")
        // Lists like Shared with me aren't things that can be dropped.
        #expect(RemoteFilePromise(DriveLocation(accountID: account, id: DriveLocation.sharedID, name: "Shared with me").url) == nil)
    }
}

/// Runs against scripts/mock-drive.py when EXPLORER_DRIVE_ENDPOINT is set, e.g.
/// `python3 scripts/mock-drive.py 5056` and EXPLORER_DRIVE_ENDPOINT=http://127.0.0.1:5056.
/// Skipped otherwise. The mock keeps state, so each test makes its own folder.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["EXPLORER_DRIVE_ENDPOINT"] != nil), .serialized)
struct DriveClientTests {
    private let google = GoogleClient(id: "test.apps.googleusercontent.com", secret: "test-secret")
    private let work = FileManager.default.temporaryDirectory.appendingPathComponent("DriveClientTests-\(UUID().uuidString)")

    private func client(refresh: String = "refresh-test") -> DriveClient {
        DriveClient(auth: GoogleAuth(client: google, refreshToken: refresh))
    }

    @Test @MainActor func signsInThroughTheLoopbackWithPKCE() async throws {
        let tokens = try await GoogleOAuth.signIn(client: google)
        #expect(tokens.refreshToken == "refresh-test")
        #expect(tokens.accessToken.hasPrefix("access-"))
        #expect(tokens.expires > Date().addingTimeInterval(3000))
        await #expect(throws: DriveError.self) { try await GoogleOAuth.signIn(client: GoogleClient(id: "x", secret: "wrong")) }
    }

    @Test func revokedSignInsSaySignInAgain() async throws {
        do {
            _ = try await client(refresh: "revoked").about()
            Issue.record("Expected an error")
        } catch let error as DriveError {
            #expect(error.reason == "invalid_grant")
            #expect(error.message.contains("Sign in again"))
        }
    }

    @Test func listsFoldersListsAndSearches() async throws {
        let drive = client()
        let about = try await drive.about()
        #expect(about.email == "test@example.com")
        #expect(about.limit == Int64(15) << 30)

        let root = try await drive.list(in: "root")
        // Folders first (a shortcut to one isn't a folder to Drive).
        #expect(root.files.prefix(2).allSatisfy { $0.isFolder })
        #expect(root.files.contains { $0.name == "Budget" && $0.isGoogleDoc })
        #expect(root.files.first { $0.name == "notes.txt" }?.size == 19)
        #expect(root.files.first { $0.name == "Projects shortcut" }?.contentID == "projects")
        #expect(try await drive.sharedWithMe().files.map(\.name) == ["Wedding invite.pdf"])
        #expect(try await drive.starred().files.map(\.name) == ["Projects"])
        #expect(try await drive.drives().drives.map(\.name) == ["Team"])
        #expect(try await drive.search("milk").files.map(\.name) == ["notes.txt"])
        #expect(try await drive.search("it's").files.isEmpty)
        #expect(try await drive.file("root").id == "root-id")

        do {
            _ = try await drive.file("nope")
            Issue.record("Expected an error")
        } catch let error as DriveError {
            #expect(error.status == 404)
            #expect(error.message.hasPrefix("Not found in Drive"))
        }
    }

    @Test func uploadsDownloadsExportsAndChanges() async throws {
        let drive = client()
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let folder = try await drive.createFolder(named: "Test \(UUID().uuidString.prefix(6))", in: "root")
        #expect(folder.isFolder)

        let source = work.appendingPathComponent("hello world+.txt")
        try Data(repeating: 65, count: 300_000).write(to: source)
        let uploaded = try await drive.upload(file: source, named: source.lastPathComponent, into: folder.id) { _ in }
        #expect(uploaded.name == "hello world+.txt")
        #expect(uploaded.size == 300_000)
        #expect(try await drive.list(in: folder.id).files.map(\.name) == ["hello world+.txt"])

        let back = work.appendingPathComponent("back.txt")
        try await drive.download(uploaded.id, to: back) { _, _ in }
        #expect(try Data(contentsOf: back) == Data(contentsOf: source))

        // Previews read just the start of a file.
        let head = try await drive.data(uploaded.id, range: 0...9)
        #expect(head == Data(repeating: 65, count: 10))
        let thumbnail = try await drive.thumbnail(try #require(try await drive.file("report").thumbnailLink), size: 300)
        #expect(thumbnail.starts(with: Data([0x89, 0x50, 0x4E, 0x47])))

        let pdf = work.appendingPathComponent("plan.pdf")
        try await drive.export("plan", as: .pdf, to: pdf) { _, _ in }
        #expect(try Data(contentsOf: pdf).starts(with: Data("%PDF".utf8)))
        do {
            try await drive.download("plan", to: work.appendingPathComponent("raw")) { _, _ in }
            Issue.record("Google Docs shouldn't download as they are")
        } catch let error as DriveError {
            #expect(error.reason == "fileNotDownloadable")
        }

        let renamed = try await drive.rename(uploaded.id, to: "renamed.txt")
        #expect(renamed.name == "renamed.txt")
        let sub = try await drive.createFolder(named: "Sub", in: folder.id)
        let moved = try await drive.move(uploaded.id, from: [folder.id], to: sub.id)
        #expect(moved.parents == [sub.id])
        let copy = try await drive.copy(uploaded.id, named: "Copy of renamed.txt", to: sub.id)
        #expect(Set(try await drive.list(in: sub.id).files.map(\.name)) == ["renamed.txt", "Copy of renamed.txt"])
        try await drive.trash(copy.id)
        #expect(try await drive.list(in: sub.id).files.map(\.name) == ["renamed.txt"])
    }
}
