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

@MainActor
struct FileHistoryTests {
    @Test func undoesAndRedoesAMoveBetweenFolders() async throws {
        let box = try Sandbox()
        let clip = try box.file("one/clip.ts", "a")
        let two = try box.folder("two")
        let history = FileHistory()

        // Dragged from the first tab's folder into the second's.
        let outcome = FileTransfer.perform([clip], into: two, optionHeld: false)
        history.record("Move of “clip.ts”", undo: outcome.undo)
        #expect(box.exists("two/clip.ts") && !box.exists("one/clip.ts"))
        #expect(history.undoTitle == "Undo Move of “clip.ts”")

        let undone = try #require(await history.undo())
        #expect(box.exists("one/clip.ts") && !box.exists("two/clip.ts"))
        #expect(undone.failures.isEmpty)
        #expect(undone.placed == [clip])
        #expect(undone.folders == [clip.deletingLastPathComponent(), two])
        #expect(history.undoStack.isEmpty)
        #expect(history.redoTitle == "Redo Move of “clip.ts”")

        _ = try #require(await history.redo())
        #expect(box.exists("two/clip.ts") && !box.exists("one/clip.ts"))
        #expect(history.redoStack.isEmpty)

        _ = try #require(await history.undo())
        #expect(box.exists("one/clip.ts"))
        #expect(try await history.undo() == nil)
    }

    @Test func undoesSeveralChangesInOrder() async throws {
        let box = try Sandbox()
        let notes = try box.file("notes.txt", "n")
        let archive = try box.folder("archive")
        let history = FileHistory()

        let renamed = box.root.appendingPathComponent("plans.txt")
        try FileManager.default.moveItem(at: notes, to: renamed)
        history.record("Rename of “notes.txt”", undo: [.move(renamed, to: notes)])
        let moved = FileTransfer.perform([renamed], into: archive, optionHeld: false)
        history.record("Move of “plans.txt”", undo: moved.undo)
        #expect(box.exists("archive/plans.txt"))

        _ = await history.undo()
        #expect(box.exists("plans.txt"))
        _ = await history.undo()
        #expect(box.exists("notes.txt") && !box.exists("plans.txt"))
        #expect(history.redoStack.map(\.name) == ["Move of “plans.txt”", "Rename of “notes.txt”"])
    }

    @Test func aNewChangeClearsRedo() async throws {
        let box = try Sandbox()
        let a = try box.file("a.txt")
        let b = box.root.appendingPathComponent("b.txt")
        let history = FileHistory()
        try FileManager.default.moveItem(at: a, to: b)
        history.record("Rename of “a.txt”", undo: [.move(b, to: a)])
        _ = await history.undo()
        #expect(!history.redoStack.isEmpty)
        history.record("New Folder", undo: [.trash(box.root.appendingPathComponent("x"))])
        #expect(history.redoStack.isEmpty)
    }

    @Test func neverOverwritesWhatTookTheOldName() async throws {
        let box = try Sandbox()
        let clip = try box.file("one/clip.ts", "original")
        let two = try box.folder("two")
        let history = FileHistory()
        history.record("Move of “clip.ts”", undo: FileTransfer.perform([clip], into: two, optionHeld: false).undo)
        // Something new arrives under the old name before the undo.
        try box.file("one/clip.ts", "newer")

        let outcome = try #require(await history.undo())
        #expect(outcome.failures.count == 1)
        #expect(try box.read("one/clip.ts") == "newer")
        #expect(try box.read("two/clip.ts") == "original")
        #expect(history.redoStack.isEmpty)
    }

    @Test func reportsItemsThatAreGone() {
        let missing = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString)/x.txt")
        let (inverse, outcome) = FileHistory.apply([.move(missing, to: URL(fileURLWithPath: "/tmp/x.txt"))])
        #expect(inverse.isEmpty)
        #expect(outcome.failures.first?.contains("no longer in") == true)
    }

    @Test func restoringPutsAnItemBackAndCanBeTrashedAgain() throws {
        let box = try Sandbox()
        // Stands in for the item's place in the Trash, so the test never touches the real one.
        let inTrash = try box.file("fake-trash/report.pdf")
        let original = try box.folder("docs").appendingPathComponent("report.pdf")
        let (inverse, outcome) = FileHistory.apply([.restore(inTrash, to: original)])
        #expect(box.exists("docs/report.pdf") && !box.exists("fake-trash/report.pdf"))
        #expect(inverse == [.trash(original)])
        #expect(outcome.placed == [original])
    }
}
