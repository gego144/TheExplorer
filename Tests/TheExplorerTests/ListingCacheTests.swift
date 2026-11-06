import Foundation
import Testing
@testable import TheExplorer

@MainActor
struct ListingCacheTests {
    private func items(_ count: Int, in folder: String) -> [FileItem] {
        (0..<count).map { FileItem(url: URL(fileURLWithPath: "/\(folder)/\($0)"), name: "\($0)", isDirectory: false) }
    }

    @Test func keepsTheFoldersUsedMostRecently() {
        let cache = ListingCache(maxFolders: 2)
        let a = URL(fileURLWithPath: "/a"), b = URL(fileURLWithPath: "/b"), c = URL(fileURLWithPath: "/c")
        cache.store(items(1, in: "a"), folder: nil, for: a)
        cache.store(items(1, in: "b"), folder: nil, for: b)
        // Looking at a makes b the oldest, so c pushes b out.
        #expect(cache.entry(for: a) != nil)
        cache.store(items(1, in: "c"), folder: nil, for: c)
        #expect(cache.entry(for: a) != nil)
        #expect(cache.entry(for: b) == nil)
        #expect(cache.entry(for: c) != nil)
    }

    @Test func staysUnderItsItemBudget() {
        let cache = ListingCache(maxItems: 10, maxFolderItems: 8)
        cache.store(items(6, in: "a"), folder: nil, for: URL(fileURLWithPath: "/a"))
        cache.store(items(6, in: "b"), folder: nil, for: URL(fileURLWithPath: "/b"))
        #expect(cache.entry(for: URL(fileURLWithPath: "/a")) == nil)
        #expect(cache.entry(for: URL(fileURLWithPath: "/b"))?.items.count == 6)
        // Too big to keep at all, and an older listing of it goes too.
        cache.store(items(9, in: "b"), folder: nil, for: URL(fileURLWithPath: "/b"))
        #expect(cache.entry(for: URL(fileURLWithPath: "/b")) == nil)
    }

    @Test func aFolderVisitedBeforeShowsAtOnceAndThenCatchesUp() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ListingCacheTests-\(UUID().uuidString)")
        let first = root.appendingPathComponent("first"), second = root.appendingPathComponent("second")
        for folder in [first, second] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: first.appendingPathComponent("one.txt"))

        let model = BrowserModel(url: first)
        model.start()
        #expect(await eventually { model.items.map(\.name) == ["one.txt"] })
        model.navigate(to: second)
        #expect(await eventually { !model.isLoading && model.items.isEmpty })

        // Changed while you were away: the old listing shows straight away, the new one follows.
        try Data().write(to: first.appendingPathComponent("two.txt"))
        model.navigate(to: first)
        #expect(model.items.map(\.name) == ["one.txt"])
        #expect(await eventually { Set(model.items.map(\.name)) == ["one.txt", "two.txt"] })
    }

    @Test func aNewTabStartsWithTheFolderItWasOpenedFrom() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ListingCacheTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("a.txt"))

        let model = BrowserModel(url: root)
        model.start()
        #expect(await eventually { !model.isLoading && model.items.count == 1 })
        let tab = BrowserModel(url: root)
        tab.seed(from: model)
        #expect(tab.rows.map(\.item.name) == ["a.txt"])
        #expect(tab.folderItem?.url == model.folderItem?.url)
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }
}
