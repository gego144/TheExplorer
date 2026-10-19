import Foundation
import Testing
@testable import TheExplorer

private func score(_ token: String, _ name: String) -> Int? {
    let folded = FuzzyMatcher.fold(name)
    let token = FuzzyMatcher.fold(token)
    return token.withUnsafeBufferPointer { token in
        folded.withUnsafeBufferPointer { folded in
            Array(name.utf8).withUnsafeBufferPointer { original in
                FuzzyMatcher.score(token, name: folded, original: folded.count == original.count ? original : folded)
            }
        }
    }
}

struct FuzzyMatcherTests {
    @Test func ordersKindsOfMatch() throws {
        let exact = try #require(score("readme", "readme"))
        let stem = try #require(score("readme", "README.md"))
        let prefix = try #require(score("read", "README.md"))
        let wordStart = try #require(score("report", "q3-report.pdf"))
        let middle = try #require(score("port", "q3-report.pdf"))
        let fuzzy = try #require(score("qrp", "q3-report.pdf"))
        #expect(exact > stem && stem > prefix && prefix > wordStart && wordStart > middle && middle > fuzzy)
    }

    @Test func findsCamelCaseAndAcronyms() {
        #expect(score("tex", "TheExplorer") != nil)
        #expect(score("fh", "FileHistory.swift") != nil)
        #expect(score("explorer", "TheExplorer")! > score("tex", "TheExplorer")!)
    }

    @Test func rejectsLettersScatteredMidWord() {
        // e, x and p all sit inside other words, so this isn't a plausible match.
        #expect(score("exp", "the_complex_up.txt") == nil || score("exp", "the_complex_up.txt")! < FuzzyMatcher.substring)
        #expect(score("zq", "photo.jpg") == nil)
        #expect(score("xyz", "xy") == nil)
    }

    @Test func ignoresCaseAndAccents() {
        #expect(score("resume", "Résumé.pdf") != nil)
        #expect(score("RESUME", "resume.pdf") == FuzzyMatcher.stem)
    }

    @Test func forgivesTypos() throws {
        // Swapped, missing, extra and wrong letters.
        #expect(score("audit", "audting.mp4") != nil)
        #expect(score("auditing", "audting.mp4") != nil)
        #expect(score("reciept", "receipt.pdf") != nil)
        #expect(score("invoce", "invoice-march.pdf") != nil)
        #expect(score("budgett", "budget.xlsx") != nil)
        #expect(score("scrnshot", "Screenshot 2026-10-01.png") != nil)
        #expect(score("raport", "q3-report.pdf") != nil)
        // In a later word, and against names shorter than the query.
        #expect(score("audit", "team audting notes.txt") != nil)
        #expect(score("audit", "audt") != nil)
    }

    @Test func typosStayStrict() throws {
        // Short words must be exact, the first letter must be right, and one slip is the limit
        // under eight letters.
        #expect(score("cat", "cot.txt") == nil)
        #expect(score("audit", "xaudting") == nil)
        #expect(score("audit", "baudting") == nil)
        #expect(score("audit", "adtiu.txt") == nil)
        #expect(score("report", "rpeotr.pdf") == nil)
        // A real match beats a typo, and a typo at the start beats one later on.
        let exact = try #require(score("audit", "audit.mp4"))
        let typo = try #require(score("audit", "audting.mp4"))
        let laterTypo = try #require(score("audit", "team audting.mp4"))
        #expect(exact > typo && typo > laterTypo)
        #expect(typo > FuzzyMatcher.fuzzyBase + 100)
    }

    @Test func shorterNamesWinTies() throws {
        #expect(try #require(score("budget", "budget-2024.xlsx")) > #require(score("budget", "budget-2024-final-final-v3-copy.xlsx")))
    }
}

/// A throwaway folder tree, removed when the test ends.
private final class Tree {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileIndexTests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func make(_ paths: String...) throws {
        for path in paths {
            let url = root.appendingPathComponent(path)
            if path.hasSuffix("/") {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("x".utf8).write(to: url)
            }
        }
    }

    func path(_ relative: String) -> String { root.appendingPathComponent(relative).path }
}

struct FileIndexTests {
    private func names(_ query: String, _ storage: FileIndex.Storage, under: Int32? = nil, hidden: Bool = false) -> [String] {
        FileIndex.search(query, in: storage, under: under, includeHidden: hidden, limit: 50).map { ($0.path as NSString).lastPathComponent }
    }

    @Test func indexesFilesButNotTheInsidesOfClutter() throws {
        let tree = try Tree()
        try tree.make("Dev/app/README.md", "Dev/app/node_modules/left-pad/README.md", "Dev/app/.git/HEAD",
                      "Dev/Tool.app/Contents/Info.plist", "Docs/report.pdf", ".hidden-file", ".config/settings.json")
        let storage = FileIndex.build(roots: [tree.root.path])

        #expect(names("readme", storage) == ["README.md"])
        // The clutter folders themselves can still be found.
        #expect(names("node_modules", storage) == ["node_modules"])
        #expect(names("tool", storage) == ["Tool.app"])
        #expect(names("info", storage).isEmpty)
        #expect(names("settings", storage, hidden: true).isEmpty)
        #expect(names("hidden", storage).isEmpty)
        #expect(names("hidden", storage, hidden: true) == [".hidden-file"])
        let paths = FileIndex.search("report", in: storage, limit: 5).map(\.path)
        #expect(paths == [tree.path("Docs/report.pdf")])
    }

    @Test func ranksBetterMatchesFirst() throws {
        let tree = try Tree()
        try tree.make("a/notes-old-archive.txt", "b/notes.txt", "c/my notes.md", "d/nightly-outputs-tests.log")
        let storage = FileIndex.build(roots: [tree.root.path])
        #expect(names("notes", storage).prefix(3) == ["notes.txt", "notes-old-archive.txt", "my notes.md"])
    }

    @Test func extraWordsCanMatchEnclosingFolders() throws {
        let tree = try Tree()
        try tree.make("Dev/explorer/README.md", "Work/README.md", "Dev/explorer-notes.md")
        let storage = FileIndex.build(roots: [tree.root.path])
        let hits = FileIndex.search("explorer readme", in: storage, limit: 10).map(\.path)
        #expect(hits == [tree.path("Dev/explorer/README.md")])
        // A word has to match the name itself somewhere; folders alone don't count.
        #expect(names("dev explorer", storage).allSatisfy { $0.lowercased().contains("explorer") })
    }

    @Test func searchesInsideOneFolder() throws {
        let tree = try Tree()
        try tree.make("one/clip.ts", "two/clip.ts", "two/sub/clip-2.ts")
        let storage = FileIndex.build(roots: [tree.root.path])
        let two = try #require(FileIndex.resolve(tree.path("two"), in: storage))
        let hits = FileIndex.search("clip", in: storage, under: two, limit: 10).map(\.path).sorted()
        #expect(hits == [tree.path("two/clip.ts"), tree.path("two/sub/clip-2.ts")])
    }

    @Test func followsChangesOnDisk() throws {
        let tree = try Tree()
        try tree.make("docs/old-name.txt", "docs/keep.txt")
        var storage = FileIndex.build(roots: [tree.root.path])

        try FileManager.default.moveItem(atPath: tree.path("docs/old-name.txt"), toPath: tree.path("docs/new-name.txt"))
        try tree.make("docs/added/deep/inside.txt")
        #expect(FileIndex.update(&storage, folder: tree.path("docs"), recursive: false))
        #expect(names("old-name", storage).isEmpty)
        #expect(names("new-name", storage) == ["new-name.txt"])
        #expect(names("inside", storage) == ["inside.txt"])

        // A change reported for a folder the index hasn't seen yet refreshes its nearest known parent.
        try tree.make("docs/added/deep/deeper/new.txt")
        #expect(FileIndex.update(&storage, folder: tree.path("docs/added/deep/deeper"), recursive: false))
        #expect(names("new.txt", storage).first == "new.txt")

        try FileManager.default.removeItem(atPath: tree.path("docs/added"))
        #expect(FileIndex.update(&storage, folder: tree.path("docs/added"), recursive: false))
        #expect(names("inside", storage).isEmpty)
        #expect(names("keep", storage) == ["keep.txt"])

        // Compacting drops removed entries and keeps everything else findable.
        let compacted = storage.compacted()
        #expect(compacted.removedCount == 0)
        #expect(compacted.liveCount == storage.liveCount)
        #expect(names("keep", compacted) == ["keep.txt"])
        #expect(names("new-name", compacted) == ["new-name.txt"])
        #expect(FileIndex.resolve(tree.path("docs/new-name.txt"), in: compacted) != nil)
    }

    @Test func ignoresChangesInsideSkippedFolders() throws {
        let tree = try Tree()
        try tree.make("app/node_modules/a/index.js")
        var storage = FileIndex.build(roots: [tree.root.path])
        try tree.make("app/node_modules/b/index.js")
        #expect(!FileIndex.update(&storage, folder: tree.path("app/node_modules/b"), recursive: false))
        #expect(names("index", storage).isEmpty)
    }
}

struct FileIndexStoreTests {
    @Test func savedIndexLoadsBackTheSame() throws {
        let tree = try Tree()
        try tree.make("docs/report.pdf", "docs/Résumé.pdf", "app/node_modules/x/index.js", "notes.txt")
        var storage = FileIndex.build(roots: [tree.root.path])
        // Something removed before saving is left out of the file.
        try FileManager.default.removeItem(atPath: tree.path("notes.txt"))
        FileIndex.update(&storage, folder: tree.root.path, recursive: false)
        let file = tree.root.appendingPathComponent("index.bin")

        try FileIndexStore.save(storage, roots: [tree.root.path], eventID: 4242, historyID: "history", to: file)
        let saved = try #require(FileIndexStore.load(from: file))

        #expect(saved.roots == [tree.root.path])
        #expect(saved.eventID == 4242)
        #expect(saved.historyID == "history")
        #expect(saved.storage.removedCount == 0)
        #expect(saved.storage.liveCount == storage.liveCount)
        let report = try #require(FileIndex.resolve(tree.path("docs/report.pdf"), in: saved.storage))
        let original = try #require(FileIndex.resolve(tree.path("docs/report.pdf"), in: storage))
        #expect(saved.storage.times(report) == storage.times(original) && storage.times(original).created > 0)
        for query in ["report", "resume", "node_modules", "notes"] {
            #expect(FileIndex.search(query, in: saved.storage, limit: 10).map(\.path)
                    == FileIndex.search(query, in: storage, limit: 10).map(\.path))
        }
        // Child links are rebuilt, so it keeps following changes.
        var loaded = saved.storage
        try tree.make("docs/later.txt")
        #expect(FileIndex.update(&loaded, folder: tree.path("docs"), recursive: false))
        #expect(FileIndex.search("later", in: loaded, limit: 5).map(\.path) == [tree.path("docs/later.txt")])
    }

    @Test func rejectsDamagedFiles() throws {
        let tree = try Tree()
        try tree.make("a.txt")
        let file = tree.root.appendingPathComponent("index.bin")
        try FileIndexStore.save(FileIndex.build(roots: [tree.root.path]), roots: [tree.root.path], eventID: 1, historyID: nil, to: file)
        let data = try Data(contentsOf: file)
        try data.prefix(data.count / 2).write(to: file)
        #expect(FileIndexStore.load(from: file) == nil)
        try Data("nonsense".utf8).write(to: file)
        #expect(FileIndexStore.load(from: file) == nil)
    }
}

struct IgnoreRulesTests {
    @Test func readsFolderRules() {
        let rules = IgnoreRules.parse("""
        # build output
        /build
        node_modules/
        /[Ll]ibrary/
        **/dist
        docs/_site/
        *.egg-info/
        !keep/
        *
        /*

        """)
        #expect(rules == [
            .init(glob: "build", anchored: true), .init(glob: "node_modules", anchored: false),
            .init(glob: "[Ll]ibrary", anchored: true), .init(glob: "dist", anchored: false),
            .init(glob: "docs/_site", anchored: true), .init(glob: "*.egg-info", anchored: false),
        ])
        let library = rules[2]
        #expect(IgnoreRules.matches(library, name: "Library", relative: "Library"))
        #expect(!IgnoreRules.matches(library, name: "Library", relative: "Assets/Library"))
        #expect(IgnoreRules.matches(rules[3], name: "dist", relative: "packages/web/dist"))
    }

    @Test func skipsIgnoredAndUnityCacheFolders() throws {
        let tree = try Tree()
        try tree.make("site/.git/HEAD", "site/build/assets/cf2149e75d5dc5d6.js", "site/src/build-tools.ts",
                      "site/src/build/keep.ts", "site/README.md",
                      "game/ProjectSettings/ProjectVersion.txt", "game/Library/ShaderCache/cf0a.bin", "game/Assets/Library/notes.txt")
        try "/build\n".write(toFile: tree.path("site/.gitignore"), atomically: true, encoding: .utf8)
        IgnoreRules.shared.reset()
        let storage = FileIndex.build(roots: [tree.root.path])
        let names = { (query: String) in FileIndex.search(query, in: storage, limit: 20).map { ($0.path as NSString).lastPathComponent } }

        #expect(names("cf2149").isEmpty)
        // Anchored to the .gitignore's folder: a "build" deeper down is still indexed.
        #expect(names("keep") == ["keep.ts"])
        #expect(names("shadercache").isEmpty)
        #expect(names("notes") == ["notes.txt"])
        #expect(Set(names("build")).isSuperset(of: ["build", "build-tools.ts"]))
    }

    @Test func findsWhatsNewWithoutClutter() throws {
        let tree = try Tree()
        try tree.make("Dev/app/new.swift", "Dev/app/node_modules/pkg/new.js", "Docs/old.pdf", "Docs/", ".hidden-new",
                      "Inbox/")
        let old = Date(timeIntervalSinceNow: -40 * 86_400)
        // An old file, last changed long ago, then moved into Inbox: its added date is now.
        try tree.make("moved.txt")
        try FileManager.default.setAttributes([.modificationDate: old, .creationDate: old], ofItemAtPath: tree.path("moved.txt"))
        try FileManager.default.setAttributes([.modificationDate: old, .creationDate: old], ofItemAtPath: tree.path("Docs/old.pdf"))
        try FileManager.default.moveItem(atPath: tree.path("moved.txt"), toPath: tree.path("Inbox/moved.txt"))
        let storage = FileIndex.build(roots: [tree.root.path])
        let week = Date(timeIntervalSinceNow: -7 * 86_400)
        let names = { (date: FileIndex.RecentDate, kind: KindFilter) in
            Set(FileIndex.recent(in: storage, scopes: [tree.root.path], since: week, by: date, kind: kind)
                .map { (storage.path($0.index) as NSString).lastPathComponent })
        }

        // Dependency folders' insides and hidden files aren't listed; folders are, unless filtered out.
        #expect(names(.created, .files) == ["new.swift"])
        #expect(!names(.created, .all).contains("new.js") && !names(.created, .all).contains(".hidden-new"))
        #expect(names(.created, .folders).isSuperset(of: ["Dev", "app", "node_modules", "Inbox"]))
        #expect(!names(.modified, .files).contains("old.pdf") && !names(.modified, .files).contains("moved.txt"))
        #expect(names(.added, .files).contains("moved.txt"))
        let added = try #require(FileIndex.addedTime(tree.path("Inbox/moved.txt")))
        #expect(abs(Double(added) - Date().timeIntervalSinceReferenceDate) < 120)
        // Out of scope.
        #expect(FileIndex.recent(in: storage, scopes: ["/nowhere"], since: week, by: .created, kind: .all).isEmpty)
        // Newest first.
        let dates = FileIndex.recent(in: storage, scopes: [tree.root.path], since: week, by: .modified, kind: .all).map(\.date)
        #expect(dates == dates.sorted(by: >))
    }

    @Test func hashNamesRankLower() {
        #expect(FileIndex.hashPenalty(ArraySlice("cf2149e75d5dc5d640913c36b9cfce49.bin".utf8)) == 400)
        #expect(FileIndex.hashPenalty(ArraySlice("b704a70e.8cb7cf31.js".utf8)) == 200)
        #expect(FileIndex.hashPenalty(ArraySlice("deadbeef-facade.txt".utf8)) == 0)
        #expect(FileIndex.hashPenalty(ArraySlice("Screenshot 2026-10-03 at 2.08.54 AM.png".utf8)) == 0)
        #expect(FileIndex.hashPenalty(ArraySlice("cf-notes.md".utf8)) == 0)
    }
}
