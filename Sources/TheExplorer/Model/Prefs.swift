import AppKit
import Observation

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
