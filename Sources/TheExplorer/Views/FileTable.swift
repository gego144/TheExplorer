import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - SwiftUI bridge

/// The file list, drawn by AppKit: an NSTableView whose rows each draw themselves in one pass
/// (name, type chip, size bar, date), with the table's own selection, keyboard handling,
/// type-to-select, dragging and dropping. SwiftUI only hands it the rows and callbacks.
///
/// Selection shows in the frame it's made in: the table draws the new highlight, and the rest
/// of the window (inspector, status bar) catches up a moment later rather than holding the
/// highlight back while it lays itself out.
struct FileTable<RowMenu: View, BackgroundMenu: View>: NSViewRepresentable {
    let rows: [ListRow]
    @Binding var selection: Set<URL>
    var sort: SortSpec?
    var onSort: ((SortKey) -> Void)?
    var maxSize: Int64?
    var dateTitle: String
    var dateSortKey: SortKey
    var showLocation: Bool
    var focusRequest: Int
    let onOpen: (Set<URL>, Bool) -> Void
    var onQuickLook: (Set<URL>, [ListRow]) -> Void
    var onDropInto: (([URL], URL) -> Bool)?
    var onDropBackground: (([URL]) -> Bool)?
    var onToggleExpand: ((URL) -> Void)?
    var onReachEnd: (() -> Void)?
    var footer: AnyView?
    var gitMark: ((URL) -> GitMark?)?
    /// Items cut with ⌘X, drawn faded. Read by the caller's body, so a cut redraws the list.
    var cut: Set<URL> = []
    /// Kept but not shown while the pane shows the gallery (see FileListView).
    var isHidden = false
    let rowMenu: (Set<URL>) -> RowMenu
    let backgroundMenu: () -> BackgroundMenu

    @Environment(\.isActivePane) private var isActivePane
    @Environment(\.activatePane) private var activatePane
    @Environment(\.switchPane) private var switchPane

    func makeNSView(context: Context) -> FileTableScrollView {
        let controller = FileTableController()
        context.coordinator.controller = controller
        apply(to: controller, context: context)
        return controller.scrollView
    }

    func updateNSView(_ view: FileTableScrollView, context: Context) {
        guard let controller = context.coordinator.controller else { return }
        apply(to: controller, context: context)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// The list fills whatever it's given. Answering here spares SwiftUI asking the scroll view
    /// for its fitting size (an Auto Layout pass) on every layout.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FileTableScrollView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 400, height: 300))
    }

    final class Coordinator {
        var controller: FileTableController?
    }

    private func apply(to controller: FileTableController, context: Context) {
        let environment = context.environment
        let selectionBinding = $selection
        var config = FileTableController.Config()
        config.sort = sort
        config.onSort = onSort
        config.maxSize = maxSize ?? rows.lazy.compactMap(\.size).max() ?? 0
        config.dateTitle = dateTitle
        config.dateSortKey = dateSortKey
        config.showLocation = showLocation
        config.isActivePane = isActivePane
        config.activatePane = activatePane
        config.switchPane = switchPane
        config.onOpen = onOpen
        config.onQuickLook = onQuickLook
        config.onDropInto = onDropInto
        config.onDropBackground = onDropBackground
        config.onToggleExpand = onToggleExpand
        config.onReachEnd = onReachEnd
        config.footer = footer
        config.gitMark = gitMark
        config.cut = cut
        config.setSelection = { selectionBinding.wrappedValue = $0 }
        let rowMenu = self.rowMenu
        let backgroundMenu = self.backgroundMenu
        config.rowMenu = { urls, rows in
            NSHostingMenu(rootView: rowMenu(urls).environment(\.self, environment).environment(\.listedItems, ListedItems(rows)))
        }
        config.backgroundMenu = {
            NSHostingMenu(rootView: backgroundMenu().environment(\.self, environment))
        }
        controller.setHidden(isHidden)
        controller.update(rows: rows, selection: selection, focusRequest: focusRequest, config: config)
    }
}

// MARK: - Controller

/// Owns the table and keeps it in step with what SwiftUI hands over.
@MainActor
final class FileTableController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    struct Config {
        var sort: SortSpec?
        var onSort: ((SortKey) -> Void)?
        var maxSize: Int64 = 0
        var dateTitle = "Modified"
        var dateSortKey: SortKey = .modified
        var showLocation = false
        var isActivePane = true
        var activatePane: (() -> Void)?
        var switchPane: (() -> Void)?
        var onOpen: (Set<URL>, Bool) -> Void = { _, _ in }
        var onQuickLook: (Set<URL>, [ListRow]) -> Void = { _, _ in }
        var onDropInto: (([URL], URL) -> Bool)?
        var onDropBackground: (([URL]) -> Bool)?
        var onToggleExpand: ((URL) -> Void)?
        var onReachEnd: (() -> Void)?
        var footer: AnyView?
        var gitMark: ((URL) -> GitMark?)?
        var cut: Set<URL> = []
        var setSelection: (Set<URL>) -> Void = { _ in }
        var rowMenu: (Set<URL>, [ListRow]) -> NSMenu = { _, _ in NSMenu() }
        var backgroundMenu: () -> NSMenu = { NSMenu() }
    }

    /// One line of the table: a file, a group header above the next files, or the footer.
    enum Line {
        case item(Int)
        case group(String)
        case footer
    }

    let scrollView = FileTableScrollView()
    let table = FileTableView()
    private(set) var rows: [ListRow] = []
    private(set) var lines: [Line] = []
    /// Each row's line, built the first time something asks: a new folder's thousand URLs
    /// aren't hashed unless the selection or a drop needs them.
    private var lineOfRowCache: [URL: Int]?
    private var lineOfRow: [URL: Int] {
        if let lineOfRowCache { return lineOfRowCache }
        var map: [URL: Int] = [:]
        map.reserveCapacity(rows.count)
        for (line, entry) in lines.enumerated() {
            if case .item(let index) = entry { map[rows[index].id] = line }
        }
        lineOfRowCache = map
        return map
    }
    private(set) var config = Config()
    let theme = TableTheme()

    /// The selection as the table has it.
    private var selection: Set<URL> = []
    /// A selection made in the table that SwiftUI hasn't been told about yet.
    private var pendingSelection: Set<URL>?
    private var applyingSelection = false
    private var focusRequest: Int?
    private var reachedEndAt = -1
    private var footerHost: NSHostingView<AnyView>?
    /// Changes to anything the visible rows read (folder sizes, git status) redraw them.
    private var trackingVisible = false

    override init() {
        super.init()
        table.controller = self
        table.dataSource = self
        table.delegate = self
        let column = NSTableColumn(identifier: .init("file"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.headerView = FileTableHeaderView(controller: self)
        table.cornerView = nil
        table.backgroundColor = .clear
        table.style = .plain
        table.rowHeight = FileTableLayout.rowHeight
        table.intercellSpacing = NSSize(width: 0, height: FileTableLayout.rowSpacing)
        table.selectionHighlightStyle = .regular
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.allowsTypeSelect = true
        table.floatsGroupRows = false
        table.usesAutomaticRowHeights = false
        table.gridStyleMask = []
        table.focusRingType = .none
        table.draggingDestinationFeedbackStyle = .none
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.setDraggingSourceOperationMask([.copy, .move, .link, .generic], forLocal: false)
        table.setDraggingSourceOperationMask([.move, .copy, .generic], forLocal: true)
        table.registerForDraggedTypes([.fileURL, .URL])
        table.verticalMotionCanBeginDrag = true

        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 8, right: 0)
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
        scrollView.controller = self
    }

    // MARK: Updates from SwiftUI

    #if DEBUG
    /// The list that last updated, for scripted scenes.
    /// The folder the last list put on screen was in, and when (for the navtime scene).
    static var debugReloaded: (folder: String, at: TimeInterval)?
    static weak var debugLast: FileTableController?
    #endif

    func update(rows newRows: [ListRow], selection newSelection: Set<URL>, focusRequest newFocus: Int, config newConfig: Config) {
        #if DEBUG
        Self.debugLast = self
        #endif
        let oldConfig = config
        config = newConfig
        let rowsChanged = !Self.same(rows, newRows) || (oldConfig.footer == nil) != (newConfig.footer == nil)
        if rowsChanged {
            #if DEBUG
            if let first = newRows.first { Self.debugReloaded = (first.id.deletingLastPathComponent().standardizedFileURL.path, ProcessInfo.processInfo.systemUptime) }
            #endif
            // The same list with changes (a reload) shares its first rows; a look at a few is enough.
            let shared = !rows.isEmpty && !newRows.isEmpty && newRows.prefix(32).contains { line(of: $0.id) != nil }
            Retired.later(rows)
            rows = newRows
            rebuildLines()
            table.reloadData()
            // A different list altogether (another folder) starts at the top.
            if !shared, !lines.isEmpty { table.scrollRowToVisible(0) }
            reachedEndAt = -1
        } else if oldConfig.showLocation != newConfig.showLocation || oldConfig.maxSize != newConfig.maxSize
                    || oldConfig.cut != newConfig.cut || oldConfig.sort != newConfig.sort || oldConfig.dateTitle != newConfig.dateTitle {
            redrawVisible()
        }
        if oldConfig.sort != newConfig.sort || oldConfig.dateTitle != newConfig.dateTitle || oldConfig.showLocation != newConfig.showLocation {
            table.headerView?.needsDisplay = true
        }
        // SwiftUI's selection wins, unless the table has one SwiftUI hasn't heard about yet.
        let wanted = pendingSelection ?? newSelection
        if rowsChanged || wanted != selection {
            select(wanted, scroll: !rowsChanged && wanted != selection)
        }
        if let focusRequest, focusRequest != newFocus, !scrollView.isHidden {
            table.window?.makeFirstResponder(table)
        }
        focusRequest = newFocus
        if rowsChanged { checkReachedEnd() }
        updateDebugFrames()
    }

    /// Rows are the same list when every row matches, which is cheap to check when the caller
    /// hands back the same array.
    private static func same(_ a: [ListRow], _ b: [ListRow]) -> Bool {
        guard a.count == b.count else { return false }
        let identical = a.withUnsafeBufferPointer { pa in b.withUnsafeBufferPointer { pb in pa.baseAddress == pb.baseAddress } }
        if identical { return true }
        for index in a.indices {
            let x = a[index], y = b[index]
            guard x.id == y.id, x.size == y.size, x.date == y.date, x.group == y.group, x.depth == y.depth,
                  x.expansion == y.expansion, x.location == y.location, x.liveFolderSize == y.liveFolderSize,
                  x.item == y.item else { return false }
        }
        return true
    }

    private func rebuildLines() {
        var lines: [Line] = []
        lines.reserveCapacity(rows.count + 8)
        for (index, row) in rows.enumerated() {
            if let group = row.group { lines.append(.group(group)) }
            lines.append(.item(index))
        }
        if config.footer != nil, !rows.isEmpty { lines.append(.footer) }
        self.lines = lines
        lineOfRowCache = nil
        footerHost = nil
    }

    func row(atLine line: Int) -> ListRow? {
        guard lines.indices.contains(line), case .item(let index) = lines[line] else { return nil }
        return rows[index]
    }

    func line(of url: URL) -> Int? { lineOfRow[url] }

    // MARK: Selection

    private func select(_ urls: Set<URL>, scroll: Bool) {
        let indexes = urls.isEmpty ? IndexSet() : IndexSet(urls.compactMap { lineOfRow[$0] })
        applyingSelection = true
        table.selectRowIndexes(indexes, byExtendingSelection: false)
        applyingSelection = false
        selection = Set(indexes.compactMap { row(atLine: $0)?.id })
        if scroll, let first = indexes.first, !table.rows(in: table.visibleRect).contains(first) {
            table.scrollRowToVisible(first)
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !applyingSelection else { return }
        let urls = Set(table.selectedRowIndexes.compactMap { row(atLine: $0)?.id })
        guard urls != selection else { return }
        selection = urls
        if urls.count == 1, let line = table.selectedRowIndexes.first, let row = row(atLine: line), row.item.isFolder {
            ListingCache.shared.readAhead(row.id, .pointer)
        }
        // The highlight goes on screen now: the changed rows are drawn and handed to the window
        // server before SwiftUI hears about it on the next turn of the run loop, so the
        // inspector and status bar laying themselves out never hold the highlight back. Rapid
        // changes (a held arrow key) send SwiftUI only the last.
        table.displayIfNeeded()
        CATransaction.flush()
        LatencyMeter.shared.noteFlush()
        let alreadyPending = pendingSelection != nil
        pendingSelection = urls
        guard !alreadyPending else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let urls = self.pendingSelection else { return }
            self.pendingSelection = nil
            self.config.setSelection(urls)
        }
    }

    private func isItem(_ line: Int) -> Bool {
        guard lines.indices.contains(line), case .item = lines[line] else { return false }
        return true
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { isItem(row) }

    func tableView(_ tableView: NSTableView, selectionIndexesForProposedSelection proposed: IndexSet) -> IndexSet {
        proposed.filteredIndexSet(includeInteger: isItem)
    }

    var selectedRows: [ListRow] { table.selectedRowIndexes.compactMap { row(atLine: $0) } }

    // MARK: Data source and rows

    func numberOfRows(in tableView: NSTableView) -> Int { lines.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .group = lines[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch lines[row] {
        case .item: return FileTableLayout.rowHeight
        case .group: return FileTableLayout.groupHeight
        case .footer: return max(1, footerView().fittingSize.height)
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = tableView.makeView(withIdentifier: FileRowView.identifier, owner: nil) as? FileRowView ?? FileRowView()
        view.identifier = FileRowView.identifier
        view.controller = self
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch lines[row] {
        case .item(let index):
            let cell = tableView.makeView(withIdentifier: FileCellView.identifier, owner: nil) as? FileCellView ?? FileCellView()
            cell.identifier = FileCellView.identifier
            cell.controller = self
            cell.row = rows[index]
            cell.needsDisplay = true
            trackVisibleReads()
            return cell
        case .group(let title):
            let cell = tableView.makeView(withIdentifier: GroupCellView.identifier, owner: nil) as? GroupCellView ?? GroupCellView()
            cell.identifier = GroupCellView.identifier
            cell.theme = theme
            cell.title = title
            return cell
        case .footer:
            return footerView()
        }
    }

    private func footerView() -> NSView {
        if let footerHost { return footerHost }
        let host = NSHostingView(rootView: config.footer ?? AnyView(EmptyView()))
        host.sizingOptions = [.intrinsicContentSize]
        footerHost = host
        return host
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        self.row(atLine: row)?.item.name
    }

    func tableView(_ tableView: NSTableView, toolTipFor cell: NSCell, rect: NSRectPointer, tableColumn: NSTableColumn?,
                   row: Int, mouseLocation: NSPoint) -> String {
        guard let item = self.row(atLine: row) else { return "" }
        let rowRect = tableView.rect(ofRow: row)
        let x = mouseLocation.x - rowRect.minX
        return FileTableLayout(width: rowRect.width, showLocation: config.showLocation, depth: item.depth)
            .toolTip(at: x, row: item, git: config.gitMark?(item.id))
    }

    /// Redraws the rows on screen (sizes, git marks or the cut items changed).
    func redrawVisible() {
        let range = table.rows(in: table.visibleRect)
        guard range.length > 0 else { return }
        for line in range.location..<(range.location + range.length) {
            (table.view(atColumn: 0, row: line, makeIfNecessary: false) as? FileCellView)?.needsDisplay = true
        }
        trackVisibleReads()
    }

    /// Reads what the visible rows draw (live folder sizes, git status) inside Observation
    /// tracking, so a change to any of it redraws them once.
    private func trackVisibleReads() {
        guard !trackingVisible else { return }
        trackingVisible = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            withObservationTracking {
                let range = self.table.rows(in: self.table.visibleRect)
                guard range.length > 0 else { return }
                for line in range.location..<(range.location + range.length) {
                    guard let row = self.row(atLine: line) else { continue }
                    if row.liveFolderSize && row.size == nil {
                        _ = FolderSizeStore.shared.size(for: row.item.path)
                        _ = FolderSizeStore.shared.isCalculating(row.item.path)
                    }
                    _ = self.config.gitMark?(row.id)
                }
            } onChange: {
                DispatchQueue.main.async { [weak self] in
                    self?.trackingVisible = false
                    self?.redrawVisible()
                }
            }
        }
    }

    // MARK: Actions

    @objc private func doubleClicked() {
        open(line: table.clickedRow, newTab: NSApp.currentEvent?.modifierFlags.contains(.command) ?? false)
    }

    /// Opens a double-clicked row, with the rest of the selection if it's part of it.
    func open(line: Int, newTab: Bool) {
        guard let row = row(atLine: line) else { return }
        let urls = table.selectedRowIndexes.contains(line) ? Set(selectedRows.map(\.id)) : [row.id]
        config.onOpen(urls, newTab)
    }

    func openSelection() {
        let urls = Set(selectedRows.map(\.id))
        guard !urls.isEmpty else { return }
        config.onOpen(urls, false)
    }

    func quickLook() {
        config.onQuickLook(Set(selectedRows.map(\.id)), rows)
    }

    func clearSelection() -> Bool {
        guard !table.selectedRowIndexes.isEmpty else { return false }
        table.deselectAll(nil)
        return true
    }

    /// → expands the selected folders; ← collapses them, or from inside one, selects its folder.
    func expandOrCollapse(expanding: Bool) -> Bool {
        guard let toggle = config.onToggleExpand else { return false }
        let selected = selectedRows
        guard !selected.isEmpty else { return false }
        if expanding {
            selected.filter { $0.expansion == false }.forEach { toggle($0.id) }
        } else if selected.contains(where: { $0.expansion == true }) {
            selected.filter { $0.expansion == true }.forEach { toggle($0.id) }
        } else if selected.count == 1, let row = selected.first, row.depth > 0,
                  let parent = line(of: row.id.deletingLastPathComponent()) {
            table.selectRowIndexes([parent], byExtendingSelection: false)
            table.scrollRowToVisible(parent)
        }
        return true
    }

    func toggleExpansion(of url: URL) {
        config.onToggleExpand?(url)
    }

    func menu(forLine line: Int) -> NSMenu? {
        guard let row = row(atLine: line) else { return config.backgroundMenu() }
        let urls = table.selectedRowIndexes.contains(line) ? Set(selectedRows.map(\.id)) : [row.id]
        return config.rowMenu(urls, rows)
    }

    func becameFirstResponder() {
        config.activatePane?()
        redrawSelected()
    }

    func redrawSelected() {
        for line in table.selectedRowIndexes {
            table.rowView(atRow: line, makeIfNecessary: false)?.needsDisplay = true
        }
    }

    // MARK: Scrolling and paging

    @objc private func scrolled() {
        checkReachedEnd()
        trackVisibleReads()
        updateDebugFrames()
    }

    private func checkReachedEnd() {
        guard let onReachEnd = config.onReachEnd, !rows.isEmpty, reachedEndAt != rows.count else { return }
        let visible = table.rows(in: table.visibleRect)
        guard visible.location + visible.length >= lines.count - 1 else { return }
        reachedEndAt = rows.count
        DispatchQueue.main.async { onReachEnd() }
    }

    /// Shows or hides the list, which is kept while the pane shows the gallery; shown again,
    /// it takes keyboard focus back from the gallery.
    func setHidden(_ hidden: Bool) {
        guard hidden != scrollView.isHidden else { return }
        scrollView.isHidden = hidden
        guard !hidden, let window = table.window, config.isActivePane, !(window.firstResponder is NSText) else { return }
        window.makeFirstResponder(table)
    }

    func viewMovedToWindow() {
        guard let window = table.window, !scrollView.isHidden else { return }
        // Never pull focus out of a text field you're typing in; in a split tab, only the
        // active pane's list takes it.
        if config.isActivePane && !(window.firstResponder is NSText) {
            window.makeFirstResponder(table)
        }
        DispatchQueue.main.async { [weak self] in
            self?.checkReachedEnd()
            self?.updateDebugFrames()
        }
    }

    // MARK: Dragging out

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let item = self.row(atLine: row) else { return nil }
        if let promise = RemoteFilePromise(item.id) { return promise }
        return item.id as NSURL
    }

    // MARK: Dropping in

    private(set) var dropLine: Int?
    private(set) var dropOnBackground = false

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        let point = tableView.convert(info.draggingLocation, from: nil)
        let line = tableView.row(at: point)
        var target: Int?
        if config.onDropInto != nil, let item = self.row(atLine: line), item.item.isFolder {
            // A folder can't go into itself.
            let dragged = Self.urls(from: info.draggingPasteboard)
            if !dragged.contains(item.id) { target = line }
        }
        let background = target == nil && config.onDropBackground != nil
        setDropTarget(line: target, background: background)
        guard target != nil || background else { return [] }
        if let target { tableView.setDropRow(target, dropOperation: .on) } else { tableView.setDropRow(-1, dropOperation: .on) }
        return NSEvent.modifierFlags.contains(.option) ? .copy : .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        let target = dropLine.flatMap { self.row(atLine: $0) }
        let background = dropOnBackground
        setDropTarget(line: nil, background: false)
        let urls = Self.urls(from: info.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        if let target { return config.onDropInto?(urls, target.id) ?? false }
        if background { return config.onDropBackground?(urls) ?? false }
        return false
    }

    func draggingEnded() { setDropTarget(line: nil, background: false) }

    private func setDropTarget(line: Int?, background: Bool) {
        if line != dropLine {
            for old in [dropLine, line].compactMap({ $0 }) {
                table.rowView(atRow: old, makeIfNecessary: false)?.needsDisplay = true
            }
            dropLine = line
        }
        if background != dropOnBackground {
            dropOnBackground = background
            scrollView.showsDropOutline = background
        }
    }

    /// Files, and S3 or Drive items (plain URLs), in the order they were dragged.
    static func urls(from pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) ?? []
    }

    // MARK: Debug geometry

    /// Tells scripted clicks where the visible rows are, worked out only when one asks.
    private func updateDebugFrames() {
        #if DEBUG
        RowGeometry.providers[ObjectIdentifier(self)] = { [weak self] in self?.debugFrames() ?? [] }
        #endif
    }

    #if DEBUG
    private func debugFrames() -> [(URL, CGRect, Int)] {
        guard let window = table.window, let content = window.contentView else { return [] }
        let range = table.rows(in: table.visibleRect)
        guard range.length > 0 else { return [] }
        return (range.location..<(range.location + range.length)).compactMap { line in
            guard let row = row(atLine: line) else { return nil }
            let rect = table.convert(table.rect(ofRow: line).insetBy(dx: FileTableLayout.gutter, dy: 0), to: nil)
            return (row.id, CGRect(x: rect.minX, y: content.bounds.height - rect.maxY, width: rect.width, height: rect.height), row.depth)
        }
    }
    #endif
}

// MARK: - Views

/// The scroll view the list lives in; draws the dashed outline while a drop would land in the
/// folder shown.
final class FileTableScrollView: NSScrollView {
    weak var controller: FileTableController?
    private let outline = CAShapeLayer()

    var showsDropOutline = false {
        didSet {
            guard showsDropOutline != oldValue else { return }
            wantsLayer = true
            if outline.superlayer == nil { layer?.addSublayer(outline) }
            outline.isHidden = !showsDropOutline
            layoutOutline()
        }
    }

    override func layout() {
        super.layout()
        layoutOutline()
    }

    private func layoutOutline() {
        guard outline.superlayer != nil, let theme = controller?.theme else { return }
        outline.frame = bounds
        outline.path = CGPath(roundedRect: bounds.insetBy(dx: 6.75, dy: 6.75), cornerWidth: 8, cornerHeight: 8, transform: nil)
        outline.fillColor = nil
        outline.strokeColor = theme.accent.withAlphaComponent(0.55).cgColor
        outline.lineWidth = 1.5
        outline.lineDashPattern = [6, 4]
        outline.zPosition = 10
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        controller?.viewMovedToWindow()
    }
}

/// The table: keys the list handles itself (open, Quick Look, expand, switch pane), the
/// folder arrows, context menus and the pointing-hand cursor.
final class FileTableView: NSTableView {
    weak var controller: FileTableController?
    private(set) var hoveredLine: Int?
    private var tracking: NSTrackingArea?

    var isFocused: Bool { window?.isKeyWindow == true && window?.firstResponder === self }

    /// A click in a window that isn't in front selects the row there too, like Finder.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { controller?.becameFirstResponder() }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { controller?.redrawSelected() }
        return resigned
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(keyChanged), name: name, object: window)
        }
    }

    @objc private func keyChanged() { controller?.redrawSelected() }

    override func keyDown(with event: NSEvent) {
        guard let controller else { return super.keyDown(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let plain = flags.isDisjoint(with: [.command, .control, .option])
        switch event.keyCode {
        case 36 where plain, 76 where plain: // return, enter
            controller.openSelection()
        case 49 where plain: // space
            controller.quickLook()
        case 53: // escape
            if !controller.clearSelection() { super.keyDown(with: event) }
        case 48 where plain && controller.config.switchPane != nil: // tab
            controller.config.switchPane?()
        case 123 where plain: // left
            if !controller.expandOrCollapse(expanding: false) { super.keyDown(with: event) }
        case 124 where plain: // right
            if !controller.expandOrCollapse(expanding: true) { super.keyDown(with: event) }
        default:
            super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let line = row(at: point)
        // The folder arrow expands or collapses the row without selecting it.
        if let controller, let item = controller.row(atLine: line), item.expansion != nil, controller.config.onToggleExpand != nil {
            let layout = FileTableLayout(width: rect(ofRow: line).width, showLocation: controller.config.showLocation, depth: item.depth)
            if layout.disclosureHitRect.contains(point.x - rect(ofRow: line).minX) {
                controller.toggleExpansion(of: item.id)
                return
            }
        }
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        #if DEBUG
        // Scripted clicks reach a window in the background, which NSTableView ignores; a real
        // click activates the app first. Do what the table would.
        if !NSApp.isActive, DebugSnapshots.isRunning {
            scriptedClick(line: line, event: event)
            return
        }
        #endif
        super.mouseDown(with: event)
    }

    #if DEBUG
    private func scriptedClick(line: Int, event: NSEvent) {
        let flags = event.modifierFlags
        guard line >= 0, controller?.row(atLine: line) != nil else {
            deselectAll(nil)
            return
        }
        if flags.contains(.command) {
            if isRowSelected(line) { deselectRow(line) } else { selectRowIndexes([line], byExtendingSelection: true) }
        } else if flags.contains(.shift), selectedRow >= 0 {
            let anchor = selectedRowIndexes.first ?? line
            selectRowIndexes(IndexSet(integersIn: min(anchor, line)...max(anchor, line)), byExtendingSelection: false)
        } else {
            selectRowIndexes([line], byExtendingSelection: false)
        }
        if event.clickCount == 2 { controller?.open(line: line, newTab: flags.contains(.command)) }
    }
    #endif

    override func menu(for event: NSEvent) -> NSMenu? {
        let line = row(at: convert(event.locationInWindow, from: nil))
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        return controller?.menu(forLine: line)
    }

    // MARK: Hover and cursor

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        setHovered(row(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHovered(nil)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    private func setHovered(_ line: Int?) {
        let line = line.flatMap { $0 >= 0 ? $0 : nil }
        guard line != hoveredLine else { return }
        for old in [hoveredLine, line].compactMap({ $0 }) where old < numberOfRows {
            rowView(atRow: old, makeIfNecessary: false)?.needsDisplay = true
            (view(atColumn: 0, row: old, makeIfNecessary: false) as? FileCellView)?.needsDisplay = true
        }
        hoveredLine = line
        if let line, let row = controller?.row(atLine: line), row.item.isFolder { ListingCache.shared.readAhead(row.id, .pointer) }
    }

    // MARK: Dragging

    override func draggingExited(_ sender: NSDraggingInfo?) {
        super.draggingExited(sender)
        controller?.draggingEnded()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        super.draggingEnded(sender)
        controller?.draggingEnded()
    }
}

/// A row's background: the selection (with its accent mark), hover and drop highlight.
final class FileRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("FileRow")
    weak var controller: FileTableController?

    override var isEmphasized: Bool {
        get { false }
        set {}
    }

    override func drawBackground(in dirtyRect: NSRect) {
        guard let controller, let table = superview as? FileTableView else { return }
        let line = table.row(for: self)
        guard line >= 0, controller.row(atLine: line) != nil else { return }
        let theme = controller.theme
        let rect = bounds.insetBy(dx: FileTableLayout.gutter, dy: 0)
        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        if isSelected {
            // A plain fill, a shade lighter while the list has the keyboard.
            (table.isFocused ? theme.accentSoft : theme.accentSoft.withAlphaComponent(0.6)).setFill()
            path.fill()
        } else if table.hoveredLine == line || HoverPreview.on {
            theme.hoverFill.setFill()
            path.fill()
        }
        if controller.dropLine == line {
            theme.accent.setStroke()
            let ring = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), xRadius: 6, yRadius: 6)
            ring.lineWidth = 1.5
            ring.stroke()
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        // Drawn in drawBackground, with the rest of the row's states.
    }
}

/// Where everything in a row goes, shared by drawing, the header, clicks and tooltips so they
/// never disagree. Matches the SwiftUI list it replaced.
struct FileTableLayout {
    static let rowHeight: CGFloat = 26
    static let rowSpacing: CGFloat = 1
    static let groupHeight: CGFloat = 38
    static let headerHeight: CGFloat = 30
    /// Outer gutter (the list) and inner padding (the row).
    static let gutter: CGFloat = 8
    static let inset: CGFloat = 10
    static let spacing: CGFloat = 10
    static let marker: CGFloat = 10
    static let typeWidth: CGFloat = 140
    static let sizeWidth: CGFloat = 76
    static let dateWidth: CGFloat = 110
    /// The type icon before each name.
    static let icon: CGFloat = 14
    static let indent: CGFloat = 16

    let name: ClosedRange<CGFloat>
    let location: ClosedRange<CGFloat>?
    let type: ClosedRange<CGFloat>
    let size: ClosedRange<CGFloat>
    let date: ClosedRange<CGFloat>
    let marker: CGFloat
    /// Where a click on the folder arrow lands, generously.
    let disclosureHitRect: ClosedRange<CGFloat>

    init(width: CGFloat, showLocation: Bool, depth: Int) {
        let left = Self.gutter + Self.inset
        let right = width - Self.gutter - Self.inset
        date = (right - Self.dateWidth)...right
        size = (date.lowerBound - Self.spacing - Self.sizeWidth)...(date.lowerBound - Self.spacing)
        type = (size.lowerBound - Self.spacing - Self.typeWidth)...(size.lowerBound - Self.spacing)
        marker = left + CGFloat(depth) * Self.indent
        let nameStart = marker + Self.marker + 6 + Self.icon + 8
        let flexibleEnd = type.lowerBound - Self.spacing
        if showLocation {
            let available = max(0, flexibleEnd - nameStart - Self.spacing)
            let nameEnd = max(nameStart, nameStart + available / 2)
            name = nameStart...nameEnd
            location = min(flexibleEnd, nameEnd + Self.spacing)...flexibleEnd
        } else {
            name = nameStart...max(nameStart, flexibleEnd)
            location = nil
        }
        disclosureHitRect = (marker - 6)...(marker + Self.marker + 6)
    }

    func toolTip(at x: CGFloat, row: ListRow, git: GitMark?) -> String {
        if date.contains(x) { return Format.date(row.date) }
        if type.contains(x) { return row.item.kindDescription }
        if let location, location.contains(x) { return row.location ?? "" }
        if name.contains(x) {
            if let git {
                switch git {
                case .changed(let change): return "\(row.item.name) · \(change.title)"
                case .contains(_, let count): return "\(row.item.name) · \(count == 1 ? "1 change inside" : "\(count) changes inside")"
                case .ignored: break
                }
            }
            return row.item.isSymlink ? "\(row.item.name) · alias or symbolic link" : row.item.name
        }
        return ""
    }
}

/// One file's row, drawn in a single pass.
final class FileCellView: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("FileCell")
    weak var controller: FileTableController?
    var row: ListRow? {
        didSet { if row?.item != oldValue?.item { kind = nil } }
    }
    /// The kind, worked out once per item rather than on every draw.
    private var kind: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let row, let controller else { return }
        let theme = controller.theme
        let config = controller.config
        let item = row.item
        let layout = FileTableLayout(width: bounds.width, showLocation: config.showLocation, depth: row.depth)
        let midY = bounds.midY
        let isCut = !config.cut.isEmpty && config.cut.contains(row.id.standardizedFileURL)
        let git = config.gitMark?(row.id)
        if isCut { NSGraphicsContext.current?.cgContext.setAlpha(0.4) }

        // Folder arrow.
        if item.isFolder {
            let table = superview?.superview as? FileTableView
            let line = table?.row(for: self) ?? -1
            let expandable = row.expansion != nil && config.onToggleExpand != nil
            let hovered = expandable && table?.hoveredLine == line && Self.mouseX(in: self).map { layout.disclosureHitRect.contains($0) } == true
            if hovered {
                theme.raisedHover.setFill()
                NSBezierPath(roundedRect: NSRect(x: layout.marker + FileTableLayout.marker / 2 - 8, y: midY - 8, width: 16, height: 16),
                             xRadius: 4, yRadius: 4).fill()
            }
            let color = hovered || row.expansion == true ? theme.text : theme.textSecondary
            theme.chevron(color: color, expanded: row.expansion == true)
                .draw(in: Self.centered(theme.chevronSize, in: NSRect(x: layout.marker, y: midY - 6, width: FileTableLayout.marker, height: 12)))
        }

        // The type icon: a folder in grey, a file tinted (softly) by its kind.
        let icon = theme.typeIcon(for: item)
        icon.draw(in: Self.centered(icon.size, in: NSRect(x: layout.marker + FileTableLayout.marker + 6, y: midY - 7,
                                                          width: FileTableLayout.icon, height: 14)))

        // Name, then the alias arrow and git mark after it.
        let nameColor = item.isHidden || git == .ignored ? theme.textTertiary : (item.isFolder ? theme.text : theme.body)
        let nameFont = item.isFolder ? theme.nameBold : theme.name
        var badgeWidth: CGFloat = 0
        if item.isSymlink { badgeWidth += 5 + 9 }
        if let git, git != .ignored { badgeWidth += 5 + 9 }
        let nameMax = max(0, layout.name.upperBound - layout.name.lowerBound - badgeWidth)
        let nameWidth = Self.drawText(item.name, font: nameFont, color: nameColor, x: layout.name.lowerBound, midY: midY,
                                      width: nameMax, truncation: .byTruncatingMiddle)
        var x = layout.name.lowerBound + nameWidth + 5
        if item.isSymlink {
            theme.aliasArrow.draw(in: Self.centered(theme.aliasArrow.size, in: NSRect(x: x, y: midY - 5, width: 9, height: 10)))
            x += 9 + 5
        }
        if let git {
            switch git {
            case .changed(let change):
                Self.drawText(change.letter, font: theme.gitFont, color: NSColor(change.color), x: x, midY: midY, width: 12)
            case .contains(let change, _):
                NSColor(change.color).setFill()
                NSBezierPath(ovalIn: NSRect(x: x + 1, y: midY - 2.5, width: 5, height: 5)).fill()
            case .ignored:
                break
            }
        }

        // Where it is, in mixed lists.
        if let location = layout.location {
            Self.drawText(row.location.map(Format.path) ?? "", font: theme.location, color: theme.textTertiary,
                          x: location.lowerBound, midY: midY, width: location.upperBound - location.lowerBound,
                          truncation: .byTruncatingMiddle)
        }

        // Kind, in words.
        let kind = self.kind ?? (item.isFolder ? "Folder" : item.kindDescription)
        self.kind = kind
        Self.drawText(kind, font: theme.meta, color: theme.textSecondary, x: layout.type.lowerBound, midY: midY,
                      width: layout.type.upperBound - layout.type.lowerBound)

        // Size.
        let measured = row.liveFolderSize && row.size == nil ? FolderSizeStore.shared.size(for: item.path) : nil
        let size = row.size ?? measured?.bytes
        let sizeText: String
        var sizeColor = theme.textSecondary
        if let size {
            sizeText = (measured.map { !$0.complete } ?? false ? "≥ " : "") + Format.bytes(size)
        } else if row.liveFolderSize && FolderSizeStore.shared.isCalculating(item.path) {
            sizeText = "···"
            sizeColor = theme.textTertiary
        } else {
            sizeText = "—"
            sizeColor = theme.textTertiary
        }
        Self.drawText(sizeText, font: theme.meta, color: sizeColor, x: layout.size.lowerBound, midY: midY,
                      width: layout.size.upperBound - layout.size.lowerBound, alignment: .right)

        // When.
        Self.drawText(Format.listDate(row.date), font: theme.meta, color: theme.textSecondary,
                      x: layout.date.lowerBound, midY: midY, width: FileTableLayout.dateWidth, alignment: .right)
    }

    /// Draws one line of text vertically centered at `midY`; returns the width it took.
    @discardableResult
    static func drawText(_ text: String, font: NSFont, color: NSColor, x: CGFloat, midY: CGFloat, width: CGFloat,
                         alignment: NSTextAlignment = .left, truncation: NSLineBreakMode = .byTruncatingTail) -> CGFloat {
        guard width > 0, !text.isEmpty else { return 0 }
        let fitted = TextLines.shared.line(text, font: font, color: color, fitting: width, truncation: truncation)
        let top = midY - ceil(TextLines.height(of: font)) / 2
        let x = switch alignment {
        case .right: x + width - fitted.width
        case .center: x + (width - fitted.width) / 2
        default: x
        }
        TextLines.draw(fitted.line, font: font, at: NSPoint(x: x, y: top))
        return min(ceil(fitted.width), width)
    }

    static func centered(_ size: NSSize, in rect: NSRect) -> NSRect {
        NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
    }

    private static func mouseX(in view: NSView) -> CGFloat? {
        guard let window = view.window else { return nil }
        return view.convert(window.mouseLocationOutsideOfEventStream, from: nil).x
    }
}

/// A group's title ("Today", "Yesterday") with a rule after it.
final class GroupCellView: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("GroupCell")
    var theme: TableTheme?
    var title = "" { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let theme else { return }
        let string = NSAttributedString(string: title, attributes: [.font: theme.caption, .foregroundColor: theme.textSecondary])
        let size = string.size()
        string.draw(at: NSPoint(x: FileTableLayout.gutter + FileTableLayout.inset, y: bounds.height - 6 - size.height))
    }
}

/// Column titles that sort when clicked, with the sort arrow's space always kept so titles
/// never shift.
final class FileTableHeaderView: NSTableHeaderView {
    weak var controller: FileTableController?
    /// The sortable title under the mouse.
    private var hovered: SortKey?
    private var tracking: NSTrackingArea?

    init(controller: FileTableController) {
        self.controller = controller
        super.init(frame: NSRect(x: 0, y: 0, width: 100, height: FileTableLayout.headerHeight))
    }

    required init?(coder: NSCoder) { fatalError() }

    private struct Title {
        let text: String
        let key: SortKey?
        let range: ClosedRange<CGFloat>
        let trailing: Bool
    }

    private func titles() -> [Title] {
        guard let controller else { return [] }
        let config = controller.config
        let layout = FileTableLayout(width: bounds.width, showLocation: config.showLocation, depth: 0)
        var titles = [Title(text: "Name", key: .name, range: layout.name.lowerBound...(layout.name.lowerBound + 60), trailing: false)]
        if let location = layout.location {
            titles.append(Title(text: "Location", key: nil, range: location.lowerBound...(location.lowerBound + 70), trailing: false))
        }
        titles.append(Title(text: "Kind", key: .kind, range: layout.type, trailing: false))
        titles.append(Title(text: "Size", key: .size, range: layout.size, trailing: true))
        titles.append(Title(text: config.dateTitle, key: config.dateSortKey, range: (layout.date.lowerBound - 20)...layout.date.upperBound, trailing: true))
        return titles
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let controller else { return }
        let theme = controller.theme
        theme.background.setFill()
        bounds.fill()
        theme.border.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        let sort = controller.config.sort
        let layout = FileTableLayout(width: bounds.width, showLocation: controller.config.showLocation, depth: 0)
        for title in titles() {
            let active = title.key != nil && sort?.key == title.key
            let isHovered = title.key != nil && hovered == title.key && controller.config.onSort != nil
            let color = isHovered ? theme.text : (active ? theme.textSecondary : theme.textTertiary)
            let string = NSAttributedString(string: title.text, attributes: [.font: theme.header, .foregroundColor: color])
            let size = string.size()
            let arrow = theme.sortArrow(ascending: sort?.ascending == true, color: color)
            let y = (bounds.height - size.height) / 2
            let x = title.trailing ? title.range.upperBound - size.width : title.range.lowerBound
            string.draw(at: NSPoint(x: x, y: y))
            if active {
                let arrowX = title.trailing ? x - 3 - 9 : x + size.width + 3
                arrow.draw(in: FileCellView.centered(arrow.size, in: NSRect(x: arrowX, y: bounds.midY - 5, width: 9, height: 10)))
            }
        }
    }

    override var isFlipped: Bool { true }

    private func title(at point: NSPoint) -> Title? {
        titles().first { $0.key != nil && $0.range.contains(point.x) }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let title = title(at: point), let key = title.key else { return }
        controller?.config.onSort?(key)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        let key = title(at: convert(event.locationInWindow, from: nil))?.key
        if hovered != key {
            hovered = key
            needsDisplay = true
        }
        (key != nil ? NSCursor.pointingHand : NSCursor.arrow).set()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        needsDisplay = true
        NSCursor.arrow.set()
    }

    override func cursorUpdate(with event: NSEvent) {}

    override func resetCursorRects() {}
}

// MARK: - Text

/// Lines of text for rows, laid out once by Core Text and kept. Rows say the same things over
/// and over ("7 B", "1h", "TXT", and each name every time its row is drawn again), and laying
/// a string out with AppKit's string drawing, to measure it and again to draw it, was half of
/// what drawing a row cost.
@MainActor
final class TextLines {
    static let shared = TextLines()

    struct Fitted {
        let line: CTLine
        let width: CGFloat
    }

    private struct Key: Hashable {
        let text: String
        let font: NSFont
        let color: NSColor
        /// The width it was cut to fit, and how; zero for the whole line.
        var width: CGFloat = 0
        var truncation = 0
    }

    private var lines: [Key: Fitted] = [:]

    /// The whole line.
    func line(_ text: String, font: NSFont, color: NSColor) -> Fitted {
        let key = Key(text: text, font: font, color: color)
        if let hit = lines[key] { return hit }
        if lines.count > 6000 { lines.removeAll(keepingCapacity: true) }
        let string = NSAttributedString(string: text, attributes: [
            .font: font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor,
        ])
        let line = CTLineCreateWithAttributedString(string)
        let fitted = Fitted(line: line, width: CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
        lines[key] = fitted
        return fitted
    }

    /// The line cut down with "…" (at the end, or in the middle) when it's wider than `width`.
    func line(_ text: String, font: NSFont, color: NSColor, fitting width: CGFloat, truncation: NSLineBreakMode) -> Fitted {
        let whole = line(text, font: font, color: color)
        guard whole.width > width else { return whole }
        let type: CTLineTruncationType = switch truncation {
        case .byTruncatingMiddle: .middle
        case .byTruncatingHead: .start
        default: .end
        }
        let key = Key(text: text, font: font, color: color, width: width, truncation: Int(type.rawValue) + 1)
        if let hit = lines[key] { return hit }
        let token = line("…", font: font, color: color).line
        let cut = CTLineCreateTruncatedLine(whole.line, Double(width), type, token) ?? whole.line
        let fitted = Fitted(line: cut, width: CGFloat(CTLineGetTypographicBounds(cut, nil, nil, nil)))
        lines[key] = fitted
        return fitted
    }

    /// A line's height in `font`, as AppKit's string drawing lays it out.
    static func height(of font: NSFont) -> CGFloat {
        font.ascender - font.descender + font.leading
    }

    /// Draws a line whose top is at `point`, in a flipped view.
    static func draw(_ line: CTLine, font: NSFont, at point: NSPoint) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: point.x, y: point.y + font.ascender)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}

// MARK: - Colors and fonts

/// The theme as AppKit colors and fonts, converted once per list (a new theme rebuilds the
/// windows), plus the few symbols rows draw.
@MainActor
final class TableTheme {
    let background, border, text, textSecondary, textTertiary, body: NSColor
    let accent, accentSoft, hoverFill, raisedHover: NSColor
    private let warning, hot: NSColor
    let name = NSFont.systemFont(ofSize: 12.5)
    let nameBold = NSFont.systemFont(ofSize: 12.5, weight: .medium)
    /// Sizes, dates and kinds: the system font with even-width digits, so columns line up.
    let meta = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    let location = NSFont.systemFont(ofSize: 11.5)
    let mono = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    let gitFont = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .bold)
    let header = NSFont.systemFont(ofSize: 11, weight: .medium)
    let caption = NSFont.systemFont(ofSize: 12, weight: .semibold)
    let chip: NSFont = {
        let base = NSFont.systemFont(ofSize: 9, weight: .bold)
        return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 9) } ?? base
    }()
    let chevronSize = NSSize(width: 6, height: 10)
    private var colorCache: [Color: NSColor] = [:]
    private var chipFills: [NSColor: NSColor] = [:]
    private var symbolCache: [String: NSImage] = [:]

    init() {
        background = NSColor(Theme.background)
        border = NSColor(Theme.border)
        text = NSColor(Theme.text)
        textSecondary = NSColor(Theme.textSecondary)
        textTertiary = NSColor(Theme.textTertiary)
        body = NSColor(Theme.body)
        accent = NSColor(Theme.accent)
        accentSoft = NSColor(Theme.accentSoft)
        hoverFill = NSColor(Theme.colors.hoverFill)
        raisedHover = NSColor(Theme.colors.raisedHover)
        warning = NSColor(Theme.warning)
        hot = NSColor(Theme.hot)
    }

    private var typeIcons: [String: NSImage] = [:]

    /// A row's icon: a folder in grey, or a page tinted softly by the file's kind (images
    /// lavender, video pink, code orange…), the type's colour mixed well toward grey so it
    /// marks the kind without shouting.
    func typeIcon(for item: FileItem) -> NSImage {
        if item.isFolder { return symbol("folder", size: 11.5, weight: .regular, color: textSecondary) }
        let base = color(for: TypeChip.style(for: item).color)
        let key = base.description
        if let cached = typeIcons[key] { return cached }
        let tint = base.blended(withFraction: 0.35, of: textSecondary) ?? base
        let icon = symbol("doc", size: 11.5, weight: .regular, color: tint)
        typeIcons[key] = icon
        return icon
    }

    func heat(_ fraction: Double) -> NSColor {
        fraction < 0.25 ? accent : (fraction < 0.6 ? warning : hot)
    }

    /// A SwiftUI color as an NSColor, converted once.
    func color(for color: Color) -> NSColor {
        if let cached = colorCache[color] { return cached }
        let converted = NSColor(color)
        colorCache[color] = converted
        return converted
    }

    /// The faint fill behind a type chip of this color.
    func chipFill(_ color: NSColor) -> NSColor {
        if let cached = chipFills[color] { return cached }
        let fill = color.withAlphaComponent(0.14)
        chipFills[color] = fill
        return fill
    }

    func chevron(color: NSColor, expanded: Bool) -> NSImage {
        symbol(expanded ? "chevron.down" : "chevron.right", size: 8, weight: .heavy, color: color)
    }

    var aliasArrow: NSImage { symbol("arrow.turn.up.right", size: 8, weight: .bold, color: textTertiary) }

    func sortArrow(ascending: Bool, color: NSColor) -> NSImage {
        symbol(ascending ? "arrow.up" : "arrow.down", size: 8, weight: .bold, color: color)
    }

    func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSImage {
        let key = "\(name)|\(size)|\(weight.rawValue)|\(color.description)"
        if let cached = symbolCache[key] { return cached }
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight).applying(.init(paletteColors: [color]))
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) ?? NSImage()
        symbolCache[key] = image
        return image
    }
}
