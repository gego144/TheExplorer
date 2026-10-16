import Foundation
import Testing
@testable import TheExplorer

/// Builds real archives with the system tools and reads them back.
struct ZipArchiveTests {
    private let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ZipArchiveTests-\(UUID().uuidString)")
        let source = root.appendingPathComponent("Project/src", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try String(repeating: "let value = 42\n", count: 400).write(to: source.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        try "hello".write(to: root.appendingPathComponent("Project/README.md"), atomically: true, encoding: .utf8)
        try Data().write(to: root.appendingPathComponent("Project/empty.txt"))
    }

    private func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.currentDirectoryURL = root
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    private func checkRoundTrip(_ zip: URL) throws {
        let archive = try ZipArchive(url: zip)
        let tree = ArchiveTree(archive)
        #expect(tree.roots.map(\.name) == ["Project"])
        #expect(tree.fileCount == 3)
        let main = try #require(archive.entries.first { $0.path.hasSuffix("src/main.swift") })
        #expect(main.size == 15 * 400)
        #expect(main.modified != nil)

        for entry in archive.entries where !entry.isDirectory {
            let out = root.appendingPathComponent("out/\(UUID().uuidString)")
            try archive.extract(entry, to: out)
            let original = try Data(contentsOf: root.appendingPathComponent(entry.path))
            #expect(try Data(contentsOf: out) == original, "\(entry.path)")
        }
    }

    @Test func readsAndUnpacksDeflatedZip() throws {
        try run("/usr/bin/zip", ["-qr", "deflated.zip", "Project"])
        try checkRoundTrip(root.appendingPathComponent("deflated.zip"))
    }

    @Test func readsAndUnpacksStoredZip() throws {
        try run("/usr/bin/zip", ["-qr0", "stored.zip", "Project"])
        try checkRoundTrip(root.appendingPathComponent("stored.zip"))
    }

    @Test func readsZip64() throws {
        try run("/usr/bin/zip", ["-qr", "-fz", "zip64.zip", "Project"])
        try checkRoundTrip(root.appendingPathComponent("zip64.zip"))
    }

    @Test func readsFinderStyleZip() throws {
        // Finder's Compress (ditto) adds __MACOSX resource forks, which the tree hides.
        try run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", "Project", "finder.zip"])
        let tree = ArchiveTree(try ZipArchive(url: root.appendingPathComponent("finder.zip")))
        #expect(tree.roots.map(\.name) == ["Project"])
        #expect(tree.fileCount == 3)
    }

    @Test func unpacksAFolderWithItsContents() throws {
        try run("/usr/bin/zip", ["-qr", "folder.zip", "Project"])
        let archive = try ZipArchive(url: root.appendingPathComponent("folder.zip"))
        let folder = try PreviewFiles.unpack(path: "Project/src", isDirectory: true, from: archive)
        let main = folder.appendingPathComponent("main.swift")
        #expect(try Data(contentsOf: main) == Data(contentsOf: root.appendingPathComponent("Project/src/main.swift")))
    }

    @Test func rejectsNonZip() throws {
        let file = root.appendingPathComponent("not.zip")
        try "not a zip".write(to: file, atomically: true, encoding: .utf8)
        #expect(throws: ZipArchive.Failure.self) { try ZipArchive(url: file) }
    }

    @Test func previewDestinationStaysInsideItsFolder() throws {
        let destination = try PreviewFiles.destination(forPath: "../../../etc/evil", in: root.appendingPathComponent("a.zip"))
        #expect(destination.path.contains("TheExplorer Previews"))
        #expect(destination.lastPathComponent == "evil")
        #expect(!destination.path.contains(".."))
    }
}
