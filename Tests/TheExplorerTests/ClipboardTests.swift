import AppKit
import Testing
@testable import TheExplorer

/// A throwaway folder, removed when the test ends.
private final class Folder {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardTests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func file(_ path: String, _ text: String = "x") throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    func folder(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) }
}

/// Waits (briefly) for a background transfer to land.
private func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<100 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

/// One at a time: pasting records in the app's shared undo history.
@MainActor
@Suite(.serialized)
struct ClipboardTests {
    /// Never the real clipboard.
    func privateClipboard() -> FileClipboard {
        FileClipboard(pasteboard: NSPasteboard(name: NSPasteboard.Name("TheExplorerTests.\(UUID().uuidString)")))
    }

    @Test func copyThenPasteCopies() async throws {
        let box = try Folder()
        let report = try box.file("a/report.pdf")
        let b = try box.folder("b")
        let clipboard = privateClipboard()
        clipboard.copy([report])
        #expect(clipboard.urls == [report])

        let model = BrowserModel(url: b)
        #expect(model.paste(from: clipboard))
        #expect(await eventually { box.exists("b/report.pdf") })
        #expect(box.exists("a/report.pdf"))
        // Still on the clipboard, so it can be pasted again.
        #expect(clipboard.urls == [report])
    }

    @Test func cutThenPasteMovesAndClears() async throws {
        let box = try Folder()
        let clip = try box.file("a/clip.ts")
        let b = try box.folder("b")
        let clipboard = privateClipboard()
        clipboard.cut([clip])
        #expect(clipboard.cutItems == [clip.standardizedFileURL])

        let model = BrowserModel(url: b)
        #expect(model.paste(from: clipboard))
        #expect(await eventually { box.exists("b/clip.ts") && !box.exists("a/clip.ts") })
        #expect(await eventually { clipboard.cutItems.isEmpty })
        #expect(clipboard.urls.isEmpty)
    }

    @Test func copyingSomethingElseForgetsTheCut() throws {
        let box = try Folder()
        let one = try box.file("one.txt")
        let two = try box.file("two.txt")
        let clipboard = privateClipboard()
        clipboard.cut([one])
        clipboard.pasteboard.clearContents()
        clipboard.pasteboard.writeObjects([two as NSURL])
        #expect(!clipboard.isCut([two]))
        #expect(clipboard.cutItems.isEmpty)
    }

    @Test func pastingIntoTheSameFolderDuplicates() async throws {
        let box = try Folder()
        let notes = try box.file("notes.txt")
        let clipboard = privateClipboard()
        clipboard.copy([notes])
        let model = BrowserModel(url: box.root)
        #expect(model.paste(from: clipboard))
        #expect(await eventually { box.exists("notes 2.txt") })
    }

    @Test func pasteCanBeUndone() async throws {
        let box = try Folder()
        let clip = try box.file("a/clip.ts")
        let b = try box.folder("b")
        let clipboard = privateClipboard()
        clipboard.cut([clip])
        let model = BrowserModel(url: b)
        let before = FileHistory.shared.undoStack.count
        model.paste(from: clipboard)
        #expect(await eventually { FileHistory.shared.undoStack.count == before + 1 })
        _ = await FileHistory.shared.undo()
        #expect(box.exists("a/clip.ts") && !box.exists("b/clip.ts"))
    }

    @Test func aFolderCantBePastedIntoItself() throws {
        let box = try Folder()
        let a = try box.folder("a")
        let inside = try box.folder("a/inside")
        let clipboard = privateClipboard()
        clipboard.copy([a])
        #expect(!BrowserModel(url: inside).paste(from: clipboard))
    }
}

extension ClipboardTests {
    @Test func pastesIntoARightClickedFolder() async throws {
        let box = try Folder()
        let notes = try box.file("notes.txt")
        let inbox = try box.folder("inbox")
        let clipboard = privateClipboard()
        clipboard.copy([notes])
        #expect(BrowserModel(url: box.root).paste(into: inbox, from: clipboard))
        #expect(await eventually { box.exists("inbox/notes.txt") })
        #expect(box.exists("notes.txt"))
    }
}
