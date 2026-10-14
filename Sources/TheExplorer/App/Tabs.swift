import AppKit
import SwiftUI

/// The value each browser window/tab is opened with. The id makes every open unique
/// (SwiftUI otherwise focuses an existing window showing the same value), and the path is
/// kept current so tabs reopen where you left them.
struct TabSeed: Codable, Hashable {
    var id = UUID()
    var path: String

    var url: URL { URL(fileURLWithPath: path) }
}

/// Opens folders in native window tabs, grouped with the window that asked, and saves/restores
/// the tab layout across launches (macOS skips window restoration when "Close windows when
/// quitting an application" is on, which is the default).
@MainActor
enum Tabs {
    static let tabbingIdentifier = "TheExplorer.browser"

    private struct Pending {
        weak var host: NSWindow?
        var activate: Bool
        /// Tabs to open alongside this window once it exists (restoring a saved window).
        var followers: [String] = []
        var selectedFollower: Int?
    }

    private struct SavedGroup: Codable {
        var paths: [String]
        var selected: Int
    }

    private static var pending: [UUID: Pending] = [:]
    private static let models = NSMapTable<NSWindow, BrowserModel>.weakToWeakObjects()
    private static var sessionChecked = false
    private static let sessionKey = "savedTabGroups"

    static func open(_ url: URL, with openWindow: OpenWindowAction) {
        let host = NSApp.keyWindow.flatMap { $0.tabbingIdentifier == tabbingIdentifier ? $0 : nil }
        open(path: url.standardizedFileURL.path, host: host, activate: true, using: openWindow)
    }

    private static func open(path: String, host: NSWindow?, activate: Bool, followers: [String] = [],
                             selectedFollower: Int? = nil, using openWindow: OpenWindowAction) {
        let seed = TabSeed(path: path)
        pending[seed.id] = Pending(host: host, activate: activate, followers: followers, selectedFollower: selectedFollower)
        openWindow(value: seed)
    }

    /// Called once a browser window exists: makes it tabbable, joins it to the tab group it was
    /// opened for, and opens any tabs that were saved alongside it.
    static func configure(_ window: NSWindow, seedID: UUID?, startedFresh: Bool, model: BrowserModel,
                          openWindow: OpenWindowAction) {
        window.tabbingIdentifier = tabbingIdentifier
        window.tabbingMode = .automatic
        models.setObject(model, forKey: window)

        if let seedID, let request = pending.removeValue(forKey: seedID) {
            if let host = request.host, host !== window {
                let previouslySelected = host.tabGroup?.selectedWindow ?? host
                host.addTabbedWindow(window, ordered: .above)
                // SwiftUI finishes presenting the window after this hook, so pick the tab afterwards.
                DispatchQueue.main.async { [weak window, weak host] in
                    if request.activate {
                        window?.makeKeyAndOrderFront(nil)
                    } else if let group = host?.tabGroup, group.windows.contains(where: { $0 === previouslySelected }) {
                        group.selectedWindow = previouslySelected
                    }
                }
            }
            openFollowers(request.followers, selected: request.selectedFollower, host: window, using: openWindow)
        } else if startedFresh, !sessionChecked {
            sessionChecked = true
            restoreSession(into: window, model: model, using: openWindow)
        }
        sessionChecked = true
    }

    private static func openFollowers(_ paths: [String], selected: Int?, host: NSWindow, using openWindow: OpenWindowAction) {
        for (index, path) in paths.enumerated() {
            open(path: path, host: host, activate: index == selected, using: openWindow)
        }
    }

    // MARK: - Session

    /// Saves every browser window's tabs, front window first.
    static func saveSession() {
        var seen = Set<ObjectIdentifier>()
        var groups: [SavedGroup] = []
        for window in NSApp.orderedWindows where window.tabbingIdentifier == tabbingIdentifier {
            guard !seen.contains(ObjectIdentifier(window)) else { continue }
            let tabs = window.tabbedWindows ?? [window]
            tabs.forEach { seen.insert(ObjectIdentifier($0)) }
            let paths = tabs.compactMap { models.object(forKey: $0)?.currentURL.path }
            guard !paths.isEmpty else { continue }
            let selectedWindow = window.tabGroup?.selectedWindow ?? window
            groups.append(SavedGroup(paths: paths, selected: tabs.firstIndex { $0 === selectedWindow } ?? 0))
        }
        UserDefaults.standard.set(try? JSONEncoder().encode(groups), forKey: sessionKey)
    }

    private static func restoreSession(into window: NSWindow, model: BrowserModel, using openWindow: OpenWindowAction) {
        guard let data = UserDefaults.standard.data(forKey: sessionKey),
              let saved = try? JSONDecoder().decode([SavedGroup].self, from: data) else { return }
        // Drop folders that were deleted or unmounted since last time.
        let groups = saved.compactMap { group -> SavedGroup? in
            let kept = group.paths.filter { FileManager.default.fileExists(atPath: $0) }
            guard !kept.isEmpty else { return nil }
            let selectedPath = group.paths.indices.contains(group.selected) ? group.paths[group.selected] : nil
            return SavedGroup(paths: kept, selected: selectedPath.flatMap { kept.firstIndex(of: $0) } ?? 0)
        }
        guard let first = groups.first, let firstPath = first.paths.first else { return }

        // This window becomes the first tab of the front group.
        model.navigate(to: URL(fileURLWithPath: firstPath), recordHistory: false)
        let selected = first.selected > 0 ? first.selected - 1 : nil
        openFollowers(Array(first.paths.dropFirst()), selected: selected, host: window, using: openWindow)

        for group in groups.dropFirst() {
            guard let lead = group.paths.first else { continue }
            open(path: lead, host: nil, activate: false, followers: Array(group.paths.dropFirst()),
                 selectedFollower: group.selected > 0 ? group.selected - 1 : nil, using: openWindow)
        }
        window.makeKeyAndOrderFront(nil)
    }
}

/// Hands the hosting NSWindow to `onWindow` as soon as the view is installed in one.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        WindowReportingView(onWindow: onWindow)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowReportingView: NSView {
        let onWindow: (NSWindow) -> Void
        private var reported = false

        init(onWindow: @escaping (NSWindow) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, !reported else { return }
            reported = true
            onWindow(window)
        }
    }
}
