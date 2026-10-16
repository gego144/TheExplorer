import AppKit
import Darwin
import Foundation
import Observation

/// A shell command you define once and run on files from the right-click menu or the Actions
/// menu, such as turning a video into an HLS stream.
///
/// Commands run in zsh as a login shell (so Homebrew tools are on the PATH), in the item's
/// folder, with these variables set: `FILE` (full path), `FILENAME` (name with extension),
/// `NAME` (name without extension), `EXT`, `DIR` (enclosing folder), and for all-at-once
/// actions `"$@"` (every path) and `COUNT`.
struct FileAction: Codable, Identifiable, Hashable {
    enum Target: String, Codable, CaseIterable {
        case files, folders, filesAndFolders
    }

    enum Mode: String, Codable, CaseIterable {
        /// Runs once per selected item, one after another.
        case eachItem
        /// Runs once with every selected item as arguments.
        case allItems
    }

    var id = UUID()
    var name: String
    var command: String
    /// For files: the extensions it applies to, lowercased without dots. Empty means any file.
    var extensions: [String] = []
    var target: Target = .files
    var mode: Mode = .eachItem

    func applies(to item: FileItem) -> Bool {
        if item.isFolder { return target != .files }
        guard target != .folders else { return false }
        return extensions.isEmpty || extensions.contains(item.fileExtension.lowercased())
    }

    /// "mp4, mov · each item"
    var summary: String {
        let kinds: String
        switch target {
        case .folders: kinds = "folders"
        case .files: kinds = extensions.isEmpty ? "any file" : extensions.joined(separator: ", ")
        case .filesAndFolders: kinds = extensions.isEmpty ? "files and folders" : extensions.joined(separator: ", ") + " and folders"
        }
        return kinds + " · " + (mode == .eachItem ? "each item" : "all at once")
    }

    /// Parses "mp4, .MOV m4v" into ["mp4", "mov", "m4v"].
    static func parseExtensions(_ text: String) -> [String] {
        text.split { $0 == "," || $0 == " " }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased() }
            .filter { !$0.isEmpty }
    }

    /// Starting points offered when adding an action.
    static let templates: [FileAction] = [
        FileAction(
            name: "Convert to HLS (m3u8)",
            command: """
            mkdir -p "$NAME-hls"
            ffmpeg -nostdin -hide_banner -y -i "$FILE" -codec copy -start_number 0 \\
              -hls_time 10 -hls_list_size 0 -f hls "$NAME-hls/$NAME.m3u8"
            """,
            extensions: ["mp4", "mov", "m4v"]
        ),
        FileAction(name: "Zip", command: #"zip -qry "$NAME.zip" "$FILENAME""#, target: .filesAndFolders),
        FileAction(name: "Copy SHA-256", command: #"shasum -a 256 "$@" | tee /dev/stderr | pbcopy"#, mode: .allItems),
    ]
}

/// The actions you've defined, saved to Application Support and shared by every window.
@MainActor
@Observable
final class ActionsStore {
    static let shared = ActionsStore()

    private(set) var actions: [FileAction] = []
    @ObservationIgnored private let fileURL: URL

    init() {
        #if DEBUG
        // Scripted runs use their own list so they never touch yours.
        if let path = ProcessInfo.processInfo.environment["EXPLORER_ACTIONS_FILE"] {
            fileURL = URL(fileURLWithPath: path)
            load()
            return
        }
        #endif
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TheExplorer", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        fileURL = support.appendingPathComponent("actions.json")
        load()
    }

    /// Actions that apply to at least one of `items`, in your order.
    func applicable(to items: [FileItem]) -> [FileAction] {
        actions.filter { action in items.contains(where: action.applies) }
    }

    func save(_ action: FileAction) {
        if let index = actions.firstIndex(where: { $0.id == action.id }) {
            actions[index] = action
        } else {
            actions.append(action)
        }
        persist()
    }

    func remove(_ action: FileAction) {
        actions.removeAll { $0.id == action.id }
        persist()
    }

    func move(_ action: FileAction, by offset: Int) {
        guard let index = actions.firstIndex(where: { $0.id == action.id }) else { return }
        let target = index + offset
        guard actions.indices.contains(target) else { return }
        actions.swapAt(index, target)
        persist()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([FileAction].self, from: data) else { return }
        actions = decoded
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(actions) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// Runs actions in the background and keeps their progress and output for the status bar.
@MainActor
@Observable
final class ActionRunner {
    static let shared = ActionRunner()

    struct Run: Identifiable {
        enum State: Equatable {
            case running, succeeded, cancelled
            case failed(Int32)
        }

        let id = UUID()
        let action: FileAction
        let items: [URL]
        var state = State.running
        /// Items finished so far (each-item actions run one at a time).
        var completed = 0
        var current: URL?
        var output = ""
        let started = Date()
        var finished: Date?

        var total: Int { action.mode == .eachItem ? items.count : 1 }
    }

    /// Newest first; only the most recent few are kept.
    private(set) var runs: [Run] = []
    @ObservationIgnored private var processes: [UUID: Process] = [:]
    @ObservationIgnored private var cancelled: Set<UUID> = []

    private static let keptRuns = 20
    /// Output beyond this is trimmed from the front; ffmpeg alone can print megabytes.
    private static let maxOutput = 64 * 1024

    var activeCount: Int { runs.filter { $0.state == .running }.count }

    /// Runs `action` on the items it applies to.
    @discardableResult
    func run(_ action: FileAction, on urls: [URL]) -> UUID? {
        let items = urls.filter { url in FileItem(url: url).map(action.applies) ?? false }
        guard !items.isEmpty else { return nil }
        let run = Run(action: action, items: items)
        runs.insert(run, at: 0)
        if runs.count > Self.keptRuns {
            runs.removeLast(runs.count - Self.keptRuns)
        }
        Task { await execute(run.id) }
        return run.id
    }

    func cancel(_ id: UUID) {
        cancelled.insert(id)
        if let process = processes[id], process.isRunning {
            Self.terminateTree(process.processIdentifier)
        }
    }

    func clearFinished() {
        runs.removeAll { $0.state != .running }
    }

    private func execute(_ id: UUID) async {
        guard let run = runs.first(where: { $0.id == id }) else { return }
        let batches: [[URL]] = run.action.mode == .eachItem ? run.items.map { [$0] } : [run.items]
        var status: Int32 = 0
        for (index, batch) in batches.enumerated() {
            guard !cancelled.contains(id) else { break }
            update(id) { $0.current = batch.first }
            if batches.count > 1 {
                append("› \(batch[0].lastPathComponent)\n", to: id)
            }
            status = await launch(run.action, on: batch, for: id)
            if status != 0 { break }
            update(id) { $0.completed = index + 1 }
        }
        let wasCancelled = cancelled.remove(id) != nil
        processes[id] = nil
        update(id) { run in
            run.current = nil
            run.finished = Date()
            run.state = wasCancelled ? .cancelled : (status == 0 ? .succeeded : .failed(status))
        }
    }

    /// Starts the shell for one batch and waits for it to exit.
    private func launch(_ action: FileAction, on items: [URL], for id: UUID) async -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // -l loads your login profile (Homebrew's PATH lives there). After the command, the
        // next argument becomes $0 and the rest "$@".
        process.arguments = ["-l", "-c", action.command, action.name] + items.map(\.path)
        process.currentDirectoryURL = items[0].deletingLastPathComponent()
        process.environment = Self.environment(for: items)
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in self?.append(text, to: id) }
        }
        return await withCheckedContinuation { continuation in
            process.terminationHandler = { finished in
                let status = finished.terminationStatus
                // Give the reader a moment to deliver the last output. Reading to the end here
                // could block forever if the command left a background process holding the pipe.
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    Task { @MainActor in continuation.resume(returning: status) }
                }
            }
            do {
                try process.run()
                processes[id] = process
            } catch {
                append("Couldn't start the shell: \(error.localizedDescription)\n", to: id)
                continuation.resume(returning: -1)
            }
        }
    }

    nonisolated static func environment(for items: [URL]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        // A fallback in case the login profile doesn't add Homebrew.
        environment["PATH"] = (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin") + ":/opt/homebrew/bin:/usr/local/bin"
        let first = items[0]
        environment["FILE"] = first.path
        environment["FILENAME"] = first.lastPathComponent
        environment["NAME"] = first.deletingPathExtension().lastPathComponent
        environment["EXT"] = first.pathExtension
        environment["DIR"] = first.deletingLastPathComponent().path
        environment["COUNT"] = String(items.count)
        return environment
    }

    private func update(_ id: UUID, _ change: (inout Run) -> Void) {
        guard let index = runs.firstIndex(where: { $0.id == id }) else { return }
        change(&runs[index])
    }

    private func append(_ text: String, to id: UUID) {
        update(id) { run in
            run.output = Self.appending(text, to: run.output)
            if run.output.utf8.count > Self.maxOutput {
                run.output = "…" + String(run.output.suffix(Self.maxOutput / 2))
            }
        }
    }

    /// Appends output the way a terminal shows it: a carriage return (progress lines from
    /// ffmpeg, curl…) rewrites the current line instead of adding a new one.
    nonisolated static func appending(_ text: String, to output: String) -> String {
        var output = output
        let segments = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\r", omittingEmptySubsequences: false)
        for (index, segment) in segments.enumerated() {
            if index > 0 {
                if let newline = output.lastIndex(of: "\n") {
                    output.removeSubrange(output.index(after: newline)...)
                } else {
                    output = ""
                }
            }
            output += segment
        }
        return output
    }

    /// Stops the shell and everything it started (a multi-line command keeps zsh around as the
    /// parent, so stopping zsh alone would leave ffmpeg running).
    nonisolated static func terminateTree(_ pid: pid_t) {
        var children = [pid_t](repeating: 0, count: 256)
        let count = proc_listchildpids(pid, &children, Int32(MemoryLayout<pid_t>.size * children.count))
        if count > 0 {
            for child in children.prefix(Int(count)) where child > 0 {
                terminateTree(child)
            }
        }
        kill(pid, SIGTERM)
    }
}
