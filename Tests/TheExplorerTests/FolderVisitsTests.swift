import Foundation
import Testing
@testable import TheExplorer

@MainActor
struct FolderVisitsTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func folders(_ names: String...) throws -> (root: URL, urls: [URL]) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderVisitsTests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        let urls = names.map { root.appendingPathComponent($0, isDirectory: true) }
        for url in urls { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        return (root, urls)
    }

    @Test func ranksByFrequencyAndRecency() throws {
        let (root, urls) = try folders("often", "once-today", "once-long-ago")
        defer { try? FileManager.default.removeItem(at: root) }
        let visits = FolderVisits(fileURL: nil)
        for _ in 0..<3 { visits.record(urls[0], now: now.addingTimeInterval(-2 * 86_400)) }
        visits.record(urls[1], now: now.addingTimeInterval(-60))
        visits.record(urls[2], now: now.addingTimeInterval(-60 * 86_400))
        // Three visits two days ago (×½) beat nothing; one a minute ago (×4) beats both.
        #expect(visits.top(3, now: now).map(\.lastPathComponent) == ["once-today", "often", "once-long-ago"])
        #expect(visits.top(3, excluding: [urls[1].path], now: now).map(\.lastPathComponent) == ["often", "once-long-ago"])
    }

    @Test func leavesOutFoldersThatAreGone() throws {
        let (root, urls) = try folders("kept", "deleted")
        defer { try? FileManager.default.removeItem(at: root) }
        let visits = FolderVisits(fileURL: nil)
        visits.record(urls[0], now: now)
        visits.record(urls[1], now: now)
        try FileManager.default.removeItem(at: urls[1])
        #expect(visits.top(5, now: now) == [urls[0]])
    }

    @Test func oldCountsFadeOnceTheTotalIsLarge() {
        let visits = FolderVisits(fileURL: nil)
        let busy = URL(fileURLWithPath: "/tmp/busy")
        let rare = URL(fileURLWithPath: "/tmp/rare")
        visits.record(rare, now: now)
        for _ in 0..<Int(FolderVisits.maxTotal) { visits.record(busy, now: now) }
        // Shrinking dropped the folder visited once; the busy one stays near the cap.
        #expect(visits.visits[rare.path] == nil)
        #expect(visits.visits[busy.path]!.rank <= FolderVisits.maxTotal)
    }

    @Test func savesAndLoads() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("visits-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let visits = FolderVisits(fileURL: file)
        visits.record(URL(fileURLWithPath: "/tmp/somewhere"), now: now)
        visits.saveIfNeeded()
        #expect(FolderVisits(fileURL: file).visits == visits.visits)
    }

    @Test func boostsVisitedFoldersAndWhatsInThem() throws {
        let tree = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderVisitsSearch-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: tree) }
        for path in ["work/client-app/notes.md", "archive/client-app/notes.md", "archive/client-apps-old/x.txt"] {
            let url = tree.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        let storage = FileIndex.build(roots: [tree.path])
        let visited = tree.appendingPathComponent("work/client-app").path

        let visits = FolderVisits(fileURL: nil)
        for _ in 0..<5 { visits.record(URL(fileURLWithPath: visited), now: now) }
        let boosts = visits.searchBoosts(now: now)
        #expect(boosts[visited] != nil)

        let folders = FileIndex.search("client-app", in: storage, boosts: boosts, limit: 5, now: now).map(\.path)
        #expect(folders.first == visited)
        let notes = FileIndex.search("notes", in: storage, boosts: boosts, limit: 5, now: now).map(\.path)
        #expect(notes.first == visited + "/notes.md")
    }
}
