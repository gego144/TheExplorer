import Foundation
import Testing
@testable import TheExplorer

/// Drive folders listed recently show at once when you go back to them.
@MainActor
struct DriveListingCacheTests {
    private let account = UUID()

    private func folder(_ id: String) -> DriveLocation { DriveLocation(accountID: account, id: id, name: id) }
    private func file(_ id: String) -> DriveFile { DriveFile(json: ["id": id, "name": id, "mimeType": "text/plain"])! }

    @Test func remembersRecentFoldersAndForgetsTheOldest() {
        let cache = DriveListingCache.shared
        cache.store(folder("first"), files: [file("a")], drives: [], nextToken: "more")
        #expect(cache.entry(for: folder("first"))?.files.map(\.id) == ["a"])
        #expect(cache.entry(for: folder("first"))?.nextToken == "more")
        for number in 0..<DriveListingCache.limit { cache.store(folder("f\(number)"), files: [], drives: [], nextToken: nil) }
        #expect(cache.entry(for: folder("first")) == nil)
        #expect(cache.entry(for: folder("f0")) != nil)
        // Another account's folder with the same id is a different folder.
        #expect(cache.entry(for: DriveLocation(accountID: UUID(), id: "f0", name: "f0")) == nil)
    }

    @Test func aChangeInAFolderForgetsIt() async {
        let cache = DriveListingCache.shared
        cache.store(folder("changed"), files: [file("a")], drives: [], nextToken: nil)
        NotificationCenter.default.post(name: .driveChanged, object: folder("changed"))
        #expect(cache.entry(for: folder("changed")) == nil)
    }
}
