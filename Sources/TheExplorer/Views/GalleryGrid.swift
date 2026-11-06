import AppKit
import SwiftUI

// MARK: - SwiftUI bridge

/// The gallery, drawn by AppKit: the same items as the list, as a grid of thumbnails, for
/// scrolling through photos and videos. Selection, opening, Quick Look, menus, dragging and
/// dropping work as in the list. Pinch, ⌘+ and ⌘− (or the slider in the bar) change the tile
/// size.
///
/// As a SwiftUI grid, switching to it built every tile's view (~40ms) and each selection
/// change compared them all again; here only the tiles on screen are drawn, each in one pass.
struct GalleryGrid<RowMenu: View, BackgroundMenu: View>: NSViewRepresentable {
    let rows: [ListRow]
    @Binding var selection: Set<URL>
    var focusRequest: Int
    let onOpen: (Set<URL>, Bool) -> Void
    var onQuickLook: (Set<URL>, [ListRow]) -> Void
    var onDropBackground: (([URL]) -> Bool)?
    var onReachEnd: (() -> Void)?
    var footer: AnyView?
    let rowMenu: (Set<URL>) -> RowMenu
    let backgroundMenu: () -> BackgroundMenu

    @Environment(\.isActivePane) private var isActivePane
    @Environment(\.activatePane) private var activatePane
    @Environment(\.switchPane) private var switchPane

    func makeNSView(context: Context) -> GalleryScrollView {
        let scroll = GalleryScrollView()
        apply(to: scroll.grid, context: context)
        return scroll
    }

    func updateNSView(_ view: GalleryScrollView, context: Context) {
        apply(to: view.grid, context: context)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: GalleryScrollView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 400, height: 300))
    }

    private func apply(to grid: GalleryGridView, context: Context) {
        let environment = context.environment
        let selectionBinding = $selection
        var config = GalleryGridView.Config()
        config.isActivePane = isActivePane
        config.activatePane = activatePane
        config.switchPane = switchPane
        config.onOpen = onOpen
        config.onQuickLook = onQuickLook
        config.onDropBackground = onDropBackground
        config.onReachEnd = onReachEnd
        config.footer = footer
        config.setSelection = { selectionBinding.wrappedValue = $0 }
        let rowMenu = self.rowMenu
        let backgroundMenu = self.backgroundMenu
        config.rowMenu = { urls, rows in
            NSHostingMenu(rootView: rowMenu(urls).environment(\.self, environment).environment(\.listedItems, ListedItems(rows)))
        }
        config.backgroundMenu = { NSHostingMenu(rootView: backgroundMenu().environment(\.self, environment)) }
        grid.update(rows: rows, selection: selection, focusRequest: focusRequest, tileSize: CGFloat(Prefs.shared.galleryTileSize), config: config)
    }
}

final class GalleryScrollView: NSScrollView {
    let grid = GalleryGridView()

    init() {
        super.init(frame: .zero)
        drawsBackground = false
        hasVerticalScroller = true
        autohidesScrollers = true
        documentView = grid
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: contentView)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func scrolled() { grid.scrolled() }

    override func layout() {
        super.layout()
        grid.fit(width: contentView.bounds.width, height: contentView.bounds.height)
    }
}

// MARK: - The grid

final class GalleryGridView: NSView, NSDraggingSource {
    struct Config {
        var isActivePane = true
        var activatePane: (() -> Void)?
        var switchPane: (() -> Void)?
        var onOpen: (Set<URL>, Bool) -> Void = { _, _ in }
        var onQuickLook: (Set<URL>, [ListRow]) -> Void = { _, _ in }
        var onDropBackground: (([URL]) -> Bool)?
        var onReachEnd: (() -> Void)?
        var footer: AnyView?
        var setSelection: (Set<URL>) -> Void = { _ in }
        var rowMenu: (Set<URL>, [ListRow]) -> NSMenu = { _, _ in NSMenu() }
        var backgroundMenu: () -> NSMenu = { NSMenu() }
    }

    private static let spacing: CGFloat = 12
    private static let padding: CGFloat = 16
    private static let nameHeight: CGFloat = 18
    private static let headerHeight: CGFloat = 30

    private var config = Config()
    private var rows: [ListRow] = []
    private var index: [URL: Int] = [:]
    private var selection: Set<URL> = []
    /// A selection made here that SwiftUI hasn't been told of yet.
    private var pendingSelection: Set<URL>?
    private var anchor: URL?
    private var cursor: URL?
    private var focusRequest: Int?
    private var tileSize: CGFloat = 180
    private var hovered: Int?
    private var dropTargeted = false
    private var pressed: (index: Int?, at: NSPoint)?
    private var reachedEndAt = -1
    private var loading: Set<String> = []
    private var footerHost: NSHostingView<AnyView>?
    private var tracking: NSTrackingArea?

    /// Where everything is, worked out in `relayout`.
    private var columns = 1
    private var tileWidth: CGFloat = 180
    private var frames: [NSRect] = []
    private var headers: [(title: String, y: CGFloat)] = []
    private var contentHeight: CGFloat = 0

    private let theme = TableTheme()
    private let surface = NSColor(Theme.surface)
    private let fieldBorder = NSColor(Theme.fieldBorder)
    private let nameFont = NSFont.systemFont(ofSize: 11.5)
    private let folderFont = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
    private let badgeFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .URL])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Updates from SwiftUI

    func update(rows newRows: [ListRow], selection newSelection: Set<URL>, focusRequest newFocus: Int, tileSize newSize: CGFloat, config newConfig: Config) {
        config = newConfig
        let rowsChanged = !Self.same(rows, newRows)
        if rowsChanged {
            rows = newRows
            index = Dictionary(rows.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
            reachedEndAt = -1
        }
        if rowsChanged || newSize != tileSize {
            tileSize = newSize
            relayout()
            needsDisplay = true
        }
        updateFooter()
        let wanted = pendingSelection ?? newSelection
        if wanted != selection { setSelection(wanted, tell: false) }
        if let focusRequest, focusRequest != newFocus { window?.makeFirstResponder(self) }
        focusRequest = newFocus
        if rowsChanged { checkReachedEnd() }
        #if DEBUG
        RowGeometry.providers[ObjectIdentifier(self)] = { [weak self] in self?.debugFrames() ?? [] }
        #endif
    }

    private static func same(_ a: [ListRow], _ b: [ListRow]) -> Bool {
        guard a.count == b.count else { return false }
        if a.withUnsafeBufferPointer({ pa in b.withUnsafeBufferPointer { pa.baseAddress == $0.baseAddress } }) { return true }
        for (x, y) in zip(a, b) where x.id != y.id || x.group != y.group || x.item != y.item { return false }
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        if config.isActivePane && !(window.firstResponder is NSText) { window.makeFirstResponder(self) }
    }

    override func becomeFirstResponder() -> Bool {
        config.activatePane?()
        redrawSelected()
        return true
    }

    override func resignFirstResponder() -> Bool {
        redrawSelected()
        return true
    }

    private var isFocused: Bool { window?.firstResponder === self }

    // MARK: Layout

    func fit(width: CGFloat, height: CGFloat) {
        if abs(width - frame.width) > 0.5 {
            setFrameSize(NSSize(width: width, height: frame.height))
            relayout()
            needsDisplay = true
        }
        let size = NSSize(width: width, height: max(contentHeight, height))
        if frame.size != size { setFrameSize(size) }
    }

    private func relayout() {
        let width = bounds.width
        let available = max(tileSize, width - Self.padding * 2)
        columns = max(1, Int((available + Self.spacing) / (tileSize + Self.spacing)))
        tileWidth = floor((available - CGFloat(columns - 1) * Self.spacing) / CGFloat(columns))
        let pitch = tileWidth + 6 + Self.nameHeight
        var y = Self.padding
        var column = 0
        frames = []
        headers = []
        frames.reserveCapacity(rows.count)
        for (position, row) in rows.enumerated() {
            if let group = row.group {
                // A new group starts a new line, with its header above.
                if position > 0 {
                    if column > 0 { y += pitch + Self.spacing }
                    column = 0
                }
                headers.append((group, y))
                y += Self.headerHeight
            }
            frames.append(NSRect(x: Self.padding + CGFloat(column) * (tileWidth + Self.spacing), y: y, width: tileWidth, height: tileWidth))
            column += 1
            if column == columns {
                column = 0
                y += pitch + Self.spacing
            }
        }
        if column > 0 { y += pitch + Self.spacing }
        let footerHeight = footerHost.map { _ in footerHostHeight } ?? 0
        footerHost?.frame = NSRect(x: 0, y: y, width: width, height: footerHeight)
        contentHeight = y - Self.spacing + Self.padding + footerHeight
        let height = max(contentHeight, superview?.bounds.height ?? 0)
        if abs(frame.height - height) > 0.5 { setFrameSize(NSSize(width: width, height: height)) }
    }

    private var footerHostHeight: CGFloat { footerHost.map { ceil($0.fittingSize.height) } ?? 0 }

    private func updateFooter() {
        if let footer = config.footer, !rows.isEmpty {
            if let footerHost {
                footerHost.rootView = footer
            } else {
                let host = NSHostingView(rootView: footer)
                addSubview(host)
                footerHost = host
                relayout()
            }
        } else if footerHost != nil {
            footerHost?.removeFromSuperview()
            footerHost = nil
            relayout()
        }
    }

    private func tile(at point: NSPoint) -> Int? {
        // Tiles are in order down the grid; the ones near the point are checked.
        frames.indices.first { index in
            let frame = frames[index]
            return point.y >= frame.minY && point.y <= frame.maxY + 6 + Self.nameHeight && point.x >= frame.minX && point.x <= frame.maxX
        }
    }

    private func tileRect(_ index: Int) -> NSRect {
        guard frames.indices.contains(index) else { return .zero }
        let frame = frames[index]
        return NSRect(x: frame.minX - 2, y: frame.minY - 2, width: frame.width + 4, height: frame.height + 6 + Self.nameHeight + 4)
    }

    private func redraw(_ index: Int?) {
        if let index { setNeedsDisplay(tileRect(index)) }
    }

    private func redrawSelected() {
        for url in selection { redraw(index[url]) }
    }

    // MARK: Drawing

    private var side: Int { Thumbnails.step(tileWidth * 2) }

    override func draw(_ dirtyRect: NSRect) {
        for header in headers where header.y + Self.headerHeight >= dirtyRect.minY && header.y <= dirtyRect.maxY {
            let text = NSAttributedString(string: header.title.uppercased(), attributes: [
                .font: theme.caption, .foregroundColor: theme.textTertiary, .kern: 0.8,
            ])
            let size = text.size()
            text.draw(at: NSPoint(x: Self.padding + 2, y: header.y + 14))
            theme.border.setFill()
            NSRect(x: Self.padding + 2 + size.width + 8, y: header.y + 14 + size.height / 2, width: bounds.width - Self.padding * 2 - size.width - 12, height: 1).fill()
        }
        let side = side
        for (position, frame) in frames.enumerated() where tileRect(position).intersects(dirtyRect) {
            drawTile(rows[position], index: position, in: frame, side: side)
        }
        if dropTargeted {
            let ring = NSBezierPath(roundedRect: visibleRect.insetBy(dx: 6.75, dy: 6.75), xRadius: 8, yRadius: 8)
            ring.lineWidth = 1.5
            ring.setLineDash([6, 4], count: 2, phase: 0)
            theme.accent.withAlphaComponent(0.55).setStroke()
            ring.stroke()
        }
    }

    private func drawTile(_ row: ListRow, index position: Int, in frame: NSRect, side: Int) {
        let item = row.item
        let isSelected = selection.contains(row.id)
        let isHovered = hovered == position || HoverPreview.on
        let shape = NSBezierPath(roundedRect: frame, xRadius: 8, yRadius: 8)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        surface.setFill()
        frame.fill()
        let entry = item.isFolder ? nil : Thumbnails.cached(item, side: side)
        if let image = entry?.image {
            // Cropped to a square, like Photos.
            let width = CGFloat(image.width), height = CGFloat(image.height)
            let crop = min(width, height)
            let source = NSRect(x: (width - crop) / 2, y: (height - crop) / 2, width: crop, height: crop)
            NSImage(cgImage: image, size: NSSize(width: width, height: height))
                .draw(in: frame, from: source, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        } else if item.isFolder {
            let glyph = theme.symbol("folder.fill", size: tileWidth * 0.32, weight: .regular, color: theme.accent.withAlphaComponent(0.85))
            glyph.draw(in: NSRect(x: frame.midX - glyph.size.width / 2, y: frame.midY - glyph.size.height / 2, width: glyph.size.width, height: glyph.size.height))
        } else {
            let icon = FileIcons.icon(for: item)
            let size = tileWidth * 0.42
            icon.draw(in: NSRect(x: frame.midX - size / 2, y: frame.midY - size / 2, width: size, height: size),
                      from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            load(item, side: side, index: position)
        }
        if isHovered && !isSelected {
            NSColor.white.withAlphaComponent(0.04).setFill()
            frame.fill(using: .sourceOver)
        }
        if Thumbnails.isVideo(item) { drawBadge(duration: entry?.duration, in: frame) }
        NSGraphicsContext.restoreGraphicsState()
        let lineWidth: CGFloat = isSelected ? 2.5 : 1
        let ring = NSBezierPath(roundedRect: frame.insetBy(dx: lineWidth / 2, dy: lineWidth / 2), xRadius: 8 - lineWidth / 2, yRadius: 8 - lineWidth / 2)
        ring.lineWidth = lineWidth
        (isSelected ? theme.accent : (isHovered ? fieldBorder : theme.border)).setStroke()
        ring.stroke()

        // The name, on a chip while selected.
        let font = item.isFolder ? folderFont : nameFont
        let color = isSelected ? theme.text : theme.textSecondary
        let fitted = TextLines.shared.line(item.name, font: font, color: color, fitting: tileWidth - 12, truncation: .byTruncatingMiddle)
        let chipWidth = min(tileWidth, ceil(fitted.width) + 12)
        let chip = NSRect(x: frame.midX - chipWidth / 2, y: frame.maxY + 6, width: chipWidth, height: Self.nameHeight)
        if isSelected {
            (isFocused ? theme.accentSoft : theme.accentSoft.withAlphaComponent(0.6)).setFill()
            NSBezierPath(roundedRect: chip, xRadius: 4, yRadius: 4).fill()
        }
        FileCellView.drawText(item.name, font: font, color: color, x: chip.minX + 6, midY: chip.midY, width: chip.width - 12,
                              truncation: .byTruncatingMiddle)
    }

    private func drawBadge(duration: Double?, in frame: NSRect) {
        let play = theme.symbol("play.fill", size: 7.5, weight: .bold, color: .white)
        let text = duration.map { Thumbnails.durationText($0) }
        let textWidth = text.map { ceil(TextLines.shared.line($0, font: badgeFont, color: .white).width) + 3 } ?? 0
        let width = 6 + play.size.width + textWidth + 6
        let badge = NSRect(x: frame.maxX - 6 - width, y: frame.maxY - 6 - 18, width: width, height: 18)
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 9, yRadius: 9).fill()
        play.draw(in: NSRect(x: badge.minX + 6, y: badge.midY - play.size.height / 2, width: play.size.width, height: play.size.height))
        if let text {
            FileCellView.drawText(text, font: badgeFont, color: .white, x: badge.minX + 6 + play.size.width + 3, midY: badge.midY, width: textWidth)
        }
    }

    /// A tile on screen without its picture yet: made off the main thread, then drawn.
    private func load(_ item: FileItem, side: Int, index position: Int) {
        let key = "\(side)|\(item.url.absoluteString)"
        guard !loading.contains(key) else { return }
        loading.insert(key)
        Task { [weak self] in
            let entry = await Thumbnails.load(item, side: side)
            guard let self else { return }
            self.loading.remove(key)
            guard entry.image != nil || entry.duration != nil, let now = self.index[item.url] else { return }
            self.redraw(now)
        }
    }

    func scrolled() {
        checkReachedEnd()
    }

    private func checkReachedEnd() {
        guard let onReachEnd = config.onReachEnd, !rows.isEmpty, reachedEndAt != rows.count, let last = frames.last else { return }
        guard visibleRect.maxY >= last.minY else { return }
        reachedEndAt = rows.count
        DispatchQueue.main.async { onReachEnd() }
    }

    // MARK: Selection

    /// Shows a selection, and (unless it came from SwiftUI) tells SwiftUI on the next turn,
    /// once the highlight is on screen.
    private func setSelection(_ urls: Set<URL>, tell: Bool) {
        let changed = selection.symmetricDifference(urls)
        selection = urls
        for url in changed { redraw(index[url]) }
        guard tell else { return }
        displayIfNeeded()
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

    private func reveal(_ url: URL) {
        guard let position = index[url] else { return }
        scrollToVisible(tileRect(position).insetBy(dx: 0, dy: -Self.spacing))
    }

    private func range(from a: URL, to b: URL) -> [URL]? {
        guard let i = index[a], let j = index[b] else { return nil }
        return rows[min(i, j)...max(i, j)].map(\.id)
    }

    private func click(_ url: URL, flags: NSEvent.ModifierFlags) {
        var next = selection
        if flags.contains(.command) {
            if next.contains(url) { next.remove(url) } else { next.insert(url) }
            anchor = url
        } else if flags.contains(.shift), let anchor, let range = range(from: anchor, to: url) {
            next = Set(range)
        } else {
            next = [url]
            anchor = url
        }
        cursor = url
        setSelection(next, tell: true)
    }

    private func move(_ delta: Int, extend: Bool) {
        guard !rows.isEmpty else { return }
        let current = cursor.flatMap { index[$0] } ?? rows.firstIndex { selection.contains($0.id) }
        let next = current.map { min(max(0, $0 + delta), rows.count - 1) } ?? (delta > 0 ? 0 : rows.count - 1)
        let url = rows[next].id
        if extend, let anchor, let range = range(from: anchor, to: url) {
            setSelection(Set(range), tell: true)
        } else {
            anchor = url
            setSelection([url], tell: true)
        }
        cursor = url
        reveal(url)
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        let shift = event.modifierFlags.contains(.shift)
        switch Int(event.keyCode) {
        case 123: move(-1, extend: shift)
        case 124: move(1, extend: shift)
        case 126: move(-columns, extend: shift)
        case 125: move(columns, extend: shift)
        case 36, 76:
            if !selection.isEmpty { config.onOpen(selection, false) } else { super.keyDown(with: event) }
        case 49: config.onQuickLook(selection, rows)
        case 53:
            if !selection.isEmpty { setSelection([], tell: true) } else { super.keyDown(with: event) }
        case 48:
            if let switchPane = config.switchPane { switchPane() } else { super.keyDown(with: event) }
        default: super.keyDown(with: event)
        }
    }

    override func magnify(with event: NSEvent) {
        let range = Prefs.galleryTileSizes
        let size = min(range.upperBound, max(range.lowerBound, Prefs.shared.galleryTileSize * (1 + event.magnification)))
        if abs(size - Prefs.shared.galleryTileSize) >= 1 { Prefs.shared.galleryTileSize = size }
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        let position = tile(at: convert(event.locationInWindow, from: nil))
        guard position != hovered else { return }
        redraw(hovered)
        redraw(position)
        hovered = position
        if let position, rows[position].item.isFolder { ListingCache.shared.readAhead(rows[position].id, .pointer) }
    }

    override func mouseExited(with event: NSEvent) {
        redraw(hovered)
        hovered = nil
    }

    override func mouseDown(with event: NSEvent) {
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        let point = convert(event.locationInWindow, from: nil)
        guard let position = tile(at: point) else {
            pressed = nil
            setSelection([], tell: true)
            return
        }
        let url = rows[position].id
        if event.clickCount == 2 {
            config.onOpen([url], event.modifierFlags.contains(.command))
            return
        }
        pressed = (position, point)
        // A press on a selected tile keeps the selection, so the whole of it can be dragged.
        if !selection.contains(url) || event.modifierFlags.contains(.command) || event.modifierFlags.contains(.shift) {
            click(url, flags: event.modifierFlags)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressed, let position = pressed.index else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - pressed.at.x, point.y - pressed.at.y) > 3 else { return }
        self.pressed = nil
        let url = rows[position].id
        let dragged = selection.contains(url) ? rows.filter { selection.contains($0.id) } : [rows[position]]
        let items = dragged.compactMap { row -> NSDraggingItem? in
            guard let place = index[row.id] else { return nil }
            let writer: NSPasteboardWriting = RemoteFilePromise(row.id) ?? row.id as NSURL
            let item = NSDraggingItem(pasteboardWriter: writer)
            let rect = frames[place]
            item.setDraggingFrame(rect, contents: snapshot(of: rect))
            return item
        }
        guard !items.isEmpty else { return }
        beginDraggingSession(with: items, event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        // A click (not a drag) on a tile that was already selected selects just that tile.
        if let pressed, let position = pressed.index, event.modifierFlags.intersection([.command, .shift]).isEmpty {
            let url = rows[position].id
            if selection != [url] {
                anchor = url
                cursor = url
                setSelection([url], tell: true)
            }
        }
        pressed = nil
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let position = tile(at: convert(event.locationInWindow, from: nil)) else { return config.backgroundMenu() }
        let url = rows[position].id
        return config.rowMenu(selection.contains(url) ? selection : [url], rows)
    }

    private func snapshot(of rect: NSRect) -> NSImage {
        guard let bitmap = bitmapImageRepForCachingDisplay(in: rect) else { return NSImage() }
        cacheDisplay(in: rect, to: bitmap)
        let image = NSImage(size: rect.size)
        image.addRepresentation(bitmap)
        return image
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .move, .link, .generic] : [.move, .copy, .generic]
    }

    // MARK: Dropping in

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard config.onDropBackground != nil, sender.draggingSource as? GalleryGridView !== self else { return [] }
        if !dropTargeted {
            dropTargeted = true
            needsDisplay = true
        }
        return NSEvent.modifierFlags.contains(.option) ? .copy : .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { endDrop() }
    override func draggingEnded(_ sender: NSDraggingInfo) { endDrop() }

    private func endDrop() {
        guard dropTargeted else { return }
        dropTargeted = false
        needsDisplay = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { endDrop() }
        let urls = FileTableController.urls(from: sender.draggingPasteboard)
        guard !urls.isEmpty, let onDrop = config.onDropBackground else { return false }
        return onDrop(urls)
    }

    // MARK: Scripted runs

    #if DEBUG
    private func debugFrames() -> [(URL, CGRect, Int)] {
        guard let window, let content = window.contentView else { return [] }
        let visible = visibleRect
        return frames.indices.compactMap { position in
            let frame = frames[position]
            guard frame.intersects(visible) else { return nil }
            let rect = convert(frame, to: nil)
            return (rows[position].id, CGRect(x: rect.minX, y: content.bounds.height - rect.maxY, width: rect.width, height: rect.height), 0)
        }
    }
    #endif
}
