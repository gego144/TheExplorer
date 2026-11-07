import QuickLook
import QuickLookUI
import SwiftUI

extension EnvironmentValues {
    /// Opens a folder in a new tab of the current window.
    @Entry var openTab: (URL) -> Void = { _ in }
    /// Whether this is the active pane (always, unless the tab is split). Lists only take
    /// keyboard focus on their own in the active pane.
    @Entry var isActivePane = true
    /// In a split tab: makes this pane the active one (its list got focus).
    @Entry var activatePane: (() -> Void)?
    /// In a split tab: moves to the other pane (Tab in a list).
    @Entry var switchPane: (() -> Void)?
    /// The window, when its tab is split, for Copy and Move to Other Pane.
    @Entry var splitWorkspace: Workspace?
    /// The items of the list a context menu was opened in, so the menu needn't read each
    /// selected file from disk.
    @Entry var listedItems: ListedItems?
    /// List or gallery, for the file lists in a pane.
    @Entry var fileLayout = FileLayout.list
}

/// The inspector, or nothing when there's nothing to show. Its own view, so selecting files
/// (which decides whether there's anything) redraws only this, not the whole window.
struct InspectorColumn: View {
    let model: BrowserModel

    var body: some View {
        if InspectorView.hasContent(model) {
            InspectorView(model: model)
                .frame(width: 272)
                .padding([.vertical, .trailing], 10)
                // Clear of the list's last column.
                .padding(.leading, 14)
        }
    }
}

/// Keeps Quick Look on the selection. Its own view for the same reason as InspectorColumn.
private struct SelectionFollower: View {
    let model: BrowserModel

    var body: some View {
        Color.clear
            .onChange(of: model.activeSelection) { model.followSelectionInPreview() }
    }
}

/// Quick Look for one pane's files.
private struct QuickLookCarrier: View {
    let model: BrowserModel

    var body: some View {
        Color.clear
            .quickLookPreview(Binding(get: { model.previewURL }, set: { model.previewMoved(to: $0) }), in: model.previewItems)
            // A pane leaving the screen closes its preview, panel and all: left open, the
            // panel would keep showing a list nothing answers for any more.
            .onDisappear {
                guard model.previewURL != nil else { return }
                model.closePreview()
                if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible {
                    panel.close()
                }
            }
    }
}

/// A whole window: tab strip, command bar, sidebar, content, inspector and status bar.
struct WorkspaceView: View {
    @Bindable var workspace: Workspace
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let model = workspace.selected
        // The window's parts live in hosting views of their own (see WorkspaceShell); what's
        // here is what belongs to the window as a whole: sheets, alerts, Quick Look, the large
        // preview and the menus' view of it.
        WorkspaceShell(workspace: workspace)
        .ignoresSafeArea()
        .background(Theme.background)
        .foregroundStyle(Theme.text)
        .ignoresSafeArea(.container, edges: .top)
        .preferredColorScheme(Theme.colorScheme)
        .tint(Theme.accent)
        .environment(\.openTab) { url in workspace.newTab(url) }
        .environment(\.showSettings) { openSettings() }
        .navigationTitle(model.title)
        // One per pane, rebuilt when another pane or tab takes over. Quick Look's panel is
        // shared, and handing an open panel another pane's list (shorter, or empty) made
        // SwiftUI look past its end and crash.
        .background { QuickLookCarrier(model: model).id(ObjectIdentifier(model)) }
        .overlay {
            if let url = model.expandedPreview {
                ExpandedPreview(url: url, model: model)
                    .id(url)
                    .transition(.opacity.combined(with: .scale(scale: 0.985)))
            }
        }
        .animation(.easeOut(duration: 0.12), value: model.expandedPreview)
        .sheet(item: Binding(get: { model.drive.sharing }, set: { model.drive.sharing = $0 })) { sharing in
            DriveShareSheet(sharing: sharing) { model.drive.sharing = nil }
        }
        .alert("Rename", isPresented: Binding(get: { model.renaming != nil }, set: { if !$0 { model.renaming = nil } }),
               presenting: model.renaming) { item in
            NamePrompt(initialName: item.name, confirmTitle: "Rename") { model.rename(item, to: $0) }
        }
        .alert(model.creating?.title ?? "", isPresented: Binding(get: { model.creating != nil }, set: { if !$0 { model.creating = nil } }),
               presenting: model.creating) { kind in
            NamePrompt(initialName: model.suggestedName(for: kind), confirmTitle: "Create") { model.create(kind, named: $0) }
        } message: { _ in
            Text("In “\(model.destination == .drive ? model.drive.location?.name ?? "" : FileManager.default.displayName(atPath: model.currentURL.path))”")
        }
        .background(SearchRunner(model: model))
        .background(SelectionFollower(model: model))
        .focusedSceneValue(\.workspace, workspace)
    }
}

/// The tab's content, or its two panes side by side when it's split.
struct PanesRegion: View {
    @Bindable var workspace: Workspace
    /// The first pane's width when a divider drag began.
    @State private var dragStart: CGFloat = 0

    var body: some View {
        let active = workspace.selected
        let tab = workspace.currentTab
        if let second = workspace.secondPane(of: tab) {
            GeometryReader { proxy in
                let width = proxy.size.width - 1
                // Neither pane gets narrower than the list's columns need (with room for names),
                // however the divider was dragged or the window resized.
                let minimum = min(380, width / 2)
                let first = min(max(width * workspace.splitFraction(of: tab), minimum), width - minimum)
                HStack(spacing: 0) {
                    SplitPane(model: tab, workspace: workspace, isActive: active === tab) { PaneContent(model: tab) }
                        .frame(width: first)
                        .clipped()
                    SplitDivider(
                        onDrag: { began, offset in
                            if began { dragStart = first }
                            workspace.setSplitFraction((dragStart + offset) / max(width, 1), of: tab)
                        },
                        onReset: { workspace.setSplitFraction(nil, of: tab) }
                    )
                    SplitPane(model: second, workspace: workspace, isActive: active === second) { PaneContent(model: second) }
                        .frame(width: max(0, width - first))
                        .clipped()
                }
            }
        } else {
            PaneContent(model: active)
        }
    }
}

/// What a pane shows. Its own view, so typing a search redraws the pane rather than the window.
private struct PaneContent: View {
    let model: BrowserModel

    var body: some View {
        Group {
            if model.isSearching {
                SearchResultsView(model: model)
            } else {
                switch model.destination {
                case .folder: FolderView(model: model)
                case .recents: RecentsView(model: model, recents: model.recents)
                case .newFiles: RecentsView(model: model, recents: model.newFiles)
                case .storage: StorageView(model: model)
                case .s3: S3View(model: model)
                case .drive: DriveView(model: model)
                }
            }
        }
        .environment(\.fileLayout, model.layout)
    }
}

/// Runs the search as you type. Its own view, so each keystroke doesn't redraw the window.
private struct SearchRunner: View {
    let model: BrowserModel

    var body: some View {
        Color.clear
            .onChange(of: searchKey, initial: true) { run() }
    }

    private var searchKey: String {
        "\(ObjectIdentifier(model).hashValue)|\(model.searchText)|\(model.searchScope)|\(model.currentURL.path)|\(model.showHidden)"
    }

    private func run() {
        if model.isSearching {
            model.search.run(text: model.searchText, scope: model.searchScope, folder: model.currentURL, includeHidden: model.showHidden)
        } else {
            model.search.clear()
        }
    }
}

/// The line between split panes. Drag it to resize them; double-click to even them out.
private struct SplitDivider: View {
    /// Called with how far the divider has moved since the drag began.
    let onDrag: (_ began: Bool, _ offset: CGFloat) -> Void
    let onReset: () -> Void
    @State private var hovering = HoverPreview.on
    @State private var dragging = false

    var body: some View {
        Rectangle()
            .fill(hovering || dragging ? Theme.accentStrong : Theme.fieldBorder)
            .frame(width: 1)
            .overlay {
                // A wider grip than the line itself.
                DividerGrip(onDrag: onDrag, onReset: onReset, onHover: { hovering = $0 }, onDragging: { dragging = $0 })
                    .frame(width: 9)
                    #if DEBUG
                    .debugRowFrame(named: "split-divider")
                    #endif
            }
            .zIndex(1)
            .animation(Theme.hoverAnimation, value: hovering)
    }
}

/// The divider's grip, in AppKit: it takes the first click even in a window that isn't
/// focused, and shows the resize cursor.
private struct DividerGrip: NSViewRepresentable {
    let onDrag: (Bool, CGFloat) -> Void
    let onReset: () -> Void
    let onHover: (Bool) -> Void
    let onDragging: (Bool) -> Void

    func makeNSView(context: Context) -> GripView { GripView() }

    func updateNSView(_ view: GripView, context: Context) {
        view.onDrag = onDrag
        view.onReset = onReset
        view.onHover = onHover
        view.onDragging = onDragging
    }

    final class GripView: NSView {
        var onDrag: (Bool, CGFloat) -> Void = { _, _ in }
        var onReset: () -> Void = {}
        var onHover: (Bool) -> Void = { _ in }
        var onDragging: (Bool) -> Void = { _ in }
        private var start: CGFloat = 0

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .cursorUpdate],
                                           owner: self))
        }

        override func cursorUpdate(with event: NSEvent) { NSCursor.resizeLeftRight.set() }
        override func mouseEntered(with event: NSEvent) { onHover(true) }
        override func mouseExited(with event: NSEvent) { onHover(false) }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                onReset()
                return
            }
            start = event.locationInWindow.x
            onDragging(true)
            onDrag(true, 0)
        }

        override func mouseDragged(with event: NSEvent) {
            onDrag(false, event.locationInWindow.x - start)
        }

        override func mouseUp(with event: NSEvent) { onDragging(false) }
    }
}

/// One side of a split tab: a slim header saying where it is, then the pane's own list. The
/// active pane's header is raised like the selected tab; the other pane's list is dimmed, so
/// which side you're working in reads at a glance.
private struct SplitPane<Content: View>: View {
    let model: BrowserModel
    let workspace: Workspace
    let isActive: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            SplitPaneHeader(model: model, isActive: isActive, onActivate: { activate() }, onClose: { workspace.close(pane: model) })
            content()
                .overlay(InactivePaneDim(isActive: isActive))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.isActivePane, isActive)
        .environment(\.activatePane) { workspace.activate(model) }
        .environment(\.switchPane) { workspace.switchPane() }
        .environment(\.splitWorkspace, workspace)
        #if DEBUG
        .debugRowFrame(named: "pane-\(workspace.currentTab === model ? 1 : 2)")
        #endif
    }

    private func activate() {
        workspace.activate(model)
        model.listFocusRequest += 1
    }
}

/// Dims the pane you're not working in. Its own view: written inline in the generic SplitPane,
/// the release build's optimizer ran for over 15 minutes on it.
private struct InactivePaneDim: View {
    let isActive: Bool

    var body: some View {
        Rectangle()
            .fill(Theme.background.opacity(isActive ? 0 : 0.38))
            .allowsHitTesting(false)
    }
}

private struct SplitPaneHeader: View {
    let model: BrowserModel
    let isActive: Bool
    let onActivate: () -> Void
    let onClose: () -> Void
    @State private var hovering = HoverPreview.on

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isActive ? Theme.text : Theme.textTertiary)
            Text(model.title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(isActive ? Theme.text : Theme.textTertiary)
                .lineLimit(1)
            if model.destination == .folder && !model.isSearching {
                Text(Format.path(model.currentURL.deletingLastPathComponent().path))
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 4)
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold)).frame(width: 14, height: 14)
            }
            .buttonStyle(GhostButtonStyle(padding: 2, tint: Theme.textTertiary))
            .opacity(hovering || isActive ? 1 : 0)
            .help("Close Pane")
        }
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(isActive ? Theme.raised : Theme.background)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
        .contentShape(.rect)
        .onTapGesture(perform: onActivate)
        .hoverTracking { hovering = $0 }
        .animation(Theme.hoverAnimation, value: hovering)
    }

    private var symbol: String {
        if model.isSearching { return "magnifyingglass" }
        switch model.destination {
        case .folder: return "folder"
        case .recents: return "clock"
        case .newFiles: return "sparkles"
        case .storage: return "chart.pie"
        case .s3: return "cloud"
        case .drive: return "externaldrive.connected.to.line.below"
        }
    }
}

struct WorkspaceFocusKey: FocusedValueKey {
    typealias Value = Workspace
}

extension FocusedValues {
    var workspace: Workspace? {
        get { self[WorkspaceFocusKey.self] }
        set { self[WorkspaceFocusKey.self] = newValue }
    }
}

struct NamePrompt: View {
    let confirmTitle: String
    let onConfirm: (String) -> Void
    @State private var name: String

    init(initialName: String, confirmTitle: String, onConfirm: @escaping (String) -> Void) {
        self.confirmTitle = confirmTitle
        self.onConfirm = onConfirm
        _name = State(initialValue: initialName)
    }

    var body: some View {
        TextField("Name", text: $name)
        Button(confirmTitle) { onConfirm(name) }
            .keyboardShortcut(.defaultAction)
        Button("Cancel", role: .cancel) {}
    }
}


