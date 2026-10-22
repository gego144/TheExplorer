import Foundation
import Testing
@testable import TheExplorer

struct StorageScanTests {
    private func tree() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageScanTests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        let fm = FileManager.default
        for folder in ["a/deep/deeper", "b", "empty", "locked"] {
            try fm.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        func write(_ path: String, _ bytes: Int) throws {
            try Data(repeating: 7, count: bytes).write(to: root.appendingPathComponent(path))
        }
        try write("top.bin", 100_000)
        try write("a/one.bin", 50_000)
        try write("a/two.bin", 9_000)
        try write("a/deep/three.bin", 20_000)
        try write("a/deep/deeper/four.bin", 300_000)
        try write("b/five.bin", 1_000)
        try write("locked/hidden.bin", 70_000)
        // A second name for the same file counts once.
        try fm.linkItem(at: root.appendingPathComponent("a/one.bin"), to: root.appendingPathComponent("b/one-again.bin"))
        // Links aren't followed.
        try fm.createSymbolicLink(at: root.appendingPathComponent("b/to-a"), withDestinationURL: root.appendingPathComponent("a"))
        // Many files in one folder, more than a single read returns.
        try fm.createDirectory(at: root.appendingPathComponent("many"), withIntermediateDirectories: true)
        for i in 0..<3000 { try write("many/\(i).txt", 10) }
        chmod(root.appendingPathComponent("locked").path, 0)
        return root
    }

    private func cleanUp(_ root: URL) {
        chmod(root.appendingPathComponent("locked").path, 0o755)
        try? FileManager.default.removeItem(at: root)
    }

    @Test func scanAddsUpLikeAWalk() async throws {
        let root = try tree()
        defer { cleanUp(root) }
        let result = try await DiskScanner.scan(root: root, progress: ScanProgress())
        let walked = try #require(DiskScanner.folderSize(path: root.path))
        let scanned = result.root
        #expect(scanned.size == walked.bytes)
        #expect(scanned.fileCount == walked.files)
        #expect(scanned.fileCount == 3007)
        #expect(result.unreadableFolders == 1)

        func child(_ node: SizeNode, _ name: String) throws -> SizeNode {
            try #require(node.children.first { $0.name == name })
        }
        let a = try child(scanned, "a")
        let deep = try child(a, "deep")
        let deeper = try child(deep, "deeper")
        #expect(deeper.fileCount == 1)
        #expect(deep.fileCount == 2)
        // one.bin and one-again.bin are the same file, counted in whichever folder is read first.
        let b = try child(scanned, "b")
        #expect(a.fileCount + b.fileCount == 6)
        // A folder's own files are one node, after its subfolders are counted.
        let summary = try #require(a.children.first { $0.kind == .otherFiles })
        #expect(summary.fileCount == a.fileCount - 2)
        #expect(summary.size + deep.size == a.size)
        #expect(a.children.map(\.size) == a.children.map(\.size).sorted(by: >))
        #expect(try child(scanned, "many").fileCount == 3000)
        #expect(try child(scanned, "locked").isReadable == false)
        #expect(try child(scanned, "empty").size == 0)
        // The root's own file is listed by name.
        #expect(scanned.children.contains { $0.kind == .file && $0.name == "top.bin" })
        #expect(result.largestFiles.first?.name == "four.bin")
        #expect(deeper.path == root.appendingPathComponent("a/deep/deeper").path)
    }

    @Test func showsTheRootsFoldersWhileScanning() async throws {
        let root = try tree()
        defer { cleanUp(root) }
        let progress = ScanProgress()
        _ = try await DiskScanner.scan(root: root, progress: progress)
        let folders = progress.folders
        #expect(Set(folders.map(\.name)) == ["a", "b", "empty", "many", "locked"])
        #expect(folders.first?.name == "many")
        // Everything but the root's own file.
        #expect(progress.snapshot.files == 3006)
    }
}
