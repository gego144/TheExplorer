import AppKit
import Observation
import UniformTypeIdentifiers

/// Where new windows start.
enum StartLocation: String, CaseIterable {
    case lastFolder = "last"
    case home
    case custom
}

/// App-wide settings and view preferences, shared by every window and persisted in
/// UserDefaults. Edited in Settings (⌘,); the browsing defaults apply to new tabs.
@MainActor
@Observable
final class Prefs {
    static let shared = Prefs()

    var showSidebar: Bool { didSet { defaults.set(showSidebar, forKey: "showSidebar") } }
    var showInspector: Bool { didSet { defaults.set(showInspector, forKey: "showInspector") } }

    /// Bundle identifier of the app "Open in Terminal" uses.
    var terminalID: String { didSet { defaults.set(terminalID, forKey: "terminalBundleID") } }

    var startLocation: StartLocation { didSet { defaults.set(startLocation.rawValue, forKey: "startLocation") } }
    var startFolder: String { didSet { defaults.set(startFolder, forKey: "startFolder") } }

    var defaultSort: SortSpec {
        didSet {
            defaults.set(defaultSort.key.rawValue, forKey: "defaultSortKey")
            defaults.set(defaultSort.ascending, forKey: "defaultSortAscending")
        }
    }
    var showHidden: Bool { didSet { defaults.set(showHidden, forKey: "showHidden") } }
    var foldersFirst: Bool { didSet { defaults.set(foldersFirst, forKey: "foldersFirst") } }

    var newHidesClutter: Bool { didSet { defaults.set(newHidesClutter, forKey: "newHidesClutter") } }
    var newRange: RecentsRange { didSet { defaults.set(newRange.rawValue, forKey: "newRangeDays") } }

    /// Which apps macOS uses as the file browser (see FolderHandler). Read from macOS, not
    /// stored here; refreshed when Settings shows and whenever the app comes forward.
    private(set) var fileViewerID = FolderHandler.finderID
    private(set) var folderOpenerID = FolderHandler.finderID
    var fileViewerIsThisApp: Bool { fileViewerID.caseInsensitiveCompare(FolderHandler.thisAppID) == .orderedSame }

    func refreshFileBrowser() {
        let viewer = FolderHandler.viewerID
        let opener = FolderHandler.folderOpenerID
        if viewer != fileViewerID { fileViewerID = viewer }
        if opener != folderOpenerID { folderOpenerID = opener }
    }

    @ObservationIgnored private let defaults = UserDefaults.standard

    private init() {
        let defaults = UserDefaults.standard
        showSidebar = defaults.object(forKey: "showSidebar") as? Bool ?? true
        showInspector = defaults.object(forKey: "showInspector") as? Bool ?? true
        terminalID = defaults.string(forKey: "terminalBundleID") ?? Terminal.appleTerminal
        startLocation = defaults.string(forKey: "startLocation").flatMap(StartLocation.init) ?? .lastFolder
        startFolder = defaults.string(forKey: "startFolder") ?? URL.home.path
        let sortKey = defaults.string(forKey: "defaultSortKey").flatMap(SortKey.init) ?? SortSpec.byChanged.key
        defaultSort = SortSpec(key: sortKey, ascending: defaults.object(forKey: "defaultSortAscending") as? Bool ?? SortSpec.byChanged.ascending)
        showHidden = defaults.bool(forKey: "showHidden")
        foldersFirst = defaults.object(forKey: "foldersFirst") as? Bool ?? true
        newHidesClutter = defaults.object(forKey: "newHidesClutter") as? Bool ?? true
        newRange = (defaults.object(forKey: "newRangeDays") as? Int).flatMap(RecentsRange.init) ?? .week
        refreshFileBrowser()
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Prefs.shared.refreshFileBrowser() }
        }
    }

    /// The folder a brand-new tab or window opens, before anything else is known.
    var startURL: URL {
        switch startLocation {
        case .home: return .home
        case .custom: return URL(fileURLWithPath: startFolder)
        case .lastFolder:
            return defaults.string(forKey: "lastPath").map(URL.init(fileURLWithPath:)) ?? .home
        }
    }

    var terminal: Terminal { Terminal(bundleID: terminalID) }
}

/// A terminal app that "Open in Terminal" can hand folders to.
struct Terminal: Identifiable, Hashable {
    static let appleTerminal = "com.apple.Terminal"
    static let cmux = "com.cmuxterm.app"

    /// Terminals offered in Settings when installed, in this order.
    static let known = [appleTerminal, cmux, "com.mitchellh.ghostty", "com.googlecode.iterm2", "dev.warp.Warp-Stable"]

    let bundleID: String
    var id: String { bundleID }

    var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }
    var isInstalled: Bool { appURL != nil }

    var name: String {
        guard let appURL else { return bundleID == Self.appleTerminal ? "Terminal" : bundleID }
        return FileManager.default.displayName(atPath: appURL.path).replacingOccurrences(of: ".app", with: "")
    }

    var icon: NSImage? {
        appURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    /// Installed known terminals, plus `current` if it's something else you picked.
    static func available(including current: String) -> [Terminal] {
        var ids = known.filter { Terminal(bundleID: $0).isInstalled }
        if !ids.contains(current) && Terminal(bundleID: current).isInstalled { ids.append(current) }
        return ids.map(Terminal.init)
    }

    /// Opens a new terminal session in `folder`.
    func open(_ folder: URL) {
        guard let appURL = appURL ?? Terminal(bundleID: Self.appleTerminal).appURL else { return }
        // cmux opens folders through its command-line tool (a new workspace in that folder).
        let cli = appURL.appendingPathComponent("Contents/Resources/bin/cmux")
        if bundleID == Self.cmux, FileManager.default.isExecutableFile(atPath: cli.path) {
            let process = Process()
            process.executableURL = cli
            process.arguments = [folder.path]
            process.terminationHandler = { finished in
                guard finished.terminationStatus != 0 else { return }
                // The tool couldn't reach cmux; fall back to opening the app with the folder.
                DispatchQueue.main.async { Self.openWithApp(appURL, folder: folder) }
            }
            do {
                try process.run()
                NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
                return
            } catch {}
        }
        Self.openWithApp(appURL, folder: folder)
    }

    private static func openWithApp(_ appURL: URL, folder: URL) {
        NSWorkspace.shared.open([folder], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// Which app macOS treats as the file browser, in its two parts:
///
/// - The file viewer (`NSFileViewer`): where other apps' "Show in Finder" and "Reveal" buttons
///   show items. Any app can be chosen, and it applies right away.
/// - The folder opener: the app folders opened from other apps, the Dock or Spotlight open in.
///   macOS 26 keeps this as Finder: Launch Services rejects changes (paramErr, even to set
///   Finder again) and drops a hand-written handler entry at login. Older systems may accept
///   the change, so it's still attempted.
@MainActor
enum FolderHandler {
    static let finderURL = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
    static let finderID = "com.apple.finder"
    static var thisAppID: String { Bundle.main.bundleIdentifier ?? "com.gego.TheExplorer" }

    enum Failure: LocalizedError {
        case notSaved
        var errorDescription: String? { "macOS didn't keep the change. Try again, or check that your preferences folder is writable." }
    }

    private static let viewerKey = "NSFileViewer" as CFString
    private static let handlersKey = "LSHandlers" as CFString
    private static let handlersDomain = "com.apple.LaunchServices/com.apple.launchservices.secure" as CFString
    nonisolated private static let folderType = "public.folder"

    /// The file viewer, read fresh so changes made elsewhere (e.g. `defaults write`) show up.
    static var viewerID: String {
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        let viewer = CFPreferencesCopyValue(viewerKey, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        return viewer as? String ?? finderID
    }

    /// The app macOS opens folders with right now.
    static var folderOpenerID: String {
        NSWorkspace.shared.urlForApplication(toOpen: .folder).flatMap { Bundle(url: $0)?.bundleIdentifier } ?? finderID
    }

    /// Makes `bundleID` the file viewer, then reads it back to confirm macOS kept it.
    static func setViewer(_ bundleID: String) throws {
        let isFinder = bundleID.caseInsensitiveCompare(finderID) == .orderedSame
        CFPreferencesSetValue(viewerKey, isFinder ? nil : bundleID as CFString,
                              kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        removeOwnFolderEntry()
        guard viewerID.caseInsensitiveCompare(bundleID) == .orderedSame else { throw Failure.notSaved }
    }

    /// Asks Launch Services to make `app` the folder opener. macOS 26 refuses; older systems may not.
    static func requestFolderOpener(_ app: URL) async {
        try? await NSWorkspace.shared.setDefaultApplication(at: app, toOpen: .folder)
    }

    /// Earlier versions wrote a folder entry into Launch Services' handler list; macOS 26 drops
    /// it at login anyway, so take ours out rather than leave it behind.
    private static func removeOwnFolderEntry() {
        let stored = CFPreferencesCopyValue(handlersKey, handlersDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            as? [[String: Any]] ?? []
        let cleaned = withoutFolderEntry(for: thisAppID, in: stored)
        guard cleaned.count != stored.count else { return }
        CFPreferencesSetValue(handlersKey, cleaned as CFArray, handlersDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(handlersDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    /// The handler list without a folder entry pointing at `bundleID`; every other entry is kept.
    nonisolated static func withoutFolderEntry(for bundleID: String, in handlers: [[String: Any]]) -> [[String: Any]] {
        handlers.filter { entry in
            guard (entry["LSHandlerContentType"] as? String)?.lowercased() == folderType else { return true }
            let role = entry["LSHandlerRoleAll"] as? String ?? entry["LSHandlerRoleViewer"] as? String
            return role?.caseInsensitiveCompare(bundleID) != .orderedSame
        }
    }
}
