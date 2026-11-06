import AppKit
import Observation
import SwiftUI

/// The command bar, drawn by AppKit: back, forward and up; the field that shows the path and
/// takes searches and typed paths (⌘K); the kind filter; list or gallery; view options; and
/// the sidebar and inspector switches.
///
/// In SwiftUI, opening the field took ~30ms (SwiftUI's focus handling), and every move or tab
/// switch spent a few milliseconds laying the bar out again.
///
/// The view reaches down over the content, far enough for the field's dropdown; below the bar
/// it lets clicks through unless the dropdown is there.
final class CommandBarView: NSView {
    static let height: CGFloat = 46
    static let reach: CGFloat = 460

    private let workspace: Workspace
    private let theme = TableTheme()
    private let surface = NSColor(Theme.surface)

    private let back: BarButton
    private let forward: BarButton
    private let up: BarButton
    private let omnibox: OmniboxView
    private let kind: BarSegmented
    private let slider = NSSlider()
    private let listButton: BarButton
    private let galleryButton: BarButton
    private let options: BarButton
    private let sidebarToggle: BarButton
    private let inspectorToggle: BarButton

    private var showsKind = false
    private var showsLayout = false
    private var showsSlider = false
    private var generation = 0

    init(workspace: Workspace, values: RegionValues) {
        self.workspace = workspace
        back = BarButton("chevron.left", help: "Back (⌘[)", theme: theme)
        forward = BarButton("chevron.right", help: "Forward (⌘])", theme: theme)
        up = BarButton("arrow.up", help: "Enclosing folder (⌘↑)", theme: theme)
        omnibox = OmniboxView(workspace: workspace, values: values, theme: theme)
        kind = BarSegmented(["All", "Dirs", "Files"], theme: theme)
        listButton = BarButton("list.bullet", help: "As List (⌥⌘1)", theme: theme)
        galleryButton = BarButton("square.grid.2x2", help: "As Gallery (⌥⌘2)", theme: theme)
        options = BarButton("ellipsis", help: "View options", theme: theme)
        sidebarToggle = BarButton("sidebar.left", help: "Sidebar (⌥⌘S)", theme: theme)
        inspectorToggle = BarButton("sidebar.right", help: "Inspector (⌘I)", theme: theme)
        super.init(frame: .zero)

        back.action = { [weak workspace] in workspace?.selected.goBack() }
        forward.action = { [weak workspace] in workspace?.selected.goForward() }
        up.action = { [weak workspace] in workspace?.selected.goUp() }
        kind.onSelect = { [weak workspace] index in
            workspace?.selected.kindFilter = [KindFilter.all, .folders, .files][index]
        }
        slider.controlSize = .mini
        slider.minValue = Prefs.galleryTileSizes.lowerBound
        slider.maxValue = Prefs.galleryTileSizes.upperBound
        slider.target = self
        slider.action = #selector(tileSizeChanged)
        slider.toolTip = "Tile size (⌘+ and ⌘−, or pinch)"
        listButton.action = { [weak workspace] in workspace?.selected.layout = .list }
        galleryButton.action = { [weak workspace] in workspace?.selected.layout = .gallery }
        options.popUpMenu = { [weak self] in self?.optionsMenu() ?? NSMenu() }
        sidebarToggle.action = { Prefs.shared.showSidebar.toggle() }
        inspectorToggle.action = { Prefs.shared.showInspector.toggle() }
        for view in [back, forward, up, omnibox, kind, slider, listButton, galleryButton, options, sidebarToggle, inspectorToggle] as [NSView] {
            addSubview(view)
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    @objc private func tileSizeChanged() {
        Prefs.shared.galleryTileSize = slider.doubleValue.rounded()
    }

    private func optionsMenu() -> NSMenu {
        let model = workspace.selected
        let menu = NSMenu()
        menu.autoenablesItems = false
        let foldersFirst = ActionMenuItem("Folders First") { model.foldersFirst.toggle() }
        foldersFirst.state = model.foldersFirst ? .on : .off
        let hidden = ActionMenuItem("Show Hidden Files") { model.showHidden.toggle() }
        hidden.state = model.showHidden ? .on : .off
        menu.addItem(foldersFirst)
        menu.addItem(hidden)
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

    // MARK: Following the active pane

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
        let prefs = Prefs.shared
        back.isEnabled = !model.backStack.isEmpty
        forward.isEnabled = !model.forwardStack.isEmpty
        up.isEnabled = model.canGoUp
        let showsKind = model.destination == .folder && !model.isSearching
        let showsLayout = model.layoutPlace != nil
        let gallery = showsLayout && model.layout == .gallery
        kind.selected = [KindFilter.all, .folders, .files].firstIndex(of: model.kindFilter) ?? 0
        listButton.isOn = showsLayout && !gallery
        galleryButton.isOn = gallery
        if slider.doubleValue != prefs.galleryTileSize { slider.doubleValue = prefs.galleryTileSize }
        sidebarToggle.isOn = prefs.showSidebar
        inspectorToggle.isOn = prefs.showInspector
        if showsKind != self.showsKind || showsLayout != self.showsLayout || gallery != showsSlider {
            self.showsKind = showsKind
            self.showsLayout = showsLayout
            showsSlider = gallery
            needsLayout = true
        }
        omnibox.update(model: model)
    }

    // MARK: Layout and drawing

    override func layout() {
        super.layout()
        let size = Theme.controlHeight
        let midY = Self.height / 2
        func place(_ view: NSView, x: CGFloat, width: CGFloat, height: CGFloat = Theme.controlHeight) {
            view.frame = NSRect(x: x, y: (midY - height / 2).rounded(), width: width, height: height)
        }
        var x: CGFloat = 12
        for button in [back, forward, up] {
            place(button, x: x, width: size)
            x += size + 2
        }
        x += 6
        let left = x
        // From the right: the switches, the options, the layout picker and the kind filter.
        var right = bounds.width - 12
        for button in [inspectorToggle, sidebarToggle] {
            right -= size
            place(button, x: right, width: size)
            right -= 2
        }
        right -= 6
        right -= size
        place(options, x: right, width: size)
        right -= 8
        listButton.isHidden = !showsLayout
        galleryButton.isHidden = !showsLayout
        slider.isHidden = !showsSlider
        if showsLayout {
            right -= size
            place(galleryButton, x: right, width: size)
            right -= 2 + size
            place(listButton, x: right, width: size)
            if showsSlider {
                right -= 6 + 80
                place(slider, x: right, width: 80, height: 16)
            }
            right -= 8
        }
        kind.isHidden = !showsKind
        if showsKind {
            right -= kind.width
            place(kind, x: right, width: kind.width, height: BarSegmented.height)
            right -= 8
        }
        place(omnibox, x: left, width: max(0, right - left), height: 30)
    }

    override func draw(_ dirtyRect: NSRect) {
        surface.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: Self.height).fill()
        theme.border.setFill()
        NSRect(x: 0, y: Self.height - 1, width: bounds.width, height: 1).fill()
    }

    /// Below the bar, only the dropdown takes clicks; everything else goes to what's underneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return super.hitTest(point) }
        let local = convert(point, from: superview)
        if local.y > Self.height, !omnibox.dropdownContains(convert(local, to: omnibox)) { return nil }
        return super.hitTest(point)
    }
}

// MARK: - The field

/// One field for both: shows the path as clickable chips; click (or ⌘K/⌘F) to search, or type
/// a path starting with / or ~ to jump there, with folder completion.
final class OmniboxView: NSView, NSTextFieldDelegate {
    private let workspace: Workspace
    private let values: RegionValues
    private let theme: TableTheme
    private let fieldColor = NSColor(Theme.field)
    private let fieldBorder = NSColor(Theme.fieldBorder)
    private let borderHover = NSColor(Theme.borderHover)
    private let danger = NSColor(Theme.danger)
    private let warning = NSColor(Theme.warning)
    private let raised = NSColor(Theme.raised)
    private let hintFont = NSFont.systemFont(ofSize: 11)
    private let keyFont = NSFont.systemFont(ofSize: 10, weight: .medium)
    private let chipFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    private let gitFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    private let field = OmniboxField()
    private let crumbs = PathCrumbsView()
    private let clear: BarButton
    private let scope: BarSegmented
    /// S3 and Drive paths, which stay SwiftUI.
    private var remoteCrumbs: RegionHostingView?
    private let dropdown: SuggestionListView

    private weak var model: BrowserModel?
    private var destination = Destination.folder
    private var placeTitle = ""
    private var git: GitSnapshot?
    private var lastRequest: UUID?

    private var query = ""
    private var editing = false
    private var focused = false
    private var invalid = false
    private var hovering = false
    private var highlighted: Int?
    private var suggestions: [URL] = []
    private var recents: [URL] = []
    private var suggestionTask: Task<Void, Never>?
    private var clickMonitor: Any?
    private var tracking: NSTrackingArea?

    init(workspace: Workspace, values: RegionValues, theme: TableTheme) {
        self.workspace = workspace
        self.values = values
        self.theme = theme
        clear = BarButton("xmark.circle.fill", style: .ghost, size: 12, weight: .regular, help: "Clear (esc)", theme: theme)
        scope = BarSegmented(["Here", "Everywhere"], theme: theme)
        dropdown = SuggestionListView(theme: theme)
        super.init(frame: .zero)
        field.delegate = self
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.textColor = theme.text
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.placeholderAttributedString = NSAttributedString(string: "Search, or type a path like ~/Dev", attributes: [
            .foregroundColor: theme.textTertiary, .font: NSFont.systemFont(ofSize: 12.5),
        ])
        field.onFocus = { [weak self] in self?.fieldFocused() }
        clear.action = { [weak self] in self?.cancel() }
        clear.cutout = fieldColor
        scope.onSelect = { [weak self] index in self?.model?.searchScope = index == 0 ? .folder : .mac }
        dropdown.onPick = { [weak self] url in self?.go(to: url) }
        dropdown.isHidden = true
        for view in [crumbs, field, clear, scope, dropdown] as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private var isPathMode: Bool { query.hasPrefix("/") || query.hasPrefix("~") }
    private var showsField: Bool { editing || focused || !query.isEmpty }
    /// What the dropdown lists: path completions, or your recent folders before you type.
    private var listed: [URL] { isPathMode ? suggestions : query.isEmpty ? recents : [] }

    func dropdownContains(_ point: NSPoint) -> Bool { !dropdown.isHidden && dropdown.frame.contains(point) }

    // MARK: Following the pane

    /// Called whenever something the field shows changes (under Observation, see CommandBarView).
    func update(model: BrowserModel) {
        if self.model !== model {
            // Another tab or pane: its own search, and nothing being edited.
            self.model = model
            query = model.searchText
            field.stringValue = query
            editing = false
            if focused { window?.makeFirstResponder(nil) }
            focused = false
            lastRequest = model.omniboxRequest?.id
        }
        destination = model.destination
        placeTitle = model.title
        git = model.destination == .folder ? model.git?.snapshot : nil
        crumbs.model = model
        crumbs.openTab = values.openTab
        let trail = Self.trail(of: model)
        if crumbs.trail != trail { crumbs.trail = trail }
        scope.selected = model.searchScope == .folder ? 0 : 1
        updateRemoteCrumbs(model)
        // Kept in step when a search is started or ended from elsewhere.
        if !focused {
            if model.searchText.isEmpty {
                if !isPathMode { setQuery("") }
            } else if query != model.searchText {
                setQuery(model.searchText)
            }
        }
        if let request = model.omniboxRequest, request.id != lastRequest {
            lastRequest = request.id
            DispatchQueue.main.async { [weak self] in self?.begin(request.text) }
        }
        relayout()
    }

    /// The folders from the home folder (or /) down to this one.
    private static func trail(of model: BrowserModel) -> [URL] {
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
            return
        }
        let content = model.destination == .s3 ? AnyView(S3Breadcrumbs(model: model)) : AnyView(DriveBreadcrumbs(model: model))
        let root = AnyView(content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading).modifier(RegionStyle(values: values)))
        if let remoteCrumbs {
            remoteCrumbs.rootView = root
        } else {
            let view = RegionHostingView(rootView: root)
            addSubview(view, positioned: .below, relativeTo: field)
            remoteCrumbs = view
        }
    }

    // MARK: Editing

    private func setQuery(_ text: String) {
        guard text != query else { return }
        query = text
        if field.stringValue != text { field.stringValue = text }
        queryChanged()
    }

    private func queryChanged() {
        invalid = false
        highlighted = nil
        model?.searchText = isPathMode ? "" : query
        suggest()
        relayout()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard field.stringValue != query else { return }
        query = field.stringValue
        queryChanged()
    }

    private func fieldFocused() {
        focused = true
        watchClicks(true)
        relayout()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        focused = false
        editing = false
        watchClicks(false)
        // An unfinished path is a draft; drop it when you leave the field.
        if isPathMode { setQuery("") }
        relayout()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): return moveHighlight(1)
        case #selector(NSResponder.moveUp(_:)): return moveHighlight(-1)
        case #selector(NSResponder.insertTab(_:)): return complete()
        case #selector(NSResponder.cancelOperation(_:)):
            cancel()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            submit()
            return true
        default: return false
        }
    }

    /// Opens the field, with `text` in it.
    func begin(_ text: String) {
        guard let window else { return }
        let model = model
        recents = FolderVisits.shared.top(8, excluding: model?.destination == .folder ? [model?.currentURL.path ?? ""] : [])
        editing = true
        relayout()
        query = text
        field.stringValue = text
        queryChanged()
        window.makeFirstResponder(field)
        if let editor = field.currentEditor() {
            editor.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        }
        // If focus didn't take (the window isn't key), don't leave an empty field behind.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, !self.focused, self.query.isEmpty, self.editing else { return }
            self.editing = false
            self.relayout()
        }
    }

    private func resign() {
        if focused, let window { window.makeFirstResponder(nil) }
        focused = false
        editing = false
        relayout()
    }

    private func cancel() {
        setQuery("")
        model?.searchText = ""
        resign()
        focusList()
    }

    private func submit() {
        let listed = listed
        if let highlighted, listed.indices.contains(highlighted) {
            go(to: listed[highlighted])
        } else if isPathMode {
            if model?.goTo(path: query) == true {
                finish()
            } else {
                invalid = true
                needsDisplay = true
            }
        } else if !query.isEmpty {
            // Search stays on; jump into the results.
            resign()
            focusList()
        }
    }

    private func go(to url: URL) {
        model?.navigate(to: url)
        finish()
    }

    private func finish() {
        setQuery("")
        resign()
        focusList()
    }

    /// Hands keyboard focus to the list once the field has let go of it.
    private func focusList() {
        let model = model
        DispatchQueue.main.async { model?.listFocusRequest += 1 }
    }

    private func moveHighlight(_ delta: Int) -> Bool {
        let listed = listed
        guard focused, !listed.isEmpty else { return false }
        let next = (highlighted ?? (delta > 0 ? -1 : listed.count)) + delta
        highlighted = min(max(0, next), listed.count - 1)
        updateDropdown()
        return true
    }

    /// Tab fills in the highlighted (or first) folder suggestion.
    private func complete() -> Bool {
        let listed = listed
        guard let target = highlighted.map({ listed[$0] }) ?? listed.first else { return false }
        setQuery(Format.path(target.path) + "/")
        if let editor = field.currentEditor() {
            editor.selectedRange = NSRange(location: (query as NSString).length, length: 0)
        }
        return true
    }

    /// Folder completions for a typed path, listed off the main thread.
    private func suggest() {
        suggestionTask?.cancel()
        guard isPathMode else {
            if !suggestions.isEmpty {
                suggestions = []
                updateDropdown()
            }
            return
        }
        let query = query
        let visits = FolderVisits.shared
        let scores = visits.visits.keys.reduce(into: [String: Double]()) { $0[$1] = visits.score($1) }
        suggestionTask = Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) { Self.suggestions(for: query, scores: scores) }.value
            guard let self, !Task.isCancelled, self.query == query else { return }
            self.suggestions = found
            self.updateDropdown()
        }
    }

    /// While the field has focus, a click anywhere outside the field and its dropdown ends
    /// editing, as in Spotlight or Raycast. The click still goes through to whatever was there.
    private func watchClicks(_ on: Bool) {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        guard on else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self, let window = self.window else { return event }
            let point = self.convert(event.locationInWindow, from: nil)
            let inside = event.window === window && (self.bounds.contains(point) || self.dropdownContains(point))
            if !inside { DispatchQueue.main.async { [weak self] in self?.resign() } }
            return event
        }
    }

    /// Folders matching what's typed: the contents of a folder ending in "/", otherwise siblings
    /// whose names start with the last component. The ones you visit most come first.
    nonisolated private static func suggestions(for query: String, scores: [String: Double]) -> [URL] {
        let expanded = (query as NSString).expandingTildeInPath
        let endsWithSlash = query.hasSuffix("/")
        let parent = endsWithSlash ? expanded : (expanded as NSString).deletingLastPathComponent
        let prefix = endsWithSlash ? "" : (expanded as NSString).lastPathComponent.lowercased()
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: parent.isEmpty ? "/" : parent), includingPropertiesForKeys: keys) else { return [] }
        return children
            .filter { url in
                let name = url.lastPathComponent
                guard (prefix.hasPrefix(".") || !name.hasPrefix(".")) && (prefix.isEmpty || name.lowercased().hasPrefix(prefix)) else { return false }
                let values = try? url.resourceValues(forKeys: Set(keys))
                return values?.isDirectory == true && values?.isPackage != true
            }
            .sorted { lhs, rhs in
                let left = scores[lhs.standardizedFileURL.path] ?? 0
                let right = scores[rhs.standardizedFileURL.path] ?? 0
                if left != right { return left > right }
                return lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
            }
            .prefix(8)
            .map { $0 }
    }

    // MARK: Layout and drawing

    private var placeholder: String {
        switch destination {
        case .s3: "filter this folder"
        case .drive: "search Drive"
        default: "search or go to path"
        }
    }

    private var hintWidth: CGFloat {
        ceil(TextLines.shared.line(placeholder, font: hintFont, color: theme.textTertiary).width) + 6
            + ceil(TextLines.shared.line("⌘K", font: keyFont, color: theme.textTertiary).width) + 8
    }

    private var gitText: String? {
        guard let git else { return nil }
        let name = git.branch ?? git.commit ?? "detached"
        var text = name.count > 30 ? name.prefix(14) + "…" + name.suffix(14) : name
        if git.ahead > 0 { text += " ↑\(git.ahead)" }
        if git.behind > 0 { text += " ↓\(git.behind)" }
        return text
    }

    private var gitChangesText: String? {
        guard let git, git.changeCount > 0 else { return nil }
        return " · \(git.changeCount)"
    }

    private var gitWidth: CGFloat {
        guard let text = gitText else { return 0 }
        let changes = gitChangesText.map { TextLines.shared.line($0, font: gitFont, color: warning).width } ?? 0
        return 7 + 11 + 5 + ceil(TextLines.shared.line(text, font: gitFont, color: theme.textSecondary).width + changes) + 7
    }

    private var gitFrame: NSRect {
        let width = gitWidth
        let x = bounds.width - 6 - hintWidth - 8 - width
        return NSRect(x: x, y: bounds.midY - 9, width: width, height: 18)
    }

    private func relayout() {
        needsLayout = true
        needsDisplay = true
        updateDropdown()
    }

    override func layout() {
        super.layout()
        let shows = showsField
        field.isHidden = !shows
        crumbs.isHidden = shows || destination != .folder
        remoteCrumbs?.isHidden = shows
        clear.isHidden = !shows || query.isEmpty
        scope.isHidden = !shows || isPathMode || query.isEmpty || destination.isRemote
        let height = bounds.height
        if shows {
            var right = bounds.width - 6
            if !clear.isHidden {
                right -= 16
                clear.frame = NSRect(x: right, y: (height - 16) / 2, width: 16, height: 16)
                right -= 6
            }
            if !scope.isHidden {
                right -= scope.width
                scope.frame = NSRect(x: right, y: (height - BarSegmented.height) / 2, width: scope.width, height: BarSegmented.height)
                right -= 6
            }
            let x: CGFloat = 6 + 14 + 6
            field.font = isPathMode ? NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular) : NSFont.systemFont(ofSize: 12.5)
            field.frame = NSRect(x: x, y: (height - 18) / 2, width: max(0, right - x), height: 18)
        } else {
            let end = (git == nil ? bounds.width - 6 - hintWidth : gitFrame.minX) - 8
            let frame = NSRect(x: 6, y: (height - Theme.smallControlHeight) / 2, width: max(0, end - 6), height: Theme.smallControlHeight)
            crumbs.frame = frame
            remoteCrumbs?.frame = frame
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds
        let radius = Theme.fieldRadius
        fieldColor.setFill()
        NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius).fill()
        let border = invalid ? danger : (focused ? theme.accent.withAlphaComponent(0.7) : (hovering ? borderHover : fieldBorder))
        border.setStroke()
        let ring = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: radius - 0.5, yRadius: radius - 0.5)
        ring.lineWidth = 1
        ring.stroke()
        let midY = box.midY
        if showsField {
            let image = theme.symbol(isPathMode ? "arrow.turn.down.right" : "magnifyingglass", size: 11, weight: .semibold,
                                     color: isPathMode ? theme.accent : theme.textSecondary)
            image.draw(in: NSRect(x: 6 + 7 - image.size.width / 2, y: midY - image.size.height / 2, width: image.size.width, height: image.size.height))
            return
        }
        // A place that isn't a folder ("Recents") shows its name as a chip.
        if destination != .folder && !destination.isRemote {
            let width = ceil(TextLines.shared.line(placeTitle, font: chipFont, color: theme.text).width) + 12
            let chip = NSRect(x: 6, y: midY - Theme.smallControlHeight / 2, width: width, height: Theme.smallControlHeight)
            raised.setFill()
            NSBezierPath(roundedRect: chip, xRadius: Theme.chipRadius, yRadius: Theme.chipRadius).fill()
            FileCellView.drawText(placeTitle, font: chipFont, color: theme.text, x: chip.minX, midY: chip.midY, width: chip.width, alignment: .center)
        }
        // The repository's branch: "⎇ dev ↑2 · 8".
        if let text = gitText {
            let chip = gitFrame
            raised.setFill()
            NSBezierPath(roundedRect: chip, xRadius: chip.height / 2, yRadius: chip.height / 2).fill()
            let icon = theme.symbol("arrow.triangle.branch", size: 9.5, weight: .semibold, color: theme.textSecondary)
            icon.draw(in: NSRect(x: chip.minX + 7, y: chip.midY - icon.size.height / 2, width: icon.size.width, height: icon.size.height))
            let x = chip.minX + 7 + 11 + 5
            let width = FileCellView.drawText(text, font: gitFont, color: theme.textSecondary, x: x, midY: chip.midY, width: chip.maxX - x)
            if let changes = gitChangesText {
                FileCellView.drawText(changes, font: gitFont, color: warning, x: x + width, midY: chip.midY, width: chip.maxX - x - width)
            }
        }
        // "search or go to path ⌘K".
        let keyWidth = ceil(TextLines.shared.line("⌘K", font: keyFont, color: theme.textTertiary).width) + 8
        let keyBox = NSRect(x: box.maxX - 6 - keyWidth, y: midY - 7, width: keyWidth, height: 14)
        let hint = keyBox.minX - 6 - ceil(TextLines.shared.line(placeholder, font: hintFont, color: theme.textTertiary).width)
        FileCellView.drawText(placeholder, font: hintFont, color: theme.textTertiary, x: hint, midY: midY, width: keyBox.minX - hint)
        let keyRing = NSBezierPath(roundedRect: keyBox.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        fieldBorder.setStroke()
        keyRing.stroke()
        FileCellView.drawText("⌘K", font: keyFont, color: theme.textTertiary, x: keyBox.minX, midY: keyBox.midY, width: keyBox.width, alignment: .center)
    }

    private func updateDropdown() {
        let listed = listed
        var isKey = window?.isKeyWindow ?? false
        #if DEBUG
        // Scripted runs and README screenshots happen with the app in the background.
        if DemoMode.isOn || DebugSnapshots.isRunning { isKey = true }
        #endif
        let shows = focused && !listed.isEmpty && isKey
        dropdown.isHidden = !shows
        guard shows else { return }
        dropdown.set(title: isPathMode ? nil : "Recent folders", suggestions: listed, highlighted: highlighted)
        dropdown.frame = NSRect(x: 0, y: bounds.height + 4, width: SuggestionListView.width, height: dropdown.height)
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .cursorUpdate, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
    }

    override func cursorUpdate(with event: NSEvent) {
        (showsField ? NSCursor.arrow : NSCursor.iBeam).set()
    }

    override func mouseDown(with event: NSEvent) {
        if !showsField { begin("") }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // The dropdown hangs below the field, outside its bounds.
        if dropdownContains(convert(point, from: superview)) { return dropdown }
        return super.hitTest(point)
    }
}

/// The text field in the command bar; says when it takes focus.
final class OmniboxField: NSTextField {
    var onFocus: () -> Void = {}

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocus() }
        return became
    }
}

// MARK: - The dropdown

/// Recent folders, or completions for a typed path, below the field.
final class SuggestionListView: NSView {
    static let width: CGFloat = 420
    private static let rowHeight = Theme.controlHeight

    var onPick: (URL) -> Void = { _ in }

    private let theme: TableTheme
    private let surface = NSColor(Theme.surface)
    private let fieldBorder = NSColor(Theme.fieldBorder)
    private let raised = NSColor(Theme.raised)
    private let pressedFill = NSColor(Theme.pressedFill)
    private let titleFont = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
    private let nameFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    private let pathFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    private let footerFont = NSFont.systemFont(ofSize: 10)

    private var title: String?
    private var suggestions: [URL] = []
    private var highlighted: Int?
    private var hovered: Int?
    private var tracking: NSTrackingArea?

    init(theme: TableTheme) {
        self.theme = theme
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.5
        layer?.shadowRadius = 18
        layer?.shadowOffset = CGSize(width: 0, height: -8)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var titleHeight: CGFloat { title == nil ? 0 : 2 + 14 + 4 }

    var height: CGFloat {
        6 + titleHeight + CGFloat(suggestions.count) * (Self.rowHeight + 1) + 4 + 13 + 6
    }

    func set(title: String?, suggestions: [URL], highlighted: Int?) {
        guard title != self.title || suggestions != self.suggestions || highlighted != self.highlighted else { return }
        self.title = title
        self.suggestions = suggestions
        self.highlighted = highlighted
        needsDisplay = true
        layer?.shadowPath = CGPath(roundedRect: NSRect(x: 0, y: 0, width: Self.width, height: height), cornerWidth: 10, cornerHeight: 10, transform: nil)
    }

    private func rowRect(_ index: Int) -> NSRect {
        NSRect(x: 6, y: 6 + titleHeight + CGFloat(index) * (Self.rowHeight + 1), width: bounds.width - 12, height: Self.rowHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10)
        surface.setFill()
        shape.fill()
        let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 9.5, yRadius: 9.5)
        fieldBorder.setStroke()
        ring.stroke()
        if let title {
            FileCellView.drawText(title, font: titleFont, color: theme.textTertiary, x: 16, midY: 6 + 2 + 7, width: bounds.width - 32)
        }
        for (index, url) in suggestions.enumerated() {
            let rect = rowRect(index)
            let isSelected = index == highlighted
            let isHovered = hovered == index
            let fill: NSColor? = isSelected ? (isHovered ? theme.raisedHover : raised) : (isHovered ? theme.hoverFill : nil)
            if let fill {
                fill.setFill()
                NSBezierPath(roundedRect: rect, xRadius: Theme.controlRadius, yRadius: Theme.controlRadius).fill()
            }
            let icon = theme.symbol("folder.fill", size: 10, weight: .regular, color: theme.textSecondary)
            icon.draw(in: NSRect(x: rect.minX + 8, y: rect.midY - icon.size.height / 2, width: icon.size.width, height: icon.size.height))
            let nameX = rect.minX + 8 + icon.size.width + 8
            let nameWidth = FileCellView.drawText(url.lastPathComponent, font: nameFont, color: theme.text, x: nameX, midY: rect.midY,
                                                  width: rect.width * 0.55)
            let pathX = nameX + nameWidth + 12
            FileCellView.drawText(Format.path(url.deletingLastPathComponent().path), font: pathFont, color: theme.textTertiary,
                                  x: pathX, midY: rect.midY, width: rect.maxX - 8 - pathX, alignment: .right, truncation: .byTruncatingHead)
        }
        let footerY = bounds.height - 6 - 13
        FileCellView.drawText("↑↓ choose · ⇥ complete · ↩ go", font: footerFont, color: theme.textTertiary,
                              x: 16, midY: footerY + 6.5, width: bounds.width - 32)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    private func row(at event: NSEvent) -> Int? {
        let point = convert(event.locationInWindow, from: nil)
        return suggestions.indices.first { rowRect($0).contains(point) }
    }

    override func mouseMoved(with event: NSEvent) {
        let index = row(at: event)
        guard index != hovered else { return }
        hovered = index
        needsDisplay = true
        (index != nil ? NSCursor.pointingHand : NSCursor.arrow).set()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard let index = row(at: event) else { return }
        onPick(suggestions[index])
    }
}
