import AppKit
import Observation
import SwiftUI

/// What a window is opened with: its tabs' folders and which one is active. The id makes every
/// open unique (SwiftUI otherwise reuses a window already showing an equal value).
struct WindowState: Codable, Hashable {
    var id = UUID()
    var paths: [String]
    var selected: Int
    /// Each tab's second pane, when it's split.
    var splits: [String?]?
    /// Where each split tab's divider is, as a fraction of the width.
    var splitFractions: [Double?]?
}

/// One window: an ordered set of tabs, each a full browser with its own folder and history.
/// A tab can be split into two panes side by side; one of them is active, and everything that
/// acts on "the current folder" (the command bar, sidebar, inspector, menus) uses that one.
@MainActor
@Observable
final class Workspace {
    /// Each tab's first (left) pane, which stands for the tab.
    private(set) var tabs: [BrowserModel]
    private(set) var selectedIndex: Int
    /// The second (right) pane of each split tab, by its first pane.
    private var splits: [ObjectIdentifier: BrowserModel] = [:]
    /// Split tabs whose second pane is the active one.
    private var secondActive: Set<ObjectIdentifier> = []
    /// Where split tabs' dividers were dragged to, as a fraction of the width (half otherwise).
    private var fractions: [ObjectIdentifier: Double] = [:]

    /// The tab showing, as its first pane.
    var currentTab: BrowserModel { tabs[selectedIndex] }

    /// The active pane of the tab showing.
    var selected: BrowserModel {
        let tab = currentTab
        let key = ObjectIdentifier(tab)
        return secondActive.contains(key) ? splits[key] ?? tab : tab
    }

    init(state: WindowState?) {
        let exists = { (path: String) in FileManager.default.fileExists(atPath: path) }
        let kept = (state?.paths ?? []).enumerated().filter { exists($0.element) }
        if kept.isEmpty {
            tabs = [BrowserModel()]
            selectedIndex = 0
        } else {
            tabs = kept.map { BrowserModel(url: URL(fileURLWithPath: $0.element)) }
            selectedIndex = min(max(0, state?.selected ?? 0), kept.count - 1)
            for (tab, (index, _)) in zip(tabs, kept) {
                if let splits = state?.splits, splits.indices.contains(index), let path = splits[index], exists(path) {
                    self.splits[ObjectIdentifier(tab)] = BrowserModel(url: URL(fileURLWithPath: path))
                    if let fractions = state?.splitFractions, fractions.indices.contains(index), let fraction = fractions[index] {
                        self.fractions[ObjectIdentifier(tab)] = Self.clamped(fraction)
                    }
                }
            }
        }
    }

    var state: WindowState {
        let splits = tabs.map { secondPane(of: $0).map { pane in pane.currentURL.path } }
        let fractions = tabs.map { self.fractions[ObjectIdentifier($0)] }
        return WindowState(paths: tabs.map(\.currentURL.path), selected: selectedIndex,
                           splits: splits.contains { $0 != nil } ? splits : nil,
                           splitFractions: fractions.contains { $0 != nil } ? fractions : nil)
    }

    func start() {
        startPanes()
        Session.register(self)
    }

    private func startPanes() {
        currentTab.start()
        secondPane(of: currentTab)?.start()
    }

    // MARK: - Split panes

    func secondPane(of tab: BrowserModel) -> BrowserModel? { splits[ObjectIdentifier(tab)] }

    var isSplit: Bool { secondPane(of: currentTab) != nil }

    /// How much of the width a split tab's first pane gets.
    func splitFraction(of tab: BrowserModel) -> Double { fractions[ObjectIdentifier(tab)] ?? 0.5 }

    /// Moves a split tab's divider; nil puts it back in the middle.
    func setSplitFraction(_ fraction: Double?, of tab: BrowserModel) {
        fractions[ObjectIdentifier(tab)] = fraction.map(Self.clamped)
    }

    private static func clamped(_ fraction: Double) -> Double { min(max(fraction, 0.15), 0.85) }

    /// In a split tab, the pane that isn't active.
    var otherPane: BrowserModel? {
        guard let second = secondPane(of: currentTab) else { return nil }
        return selected === second ? currentTab : second
    }

    /// Splits the tab into two panes, the new one showing the same folder and active, or
    /// closes the second pane.
    func toggleSplit() {
        if isSplit {
            close(pane: secondPane(of: currentTab)!)
            return
        }
        let current = selected
        let pane = BrowserModel(url: current.destination == .folder ? current.currentURL : URL.home)
        // An S3 or Drive folder opens there too.
        if current.destination.isRemote { pane.navigate(to: current.historyURL, recordHistory: false) }
        splits[ObjectIdentifier(currentTab)] = pane
        pane.start()
        activate(pane)
        focusSoon(pane)
    }

    /// Puts keyboard focus in a pane's list once it's on screen.
    private func focusSoon(_ pane: BrowserModel) {
        Task {
            try? await Task.sleep(for: .milliseconds(50))
            pane.listFocusRequest += 1
        }
    }

    /// Makes a pane of the current tab the active one.
    func activate(_ pane: BrowserModel) {
        let key = ObjectIdentifier(currentTab)
        guard let second = splits[key], pane === second || pane === currentTab else { return }
        if pane === second { secondActive.insert(key) } else { secondActive.remove(key) }
    }

    /// Moves to the other pane, keyboard focus included.
    func switchPane() {
        guard let other = otherPane else { return }
        activate(other)
        other.listFocusRequest += 1
    }

    /// Puts the right pane on the left and the left on the right.
    func swapPanes() {
        let first = currentTab
        let key = ObjectIdentifier(first)
        guard let second = splits[key] else { return }
        let secondWasActive = secondActive.contains(key)
        let fraction = fractions.removeValue(forKey: key)
        splits[key] = nil
        secondActive.remove(key)
        tabs[selectedIndex] = second
        splits[ObjectIdentifier(second)] = first
        // The divider stays where it was.
        fractions[ObjectIdentifier(second)] = fraction.map { 1 - $0 }
        // The same pane stays active, now on the other side.
        if !secondWasActive { secondActive.insert(ObjectIdentifier(second)) }
        focusSoon(selected)
    }

    /// Shows the active pane's folder in the other pane too.
    func showSameFolderInOtherPane() {
        guard let other = otherPane, selected.destination == .folder || selected.destination.isRemote else { return }
        other.navigate(to: selected.destination.isRemote ? selected.historyURL : selected.currentURL)
    }

    /// Closes one pane of a split tab, leaving the other as the whole tab.
    func close(pane: BrowserModel) {
        let first = currentTab
        let key = ObjectIdentifier(first)
        guard let second = splits[key] else { return }
        splits[key] = nil
        secondActive.remove(key)
        fractions[key] = nil
        if pane === first {
            tabs[selectedIndex] = second
        }
        focusSoon(selected)
    }

    /// In a split tab, the pane across from `pane`.
    func pane(oppositeTo pane: BrowserModel) -> BrowserModel? {
        guard let second = secondPane(of: currentTab) else { return nil }
        if pane === second { return currentTab }
        return pane === currentTab ? second : nil
    }

    /// Where a pane takes items: the folder it shows, or its S3 or Drive folder. Nil while it's
    /// showing search results, Recents and the like.
    func dropFolder(of pane: BrowserModel) -> URL? {
        guard !pane.isSearching else { return nil }
        switch pane.destination {
        case .folder: return pane.currentURL
        case .s3: return pane.s3.location.flatMap { $0.bucket == nil ? nil : $0.url }
        case .drive: return pane.drive.canAddItems ? pane.drive.location?.url : nil
        case .recents, .newFiles, .storage: return nil
        }
    }

    /// F5 and F6: copies or moves items from `pane` (by default the active one, and its
    /// selection) into the other pane's folder. Returns false when there's nothing to send or
    /// nowhere to send it.
    @discardableResult
    func sendToOtherPane(_ urls: Set<URL>? = nil, from pane: BrowserModel? = nil, mode: FileTransfer.Mode) -> Bool {
        let source = pane ?? selected
        guard let target = self.pane(oppositeTo: source), let folder = dropFolder(of: target) else { return false }
        let items = (urls ?? source.activeSelection).sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        guard !items.isEmpty else { return false }
        // Moving out of S3 isn't a thing, and Drive only moves within itself; those download.
        let movable = items.allSatisfy { $0.isFileURL || ($0.scheme == DriveLocation.scheme && folder.scheme == DriveLocation.scheme) }
        return source.transfer(items, into: folder, mode: movable ? mode : .copy)
    }

    /// ⌘W: closes the active pane of a split tab, otherwise the tab. Returns false when it was
    /// the last tab, so the caller closes the window.
    @discardableResult
    func closeActivePane() -> Bool {
        if isSplit {
            close(pane: selected)
            return true
        }
        return close(currentTab)
    }

    // MARK: - Tabs

    /// Opens `url` in a new tab right after the current one.
    func newTab(_ url: URL? = nil, select: Bool = true) {
        let s3 = url.flatMap(S3Location.init(url:))
        let drive = url.flatMap(DriveLocation.init(url:))
        let tab = BrowserModel(url: s3 == nil && drive == nil ? url ?? selected.currentURL : selected.currentURL)
        if let s3 { tab.showS3(s3, recordHistory: false) }
        if let drive { tab.showDrive(drive, recordHistory: false) }
        let index = selectedIndex + 1
        tabs.insert(tab, at: index)
        if select { self.select(index) } else { tab.start() }
    }

    func select(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        selectedIndex = index
        startPanes()
    }

    /// Shows folders handed over by macOS: the tab already showing one, otherwise a new tab.
    /// Files open their folder with the file selected; `revealing` does that for folders too
    /// (other apps' "Show in Finder").
    func show(_ urls: [URL], revealing: Bool = false) {
        // Grouped by folder, so revealing several files in one folder selects them all.
        var folders: [URL] = []
        var picks: [URL: [URL]] = [:]
        for url in urls.map(\.standardizedFileURL) {
            let isFolder = !revealing && ((try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false)
            let folder = isFolder ? url : url.deletingLastPathComponent()
            if picks[folder] == nil { folders.append(folder) }
            picks[folder, default: []] += isFolder ? [] : [url]
        }
        for folder in folders {
            if let existing = tabs.first(where: { $0.destination == .folder && !$0.isSearching && $0.currentURL == folder }) {
                select(existing)
            } else {
                newTab(folder)
            }
            if let picked = picks[folder], !picked.isEmpty {
                selected.navigate(to: folder, selecting: picked, recordHistory: false)
            }
        }
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
        splits[ObjectIdentifier(tab)] = nil
        secondActive.remove(ObjectIdentifier(tab))
        fractions[ObjectIdentifier(tab)] = nil
        if index < selectedIndex || selectedIndex >= tabs.count {
            selectedIndex = max(0, selectedIndex - 1)
        }
        startPanes()
        return true
    }

    func closeOthers(than tab: BrowserModel) {
        tabs = tabs.filter { $0 === tab }
        splits = splits.filter { $0.key == ObjectIdentifier(tab) }
        secondActive = secondActive.filter { $0 == ObjectIdentifier(tab) }
        fractions = fractions.filter { $0.key == ObjectIdentifier(tab) }
        selectedIndex = 0
    }

    func move(_ tab: BrowserModel, to destination: Int) {
        guard let from = tabs.firstIndex(where: { $0 === tab }) else { return }
        let current = currentTab
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

    /// The window you used last, where folders opened from other apps go.
    private static weak var lastActive: Workspace?
    /// Folders that arrived before any window was up (e.g. the app was launched to open one).
    private static var pending: [(urls: [URL], revealing: Bool)] = []

    static func activated(_ workspace: Workspace) { lastActive = workspace }

    /// Folders macOS asked the app to open (as the default file browser, Open With, `open -a`),
    /// or items to reveal. Returns false when there's no window to show them in yet.
    static func open(_ urls: [URL], revealing: Bool = false) -> Bool {
        guard let workspace = lastActive ?? live.last(where: { $0.workspace != nil })?.workspace else {
            pending.append((urls, revealing))
            return false
        }
        workspace.show(urls, revealing: revealing)
        if !isScripted { NSApp.activate() }
        return true
    }

    /// Shows whatever arrived before this window was up.
    static func showPending(in workspace: Workspace) {
        pending.forEach { workspace.show($0.urls, revealing: $0.revealing) }
        pending = []
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
