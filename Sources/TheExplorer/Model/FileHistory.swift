import Foundation
import Observation

/// Undo and redo for changes made to files in the app: moves, copies, renames, Move to Trash
/// and new items. There's one history for the whole app, like Finder's, so ⌘Z undoes the last
/// change wherever it was made: drag a file from one tab into a folder in another, and ⌘Z in
/// either tab (or another window) puts it back.
@MainActor
@Observable
final class FileHistory {
    static let shared = FileHistory()

    /// One change to an item on disk. Applying a step returns the step that reverses it.
    enum Step: Sendable, Equatable {
        case move(URL, to: URL)
        case trash(URL)
        /// Puts an item that's in the Trash back where it was.
        case restore(URL, to: URL)
    }

    struct Change: Sendable {
        /// "Move of “clip.mp4”", shown as "Undo Move of “clip.mp4”".
        let name: String
        let steps: [Step]
    }

    struct Outcome: Sendable {
        var name = ""
        /// Where items ended up (restored, moved back, moved again).
        var placed: [URL] = []
        /// Folders whose contents changed.
        var folders: Set<URL> = []
        var failures: [String] = []
    }

    private(set) var undoStack: [Change] = []
    private(set) var redoStack: [Change] = []
    private(set) var isBusy = false

    private static let limit = 100

    var undoTitle: String { undoStack.last.map { "Undo \($0.name)" } ?? "Undo" }
    var redoTitle: String { redoStack.last.map { "Redo \($0.name)" } ?? "Redo" }

    /// Records a change that was just made; applying `undo` reverses it.
    func record(_ name: String, undo steps: [Step]) {
        guard !steps.isEmpty else { return }
        undoStack.append(Change(name: name, steps: steps))
        if undoStack.count > Self.limit {
            undoStack.removeFirst(undoStack.count - Self.limit)
        }
        redoStack.removeAll()
    }

    /// Reverses the last change. Nil when there's nothing to undo (or one is still running).
    func undo() async -> Outcome? {
        guard !isBusy, let change = undoStack.popLast() else { return nil }
        let (inverse, outcome) = await run(change)
        if !inverse.steps.isEmpty { redoStack.append(inverse) }
        return outcome
    }

    func redo() async -> Outcome? {
        guard !isBusy, let change = redoStack.popLast() else { return nil }
        let (inverse, outcome) = await run(change)
        if !inverse.steps.isEmpty { undoStack.append(inverse) }
        return outcome
    }

    private func run(_ change: Change) async -> (Change, Outcome) {
        isBusy = true
        defer { isBusy = false }
        let result = await Task.detached(priority: .userInitiated) { Self.apply(change.steps) }.value
        var outcome = result.outcome
        outcome.name = change.name
        return (Change(name: change.name, steps: result.inverse), outcome)
    }

    /// Applies `steps` in order and returns the steps that reverse the ones that worked, in the
    /// order to apply them. A step that can't be done (the item was moved or deleted since, or
    /// something else now has its old name) is skipped and reported, never overwritten.
    nonisolated static func apply(_ steps: [Step]) -> (inverse: [Step], outcome: Outcome) {
        let fm = FileManager.default
        var inverse: [Step] = []
        var outcome = Outcome()
        for step in steps {
            switch step {
            case .move(let from, let to), .restore(let from, let to):
                if let problem = problem(moving: from, to: to) {
                    outcome.failures.append(problem)
                    continue
                }
                do {
                    try fm.moveItem(at: from, to: to)
                } catch {
                    outcome.failures.append("\(from.lastPathComponent): \(error.localizedDescription)")
                    continue
                }
                if case .restore = step {
                    inverse.append(.trash(to))
                } else {
                    inverse.append(.move(to, to: from))
                    outcome.folders.insert(from.deletingLastPathComponent())
                }
                outcome.placed.append(to)
                outcome.folders.insert(to.deletingLastPathComponent())
            case .trash(let url):
                guard exists(url) else {
                    outcome.failures.append("“\(url.lastPathComponent)” is no longer in “\(url.deletingLastPathComponent().lastPathComponent)”")
                    continue
                }
                var trashed: NSURL?
                do {
                    try fm.trashItem(at: url, resultingItemURL: &trashed)
                } catch {
                    outcome.failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                    continue
                }
                if let trashed = trashed as URL? { inverse.append(.restore(trashed, to: url)) }
                outcome.folders.insert(url.deletingLastPathComponent())
            }
        }
        return (inverse.reversed(), outcome)
    }

    private nonisolated static func problem(moving from: URL, to: URL) -> String? {
        let name = from.lastPathComponent
        guard exists(from) else {
            return "“\(name)” is no longer in “\(from.deletingLastPathComponent().lastPathComponent)”"
        }
        // A rename that only changes case is the same file on a case-insensitive volume.
        if exists(to), from.path.lowercased() != to.path.lowercased() {
            return "something named “\(to.lastPathComponent)” is already in “\(to.deletingLastPathComponent().lastPathComponent)”"
        }
        guard exists(to.deletingLastPathComponent()) else {
            return "“\(to.deletingLastPathComponent().lastPathComponent)” no longer exists"
        }
        return nil
    }

    /// Whether anything is at `url`, including a symlink whose target is gone.
    private nonisolated static func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    /// "“clip.mp4”" or "3 Items".
    static func describe(_ urls: [URL]) -> String {
        urls.count == 1 ? "“\(urls[0].lastPathComponent)”" : "\(urls.count) Items"
    }
}
