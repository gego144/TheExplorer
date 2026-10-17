import AppKit
import Observation

/// Copy, cut and paste for files, through the system pasteboard so it works with Finder and
/// other apps both ways: files copied here paste in Finder, and files copied in Finder paste here.
///
/// The pasteboard only holds the files; whether they were cut is remembered here, for as long
/// as they're still what's on the pasteboard (copying anything else, anywhere, forgets it).
@MainActor
@Observable
final class FileClipboard {
    static let shared: FileClipboard = {
        #if DEBUG
        // Scripted runs use their own pasteboard so they never touch yours.
        if ProcessInfo.processInfo.environment["EXPLORER_PRIVATE_PASTEBOARD"] != nil {
            return FileClipboard(pasteboard: NSPasteboard(name: NSPasteboard.Name("TheExplorer.debug.\(ProcessInfo.processInfo.processIdentifier)")))
        }
        #endif
        let clipboard = FileClipboard(pasteboard: .general)
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { FileClipboard.shared.forgetStaleCut() }
        }
        return clipboard
    }()

    /// Items cut with ⌘X and not yet pasted. Lists dim them.
    private(set) var cutItems: Set<URL> = []
    @ObservationIgnored private var cutChangeCount = -1
    @ObservationIgnored let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
    }

    func copy(_ urls: [URL]) {
        write(urls)
        cutItems = []
    }

    /// Cut only applies to files on disk; anything else is copied.
    func cut(_ urls: [URL]) {
        write(urls)
        let files = urls.filter(\.isFileURL)
        cutItems = Set(files.map(\.standardizedFileURL))
        cutChangeCount = pasteboard.changeCount
    }

    /// Files (and S3 and Drive items) on the pasteboard, from here or any other app.
    var urls: [URL] {
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
        return objects.filter { $0.isFileURL || RemoteFiles.isRemote($0) }
    }

    var canPaste: Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: nil) && !urls.isEmpty
    }

    /// Whether pasting `urls` should move them: they're what was cut, still on the pasteboard.
    func isCut(_ urls: [URL]) -> Bool {
        forgetStaleCut()
        return !cutItems.isEmpty && urls.allSatisfy { cutItems.contains($0.standardizedFileURL) }
    }

    /// After cut items are pasted they're gone from where they were, so the pasteboard is cleared.
    func finishCut() {
        cutItems = []
        cutChangeCount = -1
        pasteboard.clearContents()
    }

    func forgetStaleCut() {
        if !cutItems.isEmpty && pasteboard.changeCount != cutChangeCount {
            cutItems = []
        }
    }

    private func write(_ urls: [URL]) {
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { $0 as NSURL })
    }
}
