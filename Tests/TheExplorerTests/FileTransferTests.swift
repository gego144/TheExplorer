import Foundation
import Testing
@testable import TheExplorer

/// A throwaway folder tree, removed when the test ends.
private final class Sandbox {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileTransferTests-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func folder(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    func file(_ path: String, _ contents: String = "x") throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)
    }

    func read(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }
}

struct FileTransferTests {
    @Test func movesFileWithinVolume() throws {
        let box = try Sandbox()
        let source = try box.file("B/notes.txt", "hello")
        let destination = try box.folder("A")

        let outcome = FileTransfer.perform([source], into: destination, optionHeld: false)

        #expect(outcome.failures.isEmpty)
        #expect(box.exists("A/notes.txt"))
        #expect(!box.exists("B/notes.txt"))
        #expect(try box.read("A/notes.txt") == "hello")
    }

    @Test func movesFolderWithContents() throws {
        let box = try Sandbox()
        try box.file("B/sub/inner.txt", "inner")
        let destination = try box.folder("A")

        let outcome = FileTransfer.perform([box.root.appendingPathComponent("B/sub")], into: destination, optionHeld: false)

        #expect(outcome.failures.isEmpty)
        #expect(try box.read("A/sub/inner.txt") == "inner")
        #expect(!box.exists("B/sub"))
    }

    @Test func optionCopiesInsteadOfMoving() throws {
        let box = try Sandbox()
        let source = try box.file("B/notes.txt")
        let destination = try box.folder("A")

        let outcome = FileTransfer.perform([source], into: destination, optionHeld: true)

        #expect(outcome.failures.isEmpty)
        #expect(box.exists("A/notes.txt"))
        #expect(box.exists("B/notes.txt"))
    }

    @Test func nameClashKeepsBoth() throws {
        let box = try Sandbox()
        try box.file("A/notes.txt", "original")
        try box.file("A/notes 2.txt", "second")
        let source = try box.file("B/notes.txt", "incoming")

        let outcome = FileTransfer.perform([source], into: box.root.appendingPathComponent("A"), optionHeld: false)

        #expect(try box.read("A/notes.txt") == "original")
        #expect(try box.read("A/notes 2.txt") == "second")
        #expect(try box.read("A/notes 3.txt") == "incoming")
        #expect(outcome.placed.map(\.lastPathComponent) == ["notes 3.txt"])
    }

    @Test func clashNamingWithoutExtension() throws {
        let box = try Sandbox()
        let folder = try box.folder("A")
        try box.folder("A/photos")

        #expect(FileTransfer.uniqueDestination(for: "photos", in: folder).lastPathComponent == "photos 2")
        #expect(FileTransfer.uniqueDestination(for: "fresh", in: folder).lastPathComponent == "fresh")
    }

    @Test func rejectsPointlessOrDangerousDrops() throws {
        let box = try Sandbox()
        let a = try box.folder("A")
        let inner = try box.folder("A/inner")
        let alreadyThere = try box.file("A/notes.txt")
        let elsewhere = try box.file("B/other.txt")

        // Into its own folder, onto itself, and into its own subfolder are all rejected.
        #expect(FileTransfer.validSources([alreadyThere], into: a).isEmpty)
        #expect(FileTransfer.validSources([a], into: a).isEmpty)
        #expect(FileTransfer.validSources([a], into: inner).isEmpty)
        // A sibling folder whose name merely starts the same is fine ("A" vs "AB").
        let ab = try box.folder("AB")
        #expect(FileTransfer.validSources([a], into: ab) == [a])
        #expect(FileTransfer.validSources([elsewhere, alreadyThere], into: a) == [elsewhere])
    }

    @Test func reportsFailuresWithoutStopping() throws {
        let box = try Sandbox()
        let missing = box.root.appendingPathComponent("B/gone.txt")
        let present = try box.file("B/here.txt")
        let destination = try box.folder("A")

        let outcome = FileTransfer.perform([missing, present], into: destination, optionHeld: false)

        #expect(outcome.failures.count == 1)
        #expect(box.exists("A/here.txt"))
    }
}
