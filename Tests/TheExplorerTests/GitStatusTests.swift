import Foundation
import Testing
@testable import TheExplorer

struct GitStatusTests {
    private func porcelain(_ records: [String]) -> Data {
        Data(records.joined(separator: "\0").utf8 + [0])
    }

    @Test func readsStatus() {
        let output = porcelain([
            "# branch.oid ed6d5e2abc66057fb9c5f5d8dac60b5b529e02ee",
            "# branch.head dev",
            "# branch.upstream origin/dev",
            "# branch.ab +2 -1",
            "1 .M N... 100644 100644 100644 aaa aaa src/app/page.tsx",
            "1 A. N... 000000 100644 100644 000 bbb src/new file.ts",
            "1 D. N... 100644 000000 000000 ccc 000 docs/old.md",
            "2 R. N... 100644 100644 100644 ddd ddd R100 src/renamed.ts", "src/original.ts",
            "u UU N... 100644 100644 100644 100644 e1 e2 e3 package.json",
            "? notes.txt",
            "? scratch/",
            "! node_modules/",
            "! .env",
        ])
        let snapshot = GitSnapshot.parse(output, root: "/repo")
        #expect(snapshot.branch == "dev")
        #expect(snapshot.commit == "ed6d5e2")
        #expect(snapshot.upstream == "origin/dev")
        #expect(snapshot.ahead == 2 && snapshot.behind == 1)
        #expect(snapshot.changes["/repo/src/app/page.tsx"] == .modified)
        #expect(snapshot.changes["/repo/src/new file.ts"] == .added)
        #expect(snapshot.changes["/repo/docs/old.md"] == .deleted)
        #expect(snapshot.changes["/repo/src/renamed.ts"] == .renamed)
        #expect(snapshot.changes["/repo/src/original.ts"] == nil)
        #expect(snapshot.changes["/repo/package.json"] == .conflicted)
        #expect(snapshot.changes["/repo/notes.txt"] == .untracked)
        #expect(snapshot.changeCount == 7)

        #expect(snapshot.mark(for: "/repo/src/app/page.tsx") == .changed(.modified))
        #expect(snapshot.mark(for: "/repo/scratch") == .changed(.untracked))
        #expect(snapshot.mark(for: "/repo/scratch/deep/idea.md") == .changed(.untracked))
        #expect(snapshot.mark(for: "/repo/node_modules") == .ignored)
        #expect(snapshot.mark(for: "/repo/node_modules/react/index.js") == .ignored)
        #expect(snapshot.mark(for: "/repo/.env") == .ignored)
        // Folders show the worst change inside and how many.
        #expect(snapshot.mark(for: "/repo/src") == .contains(.modified, count: 3))
        #expect(snapshot.mark(for: "/repo/docs") == .contains(.deleted, count: 1))
        #expect(snapshot.mark(for: "/repo") == .contains(.conflicted, count: 7))
        #expect(snapshot.mark(for: "/repo/README.md") == nil)
        #expect(snapshot.mark(for: "/elsewhere/file") == nil)
    }

    @Test func detachedHead() {
        let snapshot = GitSnapshot.parse(porcelain(["# branch.oid 1234567890abcdef", "# branch.head (detached)"]), root: "/r")
        #expect(snapshot.branch == nil)
        #expect(snapshot.commit == "1234567")
    }

    @Test func realRepository() throws {
        let git = try #require(Git.executable)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GitStatusTests-\(UUID().uuidString)").resolvingSymlinksInPath().path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        func write(_ path: String, _ text: String) throws {
            let url = URL(fileURLWithPath: root + "/" + path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        func run(_ arguments: [String]) { _ = Git.run(git, in: root, arguments) }
        run(["init", "-q", "-b", "main"])
        try write("README.md", "hello")
        try write("src/app.ts", "one")
        try write(".gitignore", "build/\n")
        run(["add", "."])
        run(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-q", "-m", "first"])
        try write("src/app.ts", "two")
        try write("todo.txt", "new")
        try write("build/out.js", "generated")

        #expect(Git.enclosingRepository(of: root + "/src") == root)
        let output = try #require(Git.run(git, in: root, ["status", "--porcelain=v2", "--branch", "-z", "--ignored=matching", "--untracked-files=normal"]))
        let snapshot = GitSnapshot.parse(output, root: root)
        #expect(snapshot.branch == "main")
        #expect(snapshot.mark(for: root + "/src/app.ts") == .changed(.modified))
        #expect(snapshot.mark(for: root + "/src") == .contains(.modified, count: 1))
        #expect(snapshot.mark(for: root + "/todo.txt") == .changed(.untracked))
        #expect(snapshot.mark(for: root + "/build") == .ignored)
        #expect(snapshot.mark(for: root + "/build/out.js") == .ignored)
        #expect(snapshot.mark(for: root + "/README.md") == nil)
    }
}
