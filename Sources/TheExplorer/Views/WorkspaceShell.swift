import AppKit
import Observation
import SwiftUI

extension EnvironmentValues {
    /// Opens Settings. Set where the window is made, since SwiftUI's own action only works in
    /// views that SwiftUI's window holds directly, and the window's parts live in hosting views
    /// of their own (see WorkspaceShell).
    @Entry var showSettings: () -> Void = {}
}

/// The window's parts, laid out by AppKit: the tab strip and view controls, the sidebar, the
/// path row, the inspector, the status bar and the ⌘K palette (drawn by AppKit too), and the
/// panes in a hosting view of their own.
///
/// SwiftUI lays out one hosting view at a time. With the whole window in one, a click in the
/// list had SwiftUI re-measure the command bar, inspector and status bar too, ~60ms in all;
/// split up, each part only lays itself out when something it shows changes.
struct WorkspaceShell: NSViewRepresentable {
    let workspace: Workspace
    @Environment(\.openSettings) private var openSettings

    func makeNSView(context: Context) -> WorkspaceShellView {
        let openSettings = self.openSettings
        let workspace = self.workspace
        let values = RegionValues(openTab: { [weak workspace] in workspace?.newTab($0) },
                                  showSettings: { openSettings() })
        return WorkspaceShellView(workspace: workspace, values: values)
    }

    func updateNSView(_ view: WorkspaceShellView, context: Context) {}

    /// The shell fills the window. Answering here matters: asked for its fitting size instead,
    /// AppKit would measure every part's hosting view, so any change at the window's root
    /// (the selection, which Quick Look follows) laid out the whole window again.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WorkspaceShellView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 1000, height: 700))
    }
}

/// What every part needs from the window, handed to each hosting view.
struct RegionValues {
    let openTab: (URL) -> Void
    let showSettings: () -> Void
}

/// The look the whole window shares, applied in each part.
struct RegionStyle: ViewModifier {
    let values: RegionValues

    func body(content: Content) -> some View {
        content
            .foregroundStyle(Theme.text)
            .tint(Theme.accent)
            .environment(\.colorScheme, Theme.colorScheme)
            .environment(\.openTab, values.openTab)
            .environment(\.showSettings, values.showSettings)
    }
}

/// A hosting view that ignores the title bar's safe area (the tab strip sits in it) and never
/// asks AppKit for a size of its own; the shell decides its frame.
class RegionHostingView: NSHostingView<AnyView> {
    required init(rootView: AnyView) {
        super.init(rootView: rootView)
        sizingOptions = []
        safeAreaRegions = []
    }

    @MainActor required init?(coder: NSCoder) { fatalError() }

    #if DEBUG
    /// Which part this is, and the time each part's layout has taken (for the loop scenes).
    var debugName = ""
    static var layoutTime: [String: Double] = [:]

    override func layout() {
        let start = ProcessInfo.processInfo.systemUptime
        super.layout()
        Self.layoutTime[debugName, default: 0] += ProcessInfo.processInfo.systemUptime - start
    }
    #endif
}

final class WorkspaceShellView: NSView {
    private let workspace: Workspace
    private var tabs: NSView!
    private var controls: ViewControlsView!
    private var pathBar: NSView!
    private var palette: CommandPaletteView!
    private var sidebar: NSView!
    private var panes: RegionHostingView!
    private var inspector: NSView!
    private var status: NSView!

    /// What decides the layout, read under Observation tracking so a change re-lays it out.
    private var showsSidebar = true
    private var showsInspector = true
    private var tracking = false

    static let statusHeight: CGFloat = 28
    static let sidebarWidth: CGFloat = 208
    static let inspectorWidth: CGFloat = 296

    init(workspace: Workspace, values: RegionValues) {
        self.workspace = workspace
        super.init(frame: .zero)
        func host<Content: View>(_ content: Content, as kind: RegionHostingView.Type = RegionHostingView.self, name: String = "") -> RegionHostingView {
            #if DEBUG
            if Self.hidden.contains(name) {
                let view = kind.init(rootView: AnyView(Color.clear))
                addSubview(view)
                return view
            }
            #endif
            let view = kind.init(rootView: AnyView(content.modifier(RegionStyle(values: values))))
            #if DEBUG
            view.debugName = name
            #endif
            addSubview(view)
            return view
        }
        tabs = TabStripView(workspace: workspace)
        addSubview(tabs)
        controls = ViewControlsView(workspace: workspace)
        addSubview(controls)
        pathBar = PathBarView(workspace: workspace, values: values)
        addSubview(pathBar)
        sidebar = SidebarPanel(workspace: workspace, values: values)
        addSubview(sidebar)
        panes = host(PanesRegion(workspace: workspace), name: "list")
        inspector = InspectorPanel(workspace: workspace, values: values)
        addSubview(inspector)
        status = StatusBarView(workspace: workspace, values: values)
        addSubview(status)
        // ⌘K, over everything.
        palette = CommandPaletteView(workspace: workspace)
        addSubview(palette)
        palette.wantsLayer = true
        palette.layer?.zPosition = 10
        trackLayout()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// Reads what the layout depends on (sidebar and inspector shown, and whether the inspector
    /// has anything to show) and lays out again when any of it changes.
    private func trackLayout() {
        withObservationTracking {
            let prefs = Prefs.shared
            showsSidebar = prefs.showSidebar
            showsInspector = prefs.showInspector && InspectorView.hasContent(workspace.selected)
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.trackLayout()
                self.needsLayout = true
            }
        }
    }

    #if DEBUG
    /// Parts left out (EXPLORER_HIDE=tabs,command,list,status,sidebar,inspector), to find which
    /// one a slow interaction spends its time in.
    private static let hidden = Set((ProcessInfo.processInfo.environment["EXPLORER_HIDE"] ?? "").split(separator: ",").map(String.init))
    #endif

    override func layout() {
        super.layout()
        #if DEBUG
        for (name, view) in [("tabs", tabs), ("command", pathBar), ("list", panes), ("status", status)] where Self.hidden.contains(name) {
            view?.isHidden = true
        }
        if Self.hidden.contains("sidebar") { showsSidebar = false }
        if Self.hidden.contains("inspector") { showsInspector = false }
        #endif
        let width = bounds.width
        let height = bounds.height
        // The top bar: tabs, and the view controls at its right.
        let top = TabStripView.height
        let controlsWidth = controls.width
        tabs.frame = NSRect(x: 0, y: 0, width: max(0, width - controlsWidth), height: top)
        controls.frame = NSRect(x: width - controlsWidth, y: 0, width: controlsWidth, height: TabStripView.titleBarHeight)
        // Below it, the sidebar and details run down to the status bar; between them, the
        // path row over the list.
        let bodyHeight = max(0, height - top - Self.statusHeight)
        let left = showsSidebar ? Self.sidebarWidth : 0
        let right = showsInspector ? Self.inspectorWidth : 0
        let middle = max(0, width - left - right)
        sidebar.isHidden = !showsSidebar
        inspector.isHidden = !showsInspector
        sidebar.frame = NSRect(x: 0, y: top, width: left, height: bodyHeight)
        pathBar.frame = NSRect(x: left, y: top, width: middle, height: PathBarView.height)
        panes.frame = NSRect(x: left, y: top + PathBarView.height, width: middle, height: max(0, bodyHeight - PathBarView.height))
        inspector.frame = NSRect(x: width - right, y: top, width: right, height: bodyHeight)
        status.frame = NSRect(x: 0, y: height - Self.statusHeight, width: width, height: Self.statusHeight)
        palette.frame = bounds
    }

    /// The line under the top bar.
    override func draw(_ dirtyRect: NSRect) {
        NSColor(Theme.border).setFill()
        NSRect(x: 0, y: TabStripView.height - 1, width: bounds.width, height: 1).fill()
    }
}
