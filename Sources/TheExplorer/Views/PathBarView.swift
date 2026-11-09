import AppKit
import Observation
import SwiftUI

/// The row above the list: back and forward, where you are ("~ › Dev › TheExplorer"), and the
/// repository's branch when there is one. Find (⌘F, or a click on its empty part) turns it into
/// a search field that filters the list right there, with where it searches beside it.
///
/// A split tab has one per pane, side by side above the two lists: each goes back, shows the
/// path and finds in its own pane, the active pane's on a raised field. A click anywhere on one
/// makes its pane the active one, so Back always goes back where you're looking.
final class PathBarView: NSView, NSTextFieldDelegate {
    static let height: CGFloat = 36

    /// Which pane the bar is for: the tab's first (the whole tab, when it isn't split) or its second.
    enum Side { case first, second }

    private let workspace: Workspace
    private let side: Side
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

    // Find.
    private let findField = FindField()
    private let scopeButton: QuietButton
    private let clearButton: BarButton
    private let findFill = NSColor(Theme.track)
    private var finding = false
    private var lastFindFocus: [ObjectIdentifier: Int] = [:]

    // Split.
    private let close: BarButton
    private var isSplit = false
    private var isActive = true
    private let activeFill = NSColor(Theme.raised)

    init(workspace: Workspace, values: RegionValues, side: Side = .first) {
        self.workspace = workspace
        self.values = values
        self.side = side
        back = BarButton("chevron.left", style: .ghost, size: 11, weight: .semibold, help: "Back (⌘[)", theme: theme)
        forward = BarButton("chevron.right", style: .ghost, size: 11, weight: .semibold, help: "Forward (⌘])", theme: theme)
        scopeButton = QuietButton("", help: "Where Find searches", theme: theme)
        clearButton = BarButton("xmark", style: .ghost, size: 9, weight: .bold, help: "Clear (esc)", theme: theme)
        close = BarButton("xmark", style: .ghost, size: 9, weight: .bold, help: "Close Pane", theme: theme)
        super.init(frame: .zero)
        back.action = { [weak self] in self?.pane?.goBack() }
        forward.action = { [weak self] in self?.pane?.goForward() }
        clearButton.action = { [weak self] in self?.endFind() }
        close.action = { [weak self] in
            guard let self, let pane = self.pane else { return }
            self.workspace.close(pane: pane)
        }
        findField.delegate = self
        findField.isBordered = false
        findField.isBezeled = false
        findField.drawsBackground = false
        findField.focusRingType = .none
        findField.font = NSFont.systemFont(ofSize: 12.5)
        findField.textColor = theme.text
        findField.cell?.isScrollable = true
        findField.cell?.wraps = false
        for view in [back, forward, crumbs, findField, scopeButton, clearButton, close] as [NSView] { addSubview(view) }
        // Any click on the bar (back, a crumb, Find) makes its pane the active one. The
        // recogniser sees clicks on the bar's parts without taking them.
        let click = NSClickGestureRecognizer(target: self, action: #selector(activatePane))
        click.delaysPrimaryMouseButtonEvents = false
        addGestureRecognizer(click)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// The pane this bar is for; nil for a second bar while the tab isn't split.
    private var pane: BrowserModel? {
        switch side {
        case .first: workspace.currentTab
        case .second: workspace.secondPane(of: workspace.currentTab)
        }
    }

    @objc private func activatePane() {
        guard isSplit, !isActive, let pane else { return }
        workspace.activate(pane)
        if !finding { pane.listFocusRequest += 1 }
    }

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
        guard let model = pane else {
            crumbs.model = nil
            return
        }
        isSplit = workspace.isSplit
        isActive = !isSplit || workspace.selected === model
        // The other pane's path reads, but quieter.
        for view in [back, forward, crumbs] as [NSView] { view.alphaValue = isActive ? 1 : 0.55 }
        remoteCrumbs?.alphaValue = isActive ? 1 : 0.55
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
        applyFind(model)
        needsLayout = true
        needsDisplay = true
    }

    // MARK: Find

    private func applyFind(_ model: BrowserModel) {
        finding = model.isFinding || !model.searchText.isEmpty
        for view in [findField, scopeButton, clearButton] as [NSView] { view.isHidden = !finding }
        let editing = findField.currentEditor() != nil
        if findField.stringValue != model.searchText && !(editing && finding) { findField.stringValue = model.searchText }
        let scope = model.findScopeName
        findField.placeholderAttributedString = NSAttributedString(string: "Find in \(scope)", attributes: [
            .foregroundColor: theme.textTertiary, .font: NSFont.systemFont(ofSize: 12.5),
        ])
        // On your Mac you choose here or everywhere; Drive searches the whole account, S3 the folder.
        let choosable = model.destination == .folder
        scopeButton.title = "in " + scope
        scopeButton.popUpMenu = choosable ? { [weak self] in self?.scopeMenu() ?? NSMenu() } : nil
        // Only a choice looks like a button; Drive's and S3's scope just says where.
        scopeButton.isInteractive = choosable
        scopeButton.toolTip = switch model.destination {
        case .folder: "Search this folder and everything in it, or everywhere on your Mac"
        case .drive: "Google Drive's search covers your whole account: names, and the text inside documents"
        case .s3: model.s3.location?.bucket == nil ? "Searches every file in every bucket" : "Searches every file in this folder and below"
        default: "Searches everywhere on your Mac"
        }
        scopeButton.isOn = false
        let key = ObjectIdentifier(model)
        let request = model.findFocusRequest
        if lastFindFocus[key] != request {
            let first = lastFindFocus[key] == nil
            lastFindFocus[key] = request
            // A pane seen for the first time only notes where its requests are.
            if !first {
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.findField.isHidden else { return }
                    self.window?.makeFirstResponder(self.findField)
                    self.findField.currentEditor()?.selectedRange = NSRange(location: (self.findField.stringValue as NSString).length, length: 0)
                }
            }
        }
    }

    private func scopeMenu() -> NSMenu {
        guard let model = pane else { return NSMenu() }
        let menu = NSMenu()
        let here = ActionMenuItem("In \(Format.displayName(model.currentURL.path))") { model.searchScope = .folder }
        here.state = model.searchScope == .folder ? .on : .off
        let everywhere = ActionMenuItem("Everywhere on Your Mac") { model.searchScope = .mac }
        everywhere.state = model.searchScope == .mac ? .on : .off
        menu.addItem(here)
        menu.addItem(everywhere)
        return menu
    }

    private func endFind() {
        guard let model = pane else { return }
        model.endFind()
        model.listFocusRequest += 1
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let model = pane else { return }
        if model.searchText != findField.stringValue { model.searchText = findField.stringValue }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard let model = pane else { return false }
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            endFind()
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.command) == true, model.destination == .folder {
                model.searchScope = .mac
            } else {
                model.listFocusRequest += 1
            }
        case #selector(NSResponder.moveDown(_:)):
            model.listFocusRequest += 1
        default:
            return false
        }
        return true
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
            view.alphaValue = isActive ? 1 : 0.55
            addSubview(view, positioned: .below, relativeTo: close)
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
    /// Whether there's room for the branch beside the path.
    private var showsGit = true
    /// Where the row's content ends: before the close button in a split tab.
    private var contentEnd: CGFloat { bounds.width - (isSplit && !finding ? 34 : 0) }

    override func layout() {
        super.layout()
        back.frame = NSRect(x: 12, y: (bounds.height - 24) / 2, width: 24, height: 24)
        forward.frame = NSRect(x: 12 + 26, y: (bounds.height - 24) / 2, width: 24, height: 24)
        close.frame = NSRect(x: bounds.width - 12 - 20, y: (bounds.height - 20) / 2, width: 20, height: 20)
        // While finding, the field's own × is the one to press (esc too); the pane's would sit
        // right beside it.
        close.isHidden = !isSplit || finding
        var gitWidth = gitText.map { text in
            ceil(TextLines.shared.line(text, font: gitFont, color: theme.textSecondary).width)
                + (gitChanges.map { ceil(TextLines.shared.line(" · " + $0, font: gitFont, color: warning).width) } ?? 0) + 16
        } ?? 0
        // The branch goes before the path does: in a narrow pane the path needs the room.
        showsGit = gitWidth > 0 && contentEnd - navEnd - gitWidth >= 200
        if !showsGit { gitWidth = 0 }
        let frame = NSRect(x: navEnd - 6, y: (bounds.height - Theme.smallControlHeight) / 2,
                           width: max(0, contentEnd - navEnd + 6 - 16 - gitWidth), height: Theme.smallControlHeight)
        crumbs.isHidden = destination != .folder || finding
        remoteCrumbs?.isHidden = finding
        crumbs.frame = frame
        remoteCrumbs?.frame = frame
        guard finding else { return }
        let box = findBox
        clearButton.frame = NSRect(x: box.maxX - 24, y: box.midY - 10, width: 20, height: 20)
        let scopeWidth = min(scopeButton.width, max(0, box.width * 0.45))
        scopeButton.frame = NSRect(x: clearButton.frame.minX - 2 - scopeWidth, y: box.midY - 11, width: scopeWidth, height: 22)
        findField.frame = NSRect(x: box.minX + 28, y: box.midY - 8, width: max(0, scopeButton.frame.minX - 6 - box.minX - 28), height: 17)
    }

    /// The field's rounded box, across the row after back and forward.
    private var findBox: NSRect {
        NSRect(x: navEnd - 2, y: (bounds.height - 28) / 2, width: max(0, contentEnd - navEnd + 2 - (isSplit ? 4 : 12)), height: 28)
    }

    override func draw(_ dirtyRect: NSRect) {
        theme.border.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        let midY = bounds.midY
        // In a split tab, the active pane's row sits on a raised field, back button to close.
        if isSplit && isActive {
            activeFill.setFill()
            let field = NSRect(x: 6, y: (bounds.height - 28) / 2, width: max(0, bounds.width - 12), height: 28)
            NSBezierPath(roundedRect: field, xRadius: Theme.controlRadius + 1, yRadius: Theme.controlRadius + 1).fill()
        }
        if finding {
            let box = findBox
            findFill.setFill()
            NSBezierPath(roundedRect: box, xRadius: Theme.controlRadius + 1, yRadius: Theme.controlRadius + 1).fill()
            let icon = theme.symbol("magnifyingglass", size: 11.5, weight: .medium, color: theme.textSecondary)
            icon.draw(in: FileCellView.centered(icon.size, in: NSRect(x: box.minX + 8, y: box.minY, width: 16, height: box.height)))
            return
        }
        // A place that isn't a folder ("Recents") shows its name.
        if destination != .folder && !destination.isRemote {
            FileCellView.drawText(placeTitle, font: titleFont, color: isActive ? theme.text : theme.textTertiary,
                                  x: navEnd, midY: midY, width: contentEnd - navEnd - 16)
        }
        // The repository's branch, and how many files changed.
        guard showsGit, let text = gitText else { return }
        let changes = gitChanges.map { " · " + $0 }
        let changesWidth = changes.map { ceil(TextLines.shared.line($0, font: gitFont, color: warning).width) } ?? 0
        let textWidth = ceil(TextLines.shared.line(text, font: gitFont, color: theme.textSecondary).width)
        let x = contentEnd - 16 - changesWidth - textWidth
        FileCellView.drawText(text, font: gitFont, color: isActive ? theme.textSecondary : theme.textTertiary, x: x, midY: midY, width: textWidth + 2)
        if let changes {
            FileCellView.drawText(changes, font: gitFont, color: isActive ? warning : warning.withAlphaComponent(0.6),
                                  x: x + textWidth, midY: midY, width: changesWidth + 2)
        }
    }

    /// The empty part of the row opens Find; while finding, a click anywhere in the box types there.
    override func mouseDown(with event: NSEvent) {
        guard let pane else { return }
        if finding {
            workspace.activate(pane)
            window?.makeFirstResponder(findField)
        } else {
            workspace.activate(pane)
            pane.openFind()
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .iBeam)
    }
}

/// The find field in the path row.
final class FindField: NSTextField {}

/// The view controls at the right of the tab bar, as three kinds of control so each reads as
/// what it is: the sort, a menu (with a chevron, the other view options inside); list or
/// gallery, one choice on a shared track; and the details panel, a switch set apart by a rule.
final class ViewControlsView: NSView {
    private let workspace: Workspace
    private let theme = TableTheme()
    private let options: QuietButton
    private let layoutChoice: BarSegmented
    private let rule = NSView()
    private let details: QuietButton
    private var generation = 0

    init(workspace: Workspace) {
        self.workspace = workspace
        options = QuietButton("Options", help: "Sort and view options", theme: theme)
        layoutChoice = BarSegmented(["List", "Gallery"], theme: theme)
        details = QuietButton("Details", help: "Details (⌘I)", theme: theme)
        super.init(frame: .zero)
        options.popUpMenu = { [weak self] in self?.optionsMenu() ?? NSMenu() }
        layoutChoice.toolTip = "As List (⌥⌘1) or Gallery (⌥⌘2)"
        layoutChoice.onSelect = { [weak workspace] index in workspace?.selected.layout = index == 0 ? .list : .gallery }
        rule.wantsLayer = true
        rule.layer?.backgroundColor = NSColor(Theme.colors.borderHover).cgColor
        details.action = { Prefs.shared.showInspector.toggle() }
        for view in [options, layoutChoice, rule, details] { addSubview(view) }
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
        layoutChoice.isHidden = !hasLayout
        layoutChoice.selected = model.layout == .gallery ? 1 : 0
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

    /// Gaps: a wide one, with the rule in it, before Details; a smaller one between the others.
    private static let ruleGap: CGFloat = 17
    private static let gap: CGFloat = 8

    var width: CGFloat {
        10 + options.width + Self.gap + (layoutChoice.isHidden ? 0 : layoutChoice.width + Self.ruleGap) + details.width + 2
    }

    override func layout() {
        super.layout()
        let height: CGFloat = 26
        let y = (bounds.height - height) / 2
        var x = bounds.width - 10 - details.width
        details.frame = NSRect(x: x, y: y, width: details.width, height: height)
        if !layoutChoice.isHidden {
            rule.isHidden = false
            rule.frame = NSRect(x: x - (Self.ruleGap + 1) / 2, y: bounds.midY - 7, width: 1, height: 14)
            x -= Self.ruleGap + layoutChoice.width
            layoutChoice.frame = NSRect(x: x, y: y, width: layoutChoice.width, height: height)
        } else {
            rule.isHidden = true
        }
        x -= Self.gap + options.width
        options.frame = NSRect(x: x, y: y, width: options.width, height: height)
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
