import Foundation
import Testing
@testable import TheExplorer

struct CompressorTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CompressorTests-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Project/src"), withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: url.appendingPathComponent("Project/src/main.swift"))
        try Data("notes".utf8).write(to: url.appendingPathComponent("notes.txt"))
        return url
    }

    private func names(in archive: URL) throws -> Set<String> {
        Set(try ZipArchive(url: archive).entries.map(\.path).filter { !$0.hasPrefix("__MACOSX") })
    }

    @Test func aFolderBecomesItsOwnZip() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try Compressor.zip([root.appendingPathComponent("Project")])
        #expect(archive.lastPathComponent == "Project.zip")
        #expect(archive.deletingLastPathComponent().path == root.path)
        #expect(try names(in: archive).contains("Project/src/main.swift"))
        // Compressing again doesn't overwrite the first.
        #expect(try Compressor.zip([root.appendingPathComponent("Project")]).lastPathComponent == "Project 2.zip")
    }

    @Test func severalItemsGoSideBySideInArchiveZip() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try Compressor.zip([root.appendingPathComponent("Project"), root.appendingPathComponent("notes.txt")])
        #expect(archive.lastPathComponent == "Archive.zip")
        let inside = try names(in: archive)
        #expect(inside.contains("notes.txt"))
        #expect(inside.contains("Project/src/main.swift"))
        #expect(!inside.contains { $0.hasPrefix("Archive/") })
        // Nothing left behind but the archive.
        let left = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        #expect(left == ["Archive.zip", "Project", "notes.txt"])
    }

    @Test func itemsFromDifferentFoldersAreRefused() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: Compressor.Failure.self) {
            try Compressor.zip([root.appendingPathComponent("notes.txt"), root.appendingPathComponent("Project/src/main.swift")])
        }
    }
}
