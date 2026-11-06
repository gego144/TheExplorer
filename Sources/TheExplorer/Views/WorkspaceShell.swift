import AppKit
import Observation
import SwiftUI

extension EnvironmentValues {
    /// Opens Settings. Set where the window is made, since SwiftUI's own action only works in
    /// views that SwiftUI's window holds directly, and the window's parts live in hosting views
    /// of their own (see WorkspaceShell).
    @Entry var showSettings: () -> Void = {}
}

/// The window's parts, laid out by AppKit: the tab strip and sidebar (drawn by AppKit too),
/// and the command bar, panes, inspector and status bar, each in a hosting view of its own.
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
}

final class WorkspaceShellView: NSView {
    private let workspace: Workspace
    private var tabs: NSView!
    private var command: RegionHostingView!
    private var sidebar: NSView!
    private var panes: RegionHostingView!
    private var inspector: RegionHostingView!
    private var status: RegionHostingView!

    /// What decides the layout, read under Observation tracking so a change re-lays it out.
    private var showsSidebar = true
    private var showsInspector = true
    private var tracking = false

    static let commandHeight: CGFloat = 46
    static let statusHeight: CGFloat = 26
    static let sidebarWidth: CGFloat = 192
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
            addSubview(view)
            return view
        }
        tabs = TabStripView(workspace: workspace)
        addSubview(tabs)
        weak var shell: WorkspaceShellView?
        command = host(CommandBarRegion(workspace: workspace).environment(\.reportDropdown) { frame in
            shell?.dropdown = frame
        }, as: CommandBarHostingView.self, name: "command")
        sidebar = SidebarPanel(workspace: workspace, values: values)
        addSubview(sidebar)
        panes = host(PanesRegion(workspace: workspace), name: "list")
        inspector = host(InspectorRegion(workspace: workspace), name: "inspector")
        status = host(StatusBarRegion(workspace: workspace), name: "status")
        // The command bar's dropdown hangs over the content below it.
        command.layer?.zPosition = 1
        shell = self
        trackLayout()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The command bar's open dropdown, in the window from its top left; the bar's view grows
    /// to hold it.
    fileprivate var dropdown: CGRect? {
        didSet {
            guard dropdown != oldValue else { return }
            (command as? CommandBarHostingView)?.dropdown = dropdown
            needsLayout = true
        }
    }

    /// Where this view's top is in the window, from the window's top left.
    fileprivate var topInWindow: CGFloat {
        guard let content = window?.contentView else { return 0 }
        return content.bounds.height - convert(bounds, to: nil).maxY
    }

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
        for (name, view) in [("tabs", tabs), ("command", command), ("list", panes), ("status", status)] where Self.hidden.contains(name) {
            view?.isHidden = true
        }
        if Self.hidden.contains("sidebar") { showsSidebar = false }
        if Self.hidden.contains("inspector") { showsInspector = false }
        #endif
        let width = bounds.width
        let height = bounds.height
        var y: CGFloat = 0
        tabs.frame = NSRect(x: 0, y: y, width: width, height: TabStripView.height)
        y += TabStripView.height
        let commandY = y
        y += Self.commandHeight
        let bodyHeight = max(0, height - y - Self.statusHeight)
        let left = showsSidebar ? Self.sidebarWidth : 0
        let right = showsInspector ? Self.inspectorWidth : 0
        sidebar.isHidden = !showsSidebar
        inspector.isHidden = !showsInspector
        sidebar.frame = NSRect(x: 0, y: y, width: left, height: bodyHeight)
        panes.frame = NSRect(x: left, y: y, width: max(0, width - left - right), height: bodyHeight)
        inspector.frame = NSRect(x: width - right, y: y, width: right, height: bodyHeight)
        status.frame = NSRect(x: 0, y: height - Self.statusHeight, width: width, height: Self.statusHeight)
        // The command bar's view reaches down over the content while a dropdown is open; its
        // empty part passes clicks through (see CommandBarHostingView).
        let reach = dropdown.map { max(Self.commandHeight, $0.maxY - topInWindow - commandY + 24) } ?? Self.commandHeight
        command.frame = NSRect(x: 0, y: commandY, width: width, height: min(reach, height - commandY))
    }
}

/// The command bar's view: it reaches down over the content while its dropdown is open, and
/// clicks on the part below the bar that isn't the dropdown go through to what's underneath.
final class CommandBarHostingView: RegionHostingView {
    /// The open dropdown, in the window from its top left.
    var dropdown: CGRect?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview, let content = window?.contentView else { return super.hitTest(point) }
        let local = convert(point, from: superview)
        let fromTop = isFlipped ? local.y : bounds.height - local.y
        if fromTop > WorkspaceShellView.commandHeight {
            let inWindow = superview.convert(point, to: nil)
            let windowPoint = CGPoint(x: inWindow.x, y: content.bounds.height - inWindow.y)
            if !(dropdown?.contains(windowPoint) ?? false) { return nil }
        }
        return super.hitTest(point)
    }
}

// MARK: - The parts

/// Each part reads the active pane itself, so switching tabs updates just the parts that show it.
private struct CommandBarRegion: View {
    let workspace: Workspace
    var body: some View {
        // At the top of its view, which reaches further down while the dropdown is open.
        CommandBar(model: workspace.selected)
            .frame(height: WorkspaceShellView.commandHeight)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct InspectorRegion: View {
    let workspace: Workspace
    var body: some View { InspectorColumn(model: workspace.selected) }
}

private struct StatusBarRegion: View {
    let workspace: Workspace
    var body: some View { StatusBar(model: workspace.selected) }
}

extension EnvironmentValues {
    /// The command bar's dropdown while it's open, in the window from its top left (SwiftUI's
    /// `.global` space), so the bar's view can reach down to hold it.
    @Entry var reportDropdown: (CGRect?) -> Void = { _ in }
}
