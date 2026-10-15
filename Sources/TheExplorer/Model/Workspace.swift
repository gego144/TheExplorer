import AppKit
import Observation
import SwiftUI

/// App-wide view preferences, shared by every window.
@MainActor
@Observable
final class Prefs {
    static let shared = Prefs()

    var showSidebar: Bool { didSet { UserDefaults.standard.set(showSidebar, forKey: "showSidebar") } }
    var showInspector: Bool { didSet { UserDefaults.standard.set(showInspector, forKey: "showInspector") } }

    private init() {
        let defaults = UserDefaults.standard
        showSidebar = defaults.object(forKey: "showSidebar") as? Bool ?? true
        showInspector = defaults.object(forKey: "showInspector") as? Bool ?? true
    }
}

/// What a window is opened with: its tabs' folders and which one is active. The id makes every
/// open unique (SwiftUI otherwise reuses a window already showing an equal value).
struct WindowState: Codable, Hashable {
    var id = UUID()
    var paths: [String]
    var selected: Int
}

/// One window: an ordered set of tabs, each a full browser with its own folder and history.
@MainActor
@Observable
final class Workspace {
    private(set) var tabs: [BrowserModel]
    private(set) var selectedIndex: Int

    var selected: BrowserModel { tabs[selectedIndex] }

    init(state: WindowState?) {
        let paths = state?.paths.filter { FileManager.default.fileExists(atPath: $0) } ?? []
        if paths.isEmpty {
            tabs = [BrowserModel()]
            selectedIndex = 0
        } else {
            tabs = paths.map { BrowserModel(url: URL(fileURLWithPath: $0)) }
            selectedIndex = min(max(0, state?.selected ?? 0), paths.count - 1)
        }
    }

    var state: WindowState {
        WindowState(paths: tabs.map(\.currentURL.path), selected: selectedIndex)
    }

    func start() {
        selected.start()
        Session.register(self)
    }

    // MARK: - Tabs

    /// Opens `url` in a new tab right after the current one.
    func newTab(_ url: URL? = nil, select: Bool = true) {
        let tab = BrowserModel(url: url ?? selected.currentURL)
        let index = selectedIndex + 1
        tabs.insert(tab, at: index)
        if select { self.select(index) } else { tab.start() }
    }

    func select(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        selectedIndex = index
        tabs[index].start()
    }

    func select(_ tab: BrowserModel) {
        if let index = tabs.firstIndex(where: { $0 === tab }) { select(index) }
    }

    func selectNext() { select((selectedIndex + 1) % tabs.count) }
    func selectPrevious() { select((selectedIndex - 1 + tabs.count) % tabs.count) }

    /// Closes a tab. Returns false when it was the last one, so the caller closes the window.
    @discardableResult
    func close(_ tab: BrowserModel) -> Bool {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0 === tab }) else { return false }
        tabs.remove(at: index)
        if index < selectedIndex || selectedIndex >= tabs.count {
            selectedIndex = max(0, selectedIndex - 1)
        }
        selected.start()
        return true
    }

    func closeOthers(than tab: BrowserModel) {
        tabs = tabs.filter { $0 === tab }
        selectedIndex = 0
    }

    func move(_ tab: BrowserModel, to destination: Int) {
        guard let from = tabs.firstIndex(where: { $0 === tab }) else { return }
        let current = selected
        tabs.remove(at: from)
        tabs.insert(tab, at: min(max(0, destination), tabs.count))
        selectedIndex = tabs.firstIndex { $0 === current } ?? 0
    }
}

/// Saves every window's tabs on quit and reopens them at launch (macOS skips window restoration
/// when "Close windows when quitting an application" is on, which is the default).
@MainActor
enum Session {
    private static let key = "savedWindows"
    private static var live: [WeakWorkspace] = []
    private static var restored = false

    private struct WeakWorkspace {
        weak var workspace: Workspace?
    }

    static func register(_ workspace: Workspace) {
        live.removeAll { $0.workspace == nil || $0.workspace === workspace }
        live.append(WeakWorkspace(workspace: workspace))
    }

    /// Scripted debug runs start from a clean slate and leave nothing behind.
    private static var isScripted: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["EXPLORER_SCENES"] != nil
        #else
        false
        #endif
    }

    /// For scripted debug runs only: the first window, standing in for the focused one.
    static var scriptedWorkspace: Workspace? {
        isScripted ? live.first?.workspace : nil
    }

    static func save() {
        guard !isScripted else { return }
        let states = live.compactMap(\.workspace).map(\.state)
        UserDefaults.standard.set(try? JSONEncoder().encode(states), forKey: key)
    }

    /// The saved windows, once per launch, for the first window to restore.
    static func takeSavedWindows() -> [WindowState] {
        guard !restored, !isScripted else { return [] }
        restored = true
        guard let data = UserDefaults.standard.data(forKey: key),
              let states = try? JSONDecoder().decode([WindowState].self, from: data) else { return [] }
        return states.filter { state in state.paths.contains { FileManager.default.fileExists(atPath: $0) } }
    }

    /// Called by a window that opened without saved state; later windows don't restore.
    static func markRestored() { restored = true }
}
