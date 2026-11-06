import AppKit
import Observation
import SwiftUI

/// Browser-style tabs in the title bar, drawn by AppKit. Drop files on a tab to move them into
/// its folder; hover a drag over a tab to switch to it. Empty space drags the window, and a
/// double-click there does what the title bar's would.
///
/// A tab you open, pick or close is drawn and sent to the screen first, and the change made on
/// the next turn of the run loop, so the strip answers on the next frame however long the rest
/// of the window takes to lay itself out for it (see Workspace.changeTabs).
final class TabStripView: NSView {
    /// Tabs live in the top 32pt (the title bar), centred on the traffic lights' line.
    static let titleBarHeight: CGFloat = 32
    static let height: CGFloat = 36
    static let tabHeight: CGFloat = 24
    /// Room for the window's traffic lights.
    private static let leading: CGFloat = 72
    private static let spacing: CGFloat = 3
    private static let closeSide: CGFloat = 16

    private let workspace: Workspace
    private let theme = TableTheme()
    private let raised = NSColor(Theme.raised)
    private let fieldBorder = NSColor(Theme.fieldBorder)
    private let pressedFill = NSColor(Theme.pressedFill)
    private let font = NSFont.systemFont(ofSize: 12)
    private let boldFont = NSFont.systemFont(ofSize: 12, weight: .semibold)

    /// What a tab shows.
    private struct Tab: Equatable {
        let model: BrowserModel
        var label: String
        var icon: String
        var isSelected: Bool
        var isSplit: Bool
        var path: String
        /// A tab being opened, drawn before it exists.
        var isPlaceholder = false

        static func == (lhs: Tab, rhs: Tab) -> Bool {
            lhs.model === rhs.model && lhs.label == rhs.label && lhs.icon == rhs.icon && lhs.isSelected == rhs.isSelected
                && lhs.isSplit == rhs.isSplit && lhs.path == rhs.path && lhs.isPlaceholder == rhs.isPlaceholder
        }
    }

    /// Something in the strip you can point at.
    private enum Spot: Equatable {
        case tab(Int)
        case close(Int)
        case newTab
    }

    private var tabs: [Tab] = []
    private var tabFrames: [NSRect] = []
    private var labelWidths: [CGFloat] = []
    private var newTabFrame = NSRect.zero
    private var closable: Bool { tabs.count > 1 }

    private var hovered: Spot?
    private var pressed: Spot?
    private var dropTarget: Int?
    private var springLoad: DispatchWorkItem?
    private var tracking: NSTrackingArea?
    /// Bumped on each read of the tabs, so only the latest Observation registration acts.
    private var generation = 0
    /// Changes drawn but not yet made; the tabs aren't read again until they are.
    private var pendingChanges = 0

    init(workspace: Workspace) {
        self.workspace = workspace
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL, .URL])
        refresh()
        workspace.performTabChange = { [weak self] change, apply in
            guard let self else { return apply() }
            self.perform(change, apply)
        }
        #if DEBUG
        RowGeometry.providers[ObjectIdentifier(self)] = { [weak self] in self?.debugFrames() ?? [] }
        #endif
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Following the tabs

    /// Reads the tabs, and again whenever anything they show changes.
    private func refresh() {
        guard pendingChanges == 0 else { return }
        generation += 1
        let current = generation
        let read = withObservationTracking { readTabs() } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.generation == current else { return }
                self.refresh()
            }
        }
        guard read != tabs else { return }
        tabs = read
        if let hovered, !isValid(hovered) { self.hovered = nil }
        relayout()
        needsDisplay = true
    }

    private func readTabs() -> [Tab] {
        let current = workspace.currentTab
        let name = { (pane: BrowserModel) in pane.isSearching ? "“\(pane.searchText)”" : pane.title }
        return workspace.tabs.map { tab in
            let second = workspace.secondPane(of: tab)
            return Tab(model: tab, label: second.map { name(tab) + " | " + name($0) } ?? name(tab),
                       icon: icon(for: tab, isSplit: second != nil), isSelected: tab === current,
                       isSplit: second != nil, path: Format.path(tab.currentURL.path))
        }
    }

    private func icon(for tab: BrowserModel, isSplit: Bool) -> String {
        if isSplit { return "rectangle.split.2x1.fill" }
        if tab.isSearching { return "magnifyingglass" }
        switch tab.destination {
        case .folder: return "folder.fill"
        case .recents: return "clock.fill"
        case .newFiles: return "sparkles"
        case .storage: return "chart.pie.fill"
        case .s3: return "cloud.fill"
        case .drive: return "externaldrive.fill.badge.icloud"
        }
    }

    /// Draws a change of tabs and hands it to the window server, then makes it on the next turn
    /// of the run loop. Drawn first, the strip is all that's on its way to the screen; drawn
    /// once the change was made, the rest of the window would lay itself out early to go with it.
    private func perform(_ change: TabChange, _ apply: @escaping () -> Void) {
        guard window != nil, preview(change) else { return apply() }
        relayout()
        displayIfNeeded()
        CATransaction.flush()
        LatencyMeter.shared.noteFlush()
        pendingChanges += 1
        DispatchQueue.main.async { [weak self] in
            apply()
            guard let self else { return }
            self.pendingChanges -= 1
            self.refresh()
        }
    }

    /// The strip as it will be once `change` is made. False if it can't be drawn ahead.
    private func preview(_ change: TabChange) -> Bool {
        guard let current = tabs.firstIndex(where: \.isSelected) else { return false }
        switch change {
        case .select(let index):
            guard tabs.indices.contains(index), !tabs[index].isPlaceholder else { return false }
            for other in tabs.indices { tabs[other].isSelected = other == index }
        case .open:
            // The new tab shows the active pane's folder.
            let pane = workspace.selected
            var tab = tabs[current]
            tab.label = pane.isSearching ? "“\(pane.searchText)”" : pane.title
            tab.icon = icon(for: pane, isSplit: false)
            tab.isSplit = false
            tab.isPlaceholder = true
            tabs[current].isSelected = false
            tabs.insert(tab, at: current + 1)
        case .close(let index):
            guard tabs.count > 1, tabs.indices.contains(index) else { return false }
            let wasSelected = tabs[index].isSelected
            tabs.remove(at: index)
            if wasSelected { tabs[min(index, tabs.count - 1)].isSelected = true }
        }
        hovered = nil
        needsDisplay = true
        return true
    }

    private func isValid(_ spot: Spot) -> Bool {
        switch spot {
        case .tab(let index), .close(let index): tabs.indices.contains(index)
        case .newTab: true
        }
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        relayout()
    }

    private func symbol(_ name: String, color: NSColor) -> NSImage {
        theme.symbol(name, size: 9.5, weight: .bold, color: color)
    }

    /// Each tab as wide as its name (up to a limit), narrower all round when they don't fit.
    private func relayout() {
        let fixed = tabs.map { tab in
            10 + symbol(tab.icon, color: theme.accent).size.width + 6 + (closable ? 6 + Self.closeSide + 4 : 10)
        }
        let natural = tabs.map { tab in
            let width = ceil((tab.label as NSString).size(withAttributes: [.font: tab.isSelected ? boldFont : font]).width)
            return min(width, tab.isSplit ? 220 : 150)
        }
        let available = bounds.width - Self.leading - Self.spacing * CGFloat(tabs.count) - Self.tabHeight - 8
        var cap: CGFloat = 220
        func total() -> CGFloat { zip(fixed, natural).reduce(0) { $0 + $1.0 + min($1.1, cap) } + Self.spacing * CGFloat(max(0, tabs.count - 1)) }
        while cap > 24 && total() > available { cap -= 4 }
        labelWidths = natural.map { min($0, cap) }
        var x = Self.leading
        let y = (Self.titleBarHeight - Self.tabHeight) / 2
        tabFrames = zip(fixed, labelWidths).map { fixed, label in
            let frame = NSRect(x: x, y: y, width: fixed + label, height: Self.tabHeight)
            x = frame.maxX + Self.spacing
            return frame
        }
        newTabFrame = NSRect(x: x, y: y, width: Self.tabHeight, height: Self.tabHeight)
        updateToolTips()
    }

    private func closeFrame(_ index: Int) -> NSRect? {
        guard closable, tabFrames.indices.contains(index) else { return nil }
        let tab = tabFrames[index]
        return NSRect(x: tab.maxX - 4 - Self.closeSide, y: tab.midY - Self.closeSide / 2, width: Self.closeSide, height: Self.closeSide)
    }

    private func spot(at point: NSPoint) -> Spot? {
        if newTabFrame.contains(point) { return .newTab }
        guard let index = tabFrames.firstIndex(where: { $0.contains(point) }) else { return nil }
        if let close = closeFrame(index), close.contains(point) { return .close(index) }
        return .tab(index)
    }

    private func tabIndex(of spot: Spot?) -> Int? {
        switch spot {
        case .tab(let index), .close(let index): index
        default: nil
        }
    }

    private func updateToolTips() {
        removeAllToolTips()
        for (tab, frame) in zip(tabs, tabFrames) {
            addToolTip(frame, owner: tab.path as NSString, userData: nil)
        }
        addToolTip(newTabFrame, owner: "New tab (⌘T)" as NSString, userData: nil)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let radius = Theme.controlRadius + 1
        let hoveredTab = HoverPreview.on ? nil : tabIndex(of: hovered)
        for (index, tab) in tabs.enumerated() where tabFrames.indices.contains(index) {
            let frame = tabFrames[index]
            let isHovered = hoveredTab == index || HoverPreview.on
            let isDropTarget = dropTarget == index
            let shape = NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius)
            if tab.isSelected {
                raised.setFill()
                shape.fill()
            } else if isHovered {
                theme.hoverFill.setFill()
                shape.fill()
            }
            if isDropTarget || tab.isSelected {
                let ring = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: radius - 0.5, yRadius: radius - 0.5)
                ring.lineWidth = 1
                if isDropTarget { ring.setLineDash([4, 3], count: 2, phase: 0) }
                (isDropTarget ? theme.accent : fieldBorder).setStroke()
                ring.stroke()
            }
            // Icon, then the name, truncated in the middle when it's too long.
            let icon = symbol(tab.icon, color: tab.isSelected || isDropTarget ? theme.accent : theme.textTertiary)
            var x = frame.minX + 10
            icon.draw(in: NSRect(x: x, y: frame.midY - icon.size.height / 2, width: icon.size.width, height: icon.size.height))
            x += icon.size.width + 6
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingMiddle
            let label = NSAttributedString(string: tab.label, attributes: [
                .font: tab.isSelected ? boldFont : font,
                .foregroundColor: tab.isSelected ? theme.text : theme.textSecondary,
                .paragraphStyle: style,
            ])
            let height = ceil(label.size().height)
            label.draw(with: NSRect(x: x, y: frame.midY - height / 2, width: labelWidths[index], height: height),
                       options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            if let close = closeFrame(index), isHovered || tab.isSelected {
                let onClose = hovered == .close(index)
                if onClose {
                    (pressed == .close(index) ? pressedFill : theme.raisedHover).setFill()
                    NSBezierPath(roundedRect: close, xRadius: Theme.chipRadius, yRadius: Theme.chipRadius).fill()
                }
                let mark = theme.symbol("xmark", size: 8, weight: .bold, color: onClose ? theme.text : theme.textTertiary)
                mark.draw(in: NSRect(x: close.midX - mark.size.width / 2, y: close.midY - mark.size.height / 2,
                                     width: mark.size.width, height: mark.size.height))
            }
        }
        let onNewTab = hovered == .newTab || HoverPreview.on
        if pressed == .newTab || onNewTab {
            (pressed == .newTab ? pressedFill : theme.raisedHover).setFill()
            NSBezierPath(roundedRect: newTabFrame, xRadius: Theme.controlRadius, yRadius: Theme.controlRadius).fill()
        }
        let plus = theme.symbol("plus", size: 10.5, weight: .semibold, color: onNewTab ? theme.text : theme.textSecondary)
        plus.draw(in: NSRect(x: newTabFrame.midX - plus.size.width / 2, y: newTabFrame.midY - plus.size.height / 2,
                             width: plus.size.width, height: plus.size.height))
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        let spot = spot(at: convert(event.locationInWindow, from: nil))
        if spot != hovered {
            hovered = spot
            needsDisplay = true
        }
        let clickable: Bool
        switch spot {
        case .tab(let index): clickable = !tabs[index].isSelected
        case .close, .newTab: clickable = true
        case nil: clickable = false
        }
        (clickable ? NSCursor.pointingHand : NSCursor.arrow).set()
    }

    override func mouseExited(with event: NSEvent) {
        guard hovered != nil else { return }
        hovered = nil
        needsDisplay = true
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        switch spot(at: convert(event.locationInWindow, from: nil)) {
        case .tab(let index):
            // On the press, as browsers do: the tab is picked before you let go.
            if !tabs[index].isPlaceholder { workspace.pickTab(tabs[index].model) }
        case let spot?:
            pressed = spot
            needsDisplay = true
        case nil:
            if event.clickCount == 2 {
                titleBarDoubleClick()
            } else {
                window?.performDrag(with: event)
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressed else { return }
        // Pressed only while the pointer's still on it, as buttons are.
        let inside = spot(at: convert(event.locationInWindow, from: nil)) == pressed
        if inside != (hovered == pressed) {
            hovered = inside ? pressed : nil
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let pressed else { return }
        self.pressed = nil
        needsDisplay = true
        guard spot(at: convert(event.locationInWindow, from: nil)) == pressed else { return }
        switch pressed {
        case .close(let index): if !tabs[index].isPlaceholder { workspace.closeTab(tabs[index].model) }
        case .newTab: workspace.openNewTab()
        case .tab: break
        }
    }

    /// What double-clicking a title bar does in System Settings › Desktop & Dock.
    private func titleBarDoubleClick() {
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": window?.performMiniaturize(nil)
        case "None": break
        default: window?.performZoom(nil)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let index = tabIndex(of: spot(at: convert(event.locationInWindow, from: nil))), !tabs[index].isPlaceholder else { return nil }
        let tab = tabs[index].model
        let workspace = workspace
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(ActionMenuItem("Duplicate Tab") { [weak workspace] in workspace?.newTab(tab.currentURL) })
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Copy Path") { FileActions.copyPaths([tab.currentURL]) })
        menu.addItem(ActionMenuItem(FileActions.openInTerminalTitle) { FileActions.openInTerminal(tab.currentURL) })
        menu.addItem(.separator())
        let close = ActionMenuItem("Close Tab") { [weak workspace] in workspace?.closeTab(tab) }
        let closeOthers = ActionMenuItem("Close Other Tabs") { [weak workspace] in workspace?.closeOthers(than: tab) }
        close.isEnabled = tabs.count > 1
        closeOthers.isEnabled = tabs.count > 1
        menu.addItem(close)
        menu.addItem(closeOthers)
        return menu
    }

    // MARK: Dropping

    private func dropIndex(_ sender: NSDraggingInfo) -> Int? {
        tabIndex(of: spot(at: convert(sender.draggingLocation, from: nil)))
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let index = dropIndex(sender)
        if index != dropTarget {
            dropTarget = index
            needsDisplay = true
            springLoad?.cancel()
            springLoad = nil
            // Hovering a drag over a tab switches to it, so you can drop into a subfolder there.
            if let index, !tabs[index].isSelected, !tabs[index].isPlaceholder {
                let tab = tabs[index].model
                let work = DispatchWorkItem { [weak self] in self?.workspace.select(tab) }
                springLoad = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.65, execute: work)
            }
        }
        guard index != nil else { return [] }
        return NSEvent.modifierFlags.contains(.option) ? .copy : .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        endDrop()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        endDrop()
    }

    private func endDrop() {
        springLoad?.cancel()
        springLoad = nil
        guard dropTarget != nil else { return }
        dropTarget = nil
        needsDisplay = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { endDrop() }
        guard let index = dropIndex(sender), !tabs[index].isPlaceholder else { return false }
        let tab = tabs[index].model
        let urls = FileTableController.urls(from: sender.draggingPasteboard)
        return !urls.isEmpty && tab.receiveDrop(urls, into: tab.currentURL)
    }

    // MARK: Scripted runs

    #if DEBUG
    /// The tabs ("tab-0"…) and the new tab button ("newtab-button"), in the window from its top left.
    private func debugFrames() -> [(URL, CGRect, Int)] {
        guard let content = window?.contentView else { return [] }
        let named = tabFrames.enumerated().map { ("tab-\($0.offset)", $0.element) } + [("newtab-button", newTabFrame)]
        return named.map { name, frame in
            let rect = convert(frame, to: nil)
            return (URL(fileURLWithPath: "/debug-rows/" + name), CGRect(x: rect.minX, y: content.bounds.height - rect.maxY, width: rect.width, height: rect.height), 0)
        }
    }
    #endif
}
