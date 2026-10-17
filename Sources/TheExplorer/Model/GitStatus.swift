import CoreServices
import Foundation
import Observation
import SwiftUI

/// What git says about a file, worst first in `Comparable` order (a folder shows the worst
/// change inside it).
enum GitChange: Int, Comparable, Sendable {
    case untracked = 1, renamed, added, modified, deleted, conflicted

    static func < (lhs: GitChange, rhs: GitChange) -> Bool { lhs.rawValue < rhs.rawValue }

    var letter: String {
        switch self {
        case .untracked: "U"
        case .renamed: "R"
        case .added: "A"
        case .modified: "M"
        case .deleted: "D"
        case .conflicted: "!"
        }
    }

    var title: String {
        switch self {
        case .untracked: "Untracked"
        case .renamed: "Renamed"
        case .added: "Added"
        case .modified: "Modified"
        case .deleted: "Deleted"
        case .conflicted: "Conflicted"
        }
    }

    var color: Color {
        switch self {
        case .untracked, .added: Theme.blue
        case .renamed: Theme.purple
        case .modified: Theme.warning
        case .deleted, .conflicted: Theme.danger
        }
    }
}

/// How a row looks in a repository.
enum GitMark: Equatable, Sendable {
    /// The file (or untracked folder) itself changed.
    case changed(GitChange)
    /// A folder with changes inside; the worst of them and how many.
    case contains(GitChange, count: Int)
    /// Ignored by .gitignore.
    case ignored
}

/// One `git status` of a repository, keyed by absolute path.
struct GitSnapshot: Sendable, Equatable {
    var root: String
    var branch: String?
    /// The commit, for a detached HEAD.
    var commit: String?
    var upstream: String?
    var ahead = 0
    var behind = 0
    var changes: [String: GitChange] = [:]
    /// Folders with changes inside: the worst change and how many files.
    var folders: [String: (change: GitChange, count: Int)] = [:]
    /// Untracked and ignored folders, listed once rather than file by file.
    var untrackedFolders: Set<String> = []
    var ignored: Set<String> = []

    var changeCount: Int { changes.count + untrackedFolders.count }

    static func == (lhs: GitSnapshot, rhs: GitSnapshot) -> Bool {
        lhs.root == rhs.root && lhs.branch == rhs.branch && lhs.commit == rhs.commit && lhs.upstream == rhs.upstream
            && lhs.ahead == rhs.ahead && lhs.behind == rhs.behind && lhs.changes == rhs.changes
            && lhs.untrackedFolders == rhs.untrackedFolders && lhs.ignored == rhs.ignored
    }

    func mark(for path: String) -> GitMark? {
        if let change = changes[path] { return .changed(change) }
        if untrackedFolders.contains(path) { return .changed(.untracked) }
        if ignored.contains(path) { return .ignored }
        if let folder = folders[path] { return .contains(folder.change, count: folder.count) }
        // Inside an untracked or ignored folder, everything is.
        guard path.hasPrefix(root + "/") else { return nil }
        var ancestor = (path as NSString).deletingLastPathComponent
        while ancestor.count > root.count {
            if untrackedFolders.contains(ancestor) { return .changed(.untracked) }
            if ignored.contains(ancestor) { return .ignored }
            ancestor = (ancestor as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// Reads `git status --porcelain=v2 --branch -z` output.
    static func parse(_ output: Data, root: String) -> GitSnapshot {
        var snapshot = GitSnapshot(root: root)
        let records = output.split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }
        var index = 0
        func absolute(_ relative: Substring) -> String {
            var path = relative
            if path.hasSuffix("/") { path = path.dropLast() }
            return root + "/" + path
        }
        while index < records.count {
            let record = records[index]
            index += 1
            guard let kind = record.first else { continue }
            switch kind {
            case "#":
                let parts = record.split(separator: " ", maxSplits: 2)
                guard parts.count == 3 else { continue }
                switch parts[1] {
                case "branch.head": if parts[2] != "(detached)" { snapshot.branch = String(parts[2]) }
                case "branch.oid": snapshot.commit = String(parts[2].prefix(7))
                case "branch.upstream": snapshot.upstream = String(parts[2])
                case "branch.ab":
                    let counts = parts[2].split(separator: " ")
                    snapshot.ahead = counts.first.flatMap { Int($0.dropFirst()) } ?? 0
                    snapshot.behind = counts.dropFirst().first.flatMap { Int($0.dropFirst()) } ?? 0
                default: break
                }
            case "1", "2", "u":
                // Fields before the path: 8 for ordinary changes, 9 for renames, 10 for conflicts.
                let fieldCount = kind == "1" ? 8 : (kind == "2" ? 9 : 10)
                let fields = record.split(separator: " ", maxSplits: fieldCount)
                guard fields.count == fieldCount + 1 else { continue }
                if kind == "2" { index += 1 } // the original path follows a rename
                let xy = Array(fields[1])
                let change: GitChange
                if kind == "u" {
                    change = .conflicted
                } else if xy.contains("D") {
                    change = .deleted
                } else if xy[1] == "M" || xy[1] == "T" || xy[0] == "M" || xy[0] == "T" {
                    change = .modified
                } else if kind == "2" {
                    change = .renamed
                } else if xy[0] == "A" || xy[1] == "A" {
                    change = .added
                } else {
                    change = .modified
                }
                snapshot.changes[absolute(fields[fieldCount])] = change
            case "?":
                let relative = record.dropFirst(2)
                if relative.hasSuffix("/") {
                    snapshot.untrackedFolders.insert(absolute(relative))
                } else {
                    snapshot.changes[absolute(relative)] = .untracked
                }
            case "!":
                snapshot.ignored.insert(absolute(record.dropFirst(2)))
            default:
                break
            }
        }
        // Roll changes up into every folder above them, the repository's own folder included.
        let changed = snapshot.changes.map { ($0.key, $0.value) } + snapshot.untrackedFolders.map { ($0, GitChange.untracked) }
        for (path, change) in changed {
            var folder = (path as NSString).deletingLastPathComponent
            while folder.count >= root.count {
                let current = snapshot.folders[folder]
                snapshot.folders[folder] = (max(current?.change ?? change, change), (current?.count ?? 0) + 1)
                if folder == root { break }
                folder = (folder as NSString).deletingLastPathComponent
            }
        }
        return snapshot
    }
}

/// A repository being shown, with its status kept current while any tab is in it.
@MainActor
@Observable
final class GitRepository {
    let root: String
    private(set) var snapshot: GitSnapshot?

    @ObservationIgnored private let git: String
    @ObservationIgnored private var watcher: GitWatcher?
    @ObservationIgnored private var running = false
    @ObservationIgnored private var again = false

    init(root: String, gitFolders: [String], git: String) {
        self.root = root
        self.git = git
        watcher = GitWatcher(root: root, gitFolders: gitFolders) { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    /// Runs `git status` again (once more after the current run, if one is going).
    func refresh() {
        guard !running else {
            again = true
            return
        }
        running = true
        let root = root
        let git = git
        Task {
            let output = await Task.detached(priority: .utility) {
                Git.run(git, in: root, ["--no-optional-locks", "status", "--porcelain=v2", "--branch", "-z",
                                        "--ignored=matching", "--untracked-files=normal"])
            }.value
            running = false
            if let output {
                let snapshot = await Task.detached(priority: .utility) { GitSnapshot.parse(output, root: root) }.value
                if snapshot != self.snapshot { self.snapshot = snapshot }
                watcher?.skipped = snapshot.ignored
            }
            if again {
                again = false
                refresh()
            }
        }
    }
}

/// Finds repositories and shares one per repository between tabs.
@MainActor
enum GitRepositories {
    private final class Weak {
        weak var repository: GitRepository?
        init(_ repository: GitRepository) { self.repository = repository }
    }

    private static var open: [String: Weak] = [:]

    /// The repository `folder` is in, if any (and if git is installed).
    static func repository(containing folder: URL) async -> GitRepository? {
        guard folder.isFileURL, let git = Git.executable, let top = Git.enclosingRepository(of: folder.standardizedFileURL.path) else { return nil }
        if let existing = open[top]?.repository { return existing }
        // The git folders to watch: a worktree's own, and the shared one with branches and refs.
        let folders = await Task.detached(priority: .utility) {
            Git.run(git, in: top, ["rev-parse", "--absolute-git-dir", "--git-common-dir"])
        }.value
        let paths = folders.map { String(decoding: $0, as: UTF8.self).split(separator: "\n").map { path in
            path.hasPrefix("/") ? String(path) : top + "/" + path
        } } ?? []
        guard !paths.isEmpty else { return nil }
        if let existing = open[top]?.repository { return existing }
        let repository = GitRepository(root: top, gitFolders: Array(Set(paths.map { ($0 as NSString).standardizingPath })), git: git)
        open[top] = Weak(repository)
        open = open.filter { $0.value.repository != nil }
        return repository
    }
}

enum Git {
    /// A real git, never the /usr/bin/git stub (which offers to install developer tools).
    static let executable: String? = {
        var candidates = ["/opt/homebrew/bin/git", "/usr/local/bin/git"]
        if let developer = try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link") {
            candidates.append(developer + "/usr/bin/git")
        }
        candidates += ["/Library/Developer/CommandLineTools/usr/bin/git", "/Applications/Xcode.app/Contents/Developer/usr/bin/git"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    /// The folder holding `.git` (a folder, or a file for worktrees) at or above `path`.
    static func enclosingRepository(of path: String) -> String? {
        var folder = path
        while folder.count > 1 {
            if access(folder + "/.git", F_OK) == 0 { return folder }
            folder = (folder as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// Runs git and returns what it printed, or nil if it failed.
    static func run(_ git: String, in folder: String, _ arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = ["-C", folder] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["LC_ALL"] = "C"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }
}

/// Watches a repository's files and git folders, calling back (debounced) when something that
/// could change its status happens. Changes inside ignored folders (builds, node_modules) and
/// git's object store don't count.
final class GitWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let root: String
    private let gitFolders: [String]
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "GitWatcher", qos: .utility)
    private let lock = NSLock()
    private var _skipped: Set<String> = []
    private var pending: DispatchWorkItem?

    /// Ignored paths from the last status.
    var skipped: Set<String> {
        get { lock.withLock { _skipped } }
        set { lock.withLock { _skipped = newValue } }
    }

    init(root: String, gitFolders: [String], onChange: @escaping @Sendable () -> Void) {
        self.root = root
        // Longest first: a worktree's own git folder sits inside the shared one.
        self.gitFolders = gitFolders.sorted { $0.count > $1.count }
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<GitWatcher>.fromOpaque(info).takeUnretainedValue()
            let cPaths = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            for i in 0..<count {
                var path = String(cString: cPaths[i])
                if path.count > 1 && path.hasSuffix("/") { path.removeLast() }
                if watcher.matters(path) {
                    watcher.schedule()
                    return
                }
            }
        }
        let paths = ([root] + gitFolders.filter { !$0.hasPrefix(root + "/") }) as CFArray
        guard let stream = FSEventStreamCreate(nil, callback, &context, paths, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    private func matters(_ path: String) -> Bool {
        for folder in gitFolders where path == folder || path.hasPrefix(folder + "/") {
            // The index, HEAD and branches change status; objects, logs and hooks don't.
            let inside = path.dropFirst(folder.count)
            return inside.isEmpty || inside.hasPrefix("/refs")
        }
        let skipped = skipped
        var ancestor = path
        while ancestor.count > root.count {
            if skipped.contains(ancestor) { return false }
            ancestor = (ancestor as NSString).deletingLastPathComponent
        }
        return true
    }

    private func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [onChange] in onChange() }
        pending = work
        queue.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
}
