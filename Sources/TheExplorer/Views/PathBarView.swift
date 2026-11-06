import AppKit
import Observation
import SwiftUI

/// The row above the list: back and forward, where you are ("~ › Dev › TheExplorer"), and the
/// repository's branch when there is one. A click on its empty part opens ⌘K.
final class PathBarView: NSView {
    static let height: CGFloat = 36

    private let workspace: Workspace
    private let values: RegionValues
    private let theme = TableTheme()
    private let back: BarButton
    private let forward: BarButton
    private let crumbs = PathCrumbsView()
    /// S3 and Drive paths, which stay SwiftUI.
    private var remoteCrumbs: RegionHostingView?
    private let titleFont = NSFont.systemFont(ofSize: 12.5, weight: .medium)
    private let gitFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    private let warning = NSColor(Theme.warning)

    private var destination = Destination.folder
    private var placeTitle = ""
    private var git: GitSnapshot?
    private var generation = 0
    private weak var remoteModel: BrowserModel?

    init(workspace: Workspace, values: RegionValues) {
        self.workspace = workspace
        self.values = values
        back = BarButton("chevron.left", style: .ghost, size: 11, weight: .semibold, help: "Back (⌘[)", theme: theme)
        forward = BarButton("chevron.right", style: .ghost, size: 11, weight: .semibold, help: "Forward (⌘])", theme: theme)
        super.init(frame: .zero)
        back.action = { [weak workspace] in workspace?.selected.goBack() }
        forward.action = { [weak workspace] in workspace?.selected.goForward() }
        for view in [back, forward, crumbs] as [NSView] { addSubview(view) }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func refresh() {
        generation += 1
        let current = generation
        withObservationTracking { apply() } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.generation == current else { return }
                self.refresh()
            }
        }
    }

    private func apply() {
        let model = workspace.selected
        back.isEnabled = !model.backStack.isEmpty
        forward.isEnabled = !model.forwardStack.isEmpty
        destination = model.isSearching ? .folder : model.destination
        placeTitle = model.title
        git = model.destination == .folder ? model.git?.snapshot : nil
        crumbs.model = model
        crumbs.openTab = values.openTab
        let trail = Self.trail(of: model)
        if crumbs.trail != trail { crumbs.trail = trail }
        updateRemoteCrumbs(model)
        needsLayout = true
        needsDisplay = true
    }

    /// The folders from the home folder (or /) down to this one.
    static func trail(of model: BrowserModel) -> [URL] {
        guard model.destination == .folder else { return [] }
        var urls: [URL] = []
        var path = model.currentURL.path
        let home = URL.home.path
        while true {
            urls.insert(URL(fileURLWithPath: path, isDirectory: true), at: 0)
            if path == "/" || path == home || path.isEmpty { break }
            path = (path as NSString).deletingLastPathComponent
        }
        return urls
    }

    private func updateRemoteCrumbs(_ model: BrowserModel) {
        guard model.destination == .s3 || model.destination == .drive else {
            remoteCrumbs?.removeFromSuperview()
            remoteCrumbs = nil
            remoteModel = nil
            return
        }
        guard remoteCrumbs == nil || remoteModel !== model || remoteDestination != model.destination else { return }
        remoteModel = model
        remoteDestination = model.destination
        let content = model.destination == .s3 ? AnyView(S3Breadcrumbs(model: model)) : AnyView(DriveBreadcrumbs(model: model))
        let root = AnyView(content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading).modifier(RegionStyle(values: values)))
        if let remoteCrumbs {
            remoteCrumbs.rootView = root
        } else {
            let view = RegionHostingView(rootView: root)
            addSubview(view)
            remoteCrumbs = view
        }
    }

    private var remoteDestination: Destination?

    private var gitText: String? {
        guard let git else { return nil }
        let name = git.branch ?? git.commit ?? "detached"
        var text = name.count > 30 ? name.prefix(14) + "…" + name.suffix(14) : name
        if git.ahead > 0 { text += " ↑\(git.ahead)" }
        if git.behind > 0 { text += " ↓\(git.behind)" }
        return text
    }

    private var gitChanges: String? {
        guard let git, git.changeCount > 0 else { return nil }
        return "\(git.changeCount) changed"
    }

    private var navEnd: CGFloat { 12 + 24 + 2 + 24 + 8 }

    override func layout() {
        super.layout()
        back.frame = NSRect(x: 12, y: (bounds.height - 24) / 2, width: 24, height: 24)
        forward.frame = NSRect(x: 12 + 26, y: (bounds.height - 24) / 2, width: 24, height: 24)
        let gitWidth = gitText.map { text in
            ceil(TextLines.shared.line(text, font: gitFont, color: theme.textSecondary).width)
                + (gitChanges.map { ceil(TextLines.shared.line(" · " + $0, font: gitFont, color: warning).width) } ?? 0) + 16
        } ?? 0
        let frame = NSRect(x: navEnd - 6, y: (bounds.height - Theme.smallControlHeight) / 2,
                           width: max(0, bounds.width - navEnd + 6 - 16 - gitWidth), height: Theme.smallControlHeight)
        crumbs.isHidden = destination != .folder
        crumbs.frame = frame
        remoteCrumbs?.frame = frame
    }

    override func draw(_ dirtyRect: NSRect) {
        theme.border.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        let midY = bounds.midY
        // A place that isn't a folder ("Recents") shows its name.
        if destination != .folder && !destination.isRemote {
            FileCellView.drawText(placeTitle, font: titleFont, color: theme.text, x: navEnd, midY: midY, width: bounds.width - navEnd - 16)
        }
        // The repository's branch, and how many files changed.
        guard let text = gitText else { return }
        let changes = gitChanges.map { " · " + $0 }
        let changesWidth = changes.map { ceil(TextLines.shared.line($0, font: gitFont, color: warning).width) } ?? 0
        let textWidth = ceil(TextLines.shared.line(text, font: gitFont, color: theme.textSecondary).width)
        let x = bounds.width - 16 - changesWidth - textWidth
        FileCellView.drawText(text, font: gitFont, color: theme.textSecondary, x: x, midY: midY, width: textWidth + 2)
        if let changes {
            FileCellView.drawText(changes, font: gitFont, color: warning, x: x + textWidth, midY: midY, width: changesWidth + 2)
        }
    }

    /// The empty part of the row opens ⌘K, as the field there used to.
    override func mouseDown(with event: NSEvent) {
        workspace.selected.omniboxRequest = OmniboxRequest(text: "")
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .iBeam)
    }
}

/// The view controls at the right of the tab bar: the sort (with the other view options in its
/// menu), list or gallery, and the details panel.
final class ViewControlsView: NSView {
    private let workspace: Workspace
    private let theme = TableTheme()
    private let options: QuietButton
    private let list: QuietButton
    private let gallery: QuietButton
    private let details: QuietButton
    private var generation = 0

    init(workspace: Workspace) {
        self.workspace = workspace
        options = QuietButton("Options", help: "Sort and view options", theme: theme)
        list = QuietButton("List", help: "As List (⌥⌘1)", theme: theme)
        gallery = QuietButton("Gallery", help: "As Gallery (⌥⌘2)", theme: theme)
        details = QuietButton("Details", help: "Details (⌘I)", theme: theme)
        super.init(frame: .zero)
        options.popUpMenu = { [weak self] in self?.optionsMenu() ?? NSMenu() }
        list.action = { [weak workspace] in workspace?.selected.layout = .list }
        gallery.action = { [weak workspace] in workspace?.selected.layout = .gallery }
        details.action = { Prefs.shared.showInspector.toggle() }
        for view in [options, list, gallery, details] { addSubview(view) }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    private func refresh() {
        generation += 1
        let current = generation
        withObservationTracking { apply() } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.generation == current else { return }
                self.refresh()
            }
        }
    }

    private func apply() {
        let model = workspace.selected
        let sortable = model.destination == .folder && !model.isSearching
        options.title = sortable ? Self.sortTitle(model.sort) : "Options"
        let hasLayout = model.layoutPlace != nil
        list.isHidden = !hasLayout
        gallery.isHidden = !hasLayout
        list.isOn = hasLayout && model.layout == .list
        gallery.isOn = hasLayout && model.layout == .gallery
        details.isOn = Prefs.shared.showInspector
        needsLayout = true
        superview?.needsLayout = true
    }

    private static func sortTitle(_ sort: SortSpec) -> String {
        let name = switch sort.key {
        case .name: "Name"
        case .kind: "Kind"
        case .size: "Size"
        case .created: "Created"
        case .modified, .date: "Modified"
        }
        return name + (sort.ascending ? " ↑" : " ↓")
    }

    var width: CGFloat {
        [options, list, gallery, details].filter { !$0.isHidden }.reduce(0) { $0 + $1.width + 2 } + 10
    }

    override func layout() {
        super.layout()
        var x = bounds.width - 10
        for button in [details, gallery, list, options] where !button.isHidden {
            x -= button.width
            button.frame = NSRect(x: x, y: (bounds.height - 26) / 2, width: button.width, height: 26)
            x -= 2
        }
    }

    private func optionsMenu() -> NSMenu {
        let model = workspace.selected
        let menu = NSMenu()
        menu.autoenablesItems = false
        if model.destination == .folder && !model.isSearching {
            for (title, key) in [("Name", SortKey.name), ("Kind", .kind), ("Size", .size), ("Modified", .modified), ("Created", .created)] {
                let item = ActionMenuItem(title) { model.sort = model.sort.toggled(to: key) }
                if model.sort.key == key {
                    item.state = .on
                    item.title = title + (model.sort.ascending ? " ↑" : " ↓")
                }
                menu.addItem(item)
            }
            menu.addItem(.separator())
            for (title, filter) in [("All Items", KindFilter.all), ("Folders Only", .folders), ("Files Only", .files)] {
                let item = ActionMenuItem(title) { model.kindFilter = filter }
                item.state = model.kindFilter == filter ? .on : .off
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }
        let foldersFirst = ActionMenuItem("Folders First") { model.foldersFirst.toggle() }
        foldersFirst.state = model.foldersFirst ? .on : .off
        let hidden = ActionMenuItem("Show Hidden Files") { model.showHidden.toggle() }
        hidden.state = model.showHidden ? .on : .off
        menu.addItem(foldersFirst)
        menu.addItem(hidden)
        let sidebar = ActionMenuItem("Show Sidebar") { Prefs.shared.showSidebar.toggle() }
        sidebar.state = Prefs.shared.showSidebar ? .on : .off
        menu.addItem(sidebar)
        menu.addItem(.separator())
        let newFolder = ActionMenuItem("New Folder…") { model.creating = .folder }
        let newFile = ActionMenuItem("New File…") { model.creating = .file }
        newFolder.isEnabled = model.canCreateItems
        newFile.isEnabled = model.canCreateItems
        menu.addItem(newFolder)
        menu.addItem(newFile)
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Recalculate Folder Sizes") { model.recalculateSizes() })
        menu.addItem(ActionMenuItem(FileActions.openInTerminalTitle) { FileActions.openInTerminal(model.currentURL) })
        return menu
    }
}
