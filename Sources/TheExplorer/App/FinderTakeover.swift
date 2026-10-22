import AppKit
import Observation
import os

/// Catches Finder windows and shows their folders in TheExplorer instead.
///
/// Other apps' "Show in Finder" already comes here once TheExplorer is the file viewer, but
/// macOS 26 keeps Finder for opening folders: the Dock and its stacks, Spotlight, Archive
/// Utility, and apps that ask Finder directly. So when Finder comes forward (and every second
/// while it stays there), TheExplorer asks Finder over Apple Events which folders its windows
/// show, closes them, and opens those folders in tabs, with the front window's selection
/// selected. Windows that aren't folders (AirDrop, Recents, servers) are left alone. It costs
/// nothing while Finder is in the background.
///
/// Off unless you turn it on in Settings, since it needs your permission to control Finder.
@MainActor
@Observable
final class FinderTakeover {
    static let shared = FinderTakeover()

    nonisolated static let finderID = "com.apple.finder"
    /// What it saw and did, for `log show --predicate 'subsystem == "com.gego.TheExplorer"'`.
    nonisolated static let log = Logger(subsystem: "com.gego.TheExplorer", category: "FinderTakeover")
    /// Apple Events error for "not allowed to control that app".
    nonisolated static let notPermitted = -1743

    /// Set when macOS refused to let TheExplorer control Finder.
    private(set) var isDenied = false
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var checking: Task<Void, Never>?
    /// Held while Finder is in front. TheExplorer is in the background then, where App Nap
    /// would stretch a check due in a fifth of a second to several seconds.
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private let queue = DispatchQueue(label: "TheExplorer.FinderTakeover", qos: .userInitiated)
    /// Compiled once, and only used on `queue`.
    @ObservationIgnored nonisolated(unsafe) private static var script: NSAppleScript?

    private init() {}

    /// Follows the setting. Scripted runs never touch your Finder.
    func update() {
        let on = Prefs.shared.takeOverFinder && !Session.isScripted
        Self.log.notice("catching Finder windows: \(on ? "on" : "off", privacy: .public)")
        if on && observer == nil {
            observer = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let isFinder = app?.bundleIdentifier == Self.finderID
                MainActor.assumeIsolated { FinderTakeover.shared.activated(finder: isFinder) }
            }
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.finderID { activated(finder: true) }
        } else if !on, let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            self.observer = nil
            activated(finder: false)
        }
    }

    /// Asks for permission to control Finder (macOS shows its prompt the first time), without
    /// taking any windows yet.
    func requestPermission() {
        queue.async {
            let error = Self.run("tell application \"Finder\" to count Finder windows").error
            Self.log.notice("permission check: \(error.map(String.init) ?? "allowed", privacy: .public)")
            DispatchQueue.main.async { FinderTakeover.shared.isDenied = error == Self.notPermitted }
        }
    }

    private func activated(finder: Bool) {
        checking?.cancel()
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        guard finder else {
            checking = nil
            return
        }
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                                                         reason: "Catching Finder windows")
        Self.log.notice("Finder came forward")
        // A window can appear a moment after Finder comes forward, and Spotlight or the Dock
        // can open one while Finder is already in front, so keep looking while it's there.
        checking = Task {
            for delay in [0.05, 0.2, 0.4] + Array(repeating: 1.0, count: 600) {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.finderID else { return }
                await takeWindows()
            }
        }
    }

    private func takeWindows() async {
        let windows: FinderWindows? = await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: Self.readAndClose()) }
        }
        guard let windows else { return }
        Self.log.notice("took \(windows.folders.count) Finder windows, \(windows.selection.count) selected")
        for opening in windows.openings { AppDelegate.show(opening.urls, revealing: opening.revealing) }
    }

    /// Finder's folder windows (front first) and its selection, after closing those windows.
    /// Nil when there were none, or Finder wouldn't say.
    nonisolated private static func readAndClose() -> FinderWindows? {
        let source = """
        with timeout of 5 seconds
            tell application "Finder"
                set shown to {}
                set picked to {}
                if (count of Finder windows) is 0 then return {shown, picked}
                try
                    repeat with chosen in (selection as alias list)
                        set end of picked to POSIX path of chosen
                    end repeat
                end try
                -- By id: closing one renumbers the rest.
                repeat with windowID in (get id of every Finder window)
                    try
                        set shownWindow to Finder window id (contents of windowID)
                        set end of shown to POSIX path of ((target of shownWindow) as alias)
                        close shownWindow
                    end try
                end repeat
                return {shown, picked}
            end tell
        end timeout
        """
        if script == nil {
            script = NSAppleScript(source: source)
            script?.compileAndReturnError(nil)
        }
        guard let script else { return nil }
        var info: NSDictionary?
        let result = script.executeAndReturnError(&info)
        if let number = info?[NSAppleScript.errorNumber] as? Int {
            log.notice("Finder said no: \(number, privacy: .public) \(info?[NSAppleScript.errorMessage] as? String ?? "", privacy: .public)")
            if number == notPermitted { DispatchQueue.main.async { FinderTakeover.shared.isDenied = true } }
            return nil
        }
        DispatchQueue.main.async { FinderTakeover.shared.isDenied = false }
        guard result.numberOfItems == 2 else { return nil }
        let windows = strings(result.atIndex(1))
        guard !windows.isEmpty else { return nil }
        return FinderWindows(folders: windows, selection: strings(result.atIndex(2)))
    }

    nonisolated private static func run(_ source: String) -> (result: NSAppleEventDescriptor?, error: Int?) {
        var info: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&info)
        return (result, info?[NSAppleScript.errorNumber] as? Int)
    }

    nonisolated private static func strings(_ list: NSAppleEventDescriptor?) -> [String] {
        guard let list, list.numberOfItems > 0 else { return [] }
        return (1...list.numberOfItems).compactMap { list.atIndex($0)?.stringValue }
    }
}

/// What Finder had open, and what TheExplorer opens for it.
struct FinderWindows: Equatable {
    /// Folder paths, front window first.
    let folders: [String]
    /// What was selected in Finder.
    let selection: [String]

    struct Opening: Equatable {
        let urls: [URL]
        let revealing: Bool
    }

    /// The other windows' folders as tabs behind, then the front window's: its selection
    /// revealed if it had one there, else the folder itself, so it ends up in front.
    var openings: [Opening] {
        guard let front = folders.first.map(Self.folderURL) else { return [] }
        var openings = folders.dropFirst().map(Self.folderURL).filter { $0 != front }
            .map { Opening(urls: [$0], revealing: false) }
        // Only items in the front window: with the desktop in front, the selection is there.
        let picked = selection.map { URL(fileURLWithPath: $0) }
            .filter { $0.deletingLastPathComponent().standardizedFileURL.path == front.path }
        openings.append(picked.isEmpty ? Opening(urls: [front], revealing: false) : Opening(urls: picked, revealing: true))
        return openings
    }

    private static func folderURL(_ path: String) -> URL {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }
}
