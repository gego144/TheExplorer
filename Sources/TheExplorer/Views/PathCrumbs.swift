import AppKit
import SwiftUI

/// The folder's path as chips, "~ / Dev / jestr", drawn by AppKit. Click a chip to go there,
/// drop files on one to move them in, right-click for its menu. When the path doesn't fit, the
/// middle folders fold into a "…" chip that lists them.
///
/// SwiftUI laid out the path up to four ways (whole, then keeping fewer folders) to find one
/// that fit, every time you changed folder; here the chips' widths are measured once and the
/// fit is picked by adding them up.
struct PathCrumbs: NSViewRepresentable {
    let trail: [URL]
    let model: BrowserModel
    let openTab: (URL) -> Void

    func makeNSView(context: Context) -> PathCrumbsView { PathCrumbsView() }

    func updateNSView(_ view: PathCrumbsView, context: Context) {
        view.model = model
        view.openTab = openTab
        if view.trail != trail { view.trail = trail }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PathCrumbsView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.idealWidth, height: Theme.smallControlHeight)
    }
}

final class PathCrumbsView: NSView {
    weak var model: BrowserModel?
    var openTab: (URL) -> Void = { _ in }
    var trail: [URL] = [] {
        didSet {
            measured = trail.map { measure(title(for: $0), current: $0 == trail.last) }
            needsLayout = true
            needsDisplay = true
        }
    }

    /// One thing drawn in a row: a folder's chip, the "…" fold, or a "/" between them.
    private enum Part {
        case folder(Int)
        case fold([URL])
        case slash
    }

    private var measured: [CGFloat] = []
    private var parts: [(part: Part, rect: NSRect)] = []
    private var hovered: Int?
    private var pressed: Int?
    private var dropTarget: Int?
    private var tracking: NSTrackingArea?

    private static let spacing: CGFloat = 2
    private static let padding: CGFloat = 6
    private let font = NSFont.systemFont(ofSize: 12.5)
    private let boldFont = NSFont.systemFont(ofSize: 12.5, weight: .medium)
    private let slashFont = NSFont.systemFont(ofSize: 12)
    private lazy var colors = Colors()

    /// Parents a clear step under the folder you're in, which sits on a raised fill like the
    /// selected tab; a crumb you point at gets a fill you can see.
    private struct Colors {
        let text = NSColor(Theme.text)
        let secondary = NSColor(Theme.textSecondary).blended(withFraction: 0.4, of: NSColor(Theme.text)) ?? NSColor(Theme.textSecondary)
        let slash = NSColor(Theme.textTertiary)
        let raised = NSColor(Theme.raised)
        let hover = NSColor(Theme.colors.raisedHover)
        let pressed = NSColor(Theme.colors.pressedFill)
        let accent = NSColor(Theme.accent).withAlphaComponent(0.7)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .URL])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The whole path's width, for when SwiftUI asks without a width in mind.
    var idealWidth: CGFloat { layoutParts(keepLast: trail.count).width }

    private func title(for url: URL) -> String {
        if url.path == URL.home.standardizedFileURL.path { return "~" }
        if url.isRoot { return Format.displayName("/") }
        return url.lastPathComponent
    }

    private func measure(_ title: String, current: Bool) -> CGFloat {
        ceil(TextLines.shared.line(title, font: current ? boldFont : font, color: colors.text).width) + Self.padding * 2
    }

    private lazy var slashWidth: CGFloat = ceil(TextLines.shared.line("›", font: slashFont, color: colors.slash).width)
    private var foldWidth: CGFloat { measure("…", current: false) }

    /// The path keeping the root and the last `keepLast` folders, the rest folded into "…".
    private func layoutParts(keepLast: Int) -> (parts: [(Part, NSRect)], width: CGFloat) {
        guard !trail.isEmpty else { return ([], 0) }
        let folding = keepLast < trail.count - 1
        let hidden = folding ? Array(trail[1..<(trail.count - keepLast)]) : []
        let visible = folding ? [0] + Array((trail.count - keepLast)..<trail.count) : Array(trail.indices)
        var parts: [(Part, NSRect)] = []
        var x: CGFloat = 0
        let height = bounds.height > 0 ? bounds.height : Theme.smallControlHeight
        func add(_ part: Part, width: CGFloat) {
            if !parts.isEmpty { x += Self.spacing }
            parts.append((part, NSRect(x: x, y: 0, width: width, height: height)))
            x += width
        }
        for (position, index) in visible.enumerated() {
            if position > 0 { add(.slash, width: slashWidth) }
            if position == 1 && !hidden.isEmpty {
                add(.fold(hidden), width: foldWidth)
                add(.slash, width: slashWidth)
            }
            add(.folder(index), width: measured.indices.contains(index) ? measured[index] : 0)
        }
        return (parts, x)
    }

    override func layout() {
        super.layout()
        // The whole path if it fits; otherwise the root and the last three, two or one folders.
        let options = [trail.count] + [3, 2, 1].filter { $0 < trail.count - 1 }
        var chosen = layoutParts(keepLast: options.last ?? trail.count)
        for keep in options {
            let candidate = layoutParts(keepLast: keep)
            if candidate.width <= bounds.width {
                chosen = candidate
                break
            }
        }
        parts = chosen.parts.map { (part: $0.0, rect: $0.1) }
        updateToolTips()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        for (index, entry) in parts.enumerated() {
            let rect = entry.rect
            switch entry.part {
            case .slash:
                draw("›", font: slashFont, color: colors.slash, in: rect)
            case .fold:
                drawChip(index: index, rect: rect, current: false)
                draw("…", font: font, color: hovered == index ? colors.text : colors.secondary, in: rect)
            case .folder(let folder):
                let current = folder == trail.count - 1
                drawChip(index: index, rect: rect, current: current)
                let color = current || hovered == index || dropTarget == index ? colors.text : colors.secondary
                draw(title(for: trail[folder]), font: current ? boldFont : font, color: color, in: rect)
            }
        }
    }

    private func drawChip(index: Int, rect: NSRect, current: Bool) {
        let fill: NSColor? = pressed == index ? colors.pressed
            : (hovered == index || dropTarget == index ? colors.hover : (current ? colors.raised : nil))
        let shape = NSBezierPath(roundedRect: rect, xRadius: Theme.chipRadius, yRadius: Theme.chipRadius)
        if let fill {
            fill.setFill()
            shape.fill()
        }
        if dropTarget == index {
            let ring = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: Theme.chipRadius, yRadius: Theme.chipRadius)
            ring.setLineDash([3, 2], count: 2, phase: 0)
            ring.lineWidth = 1
            colors.accent.setStroke()
            ring.stroke()
        }
    }

    private func draw(_ text: String, font: NSFont, color: NSColor, in rect: NSRect) {
        FileCellView.drawText(text, font: font, color: color, x: rect.minX, midY: rect.midY, width: rect.width, alignment: .center)
    }

    // MARK: Mouse

    private func part(at point: NSPoint) -> Int? {
        parts.firstIndex { entry in
            if case .slash = entry.part { return false }
            return entry.rect.contains(point)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        let index = part(at: convert(event.locationInWindow, from: nil))
        if index != hovered {
            hovered = index
            needsDisplay = true
            if let index, case .folder(let folder) = parts[index].part { ListingCache.shared.readAhead(trail[folder], .pointer) }
        }
        (index != nil ? NSCursor.pointingHand : NSCursor.arrow).set()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        needsDisplay = true
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        guard let index = part(at: convert(event.locationInWindow, from: nil)) else {
            super.mouseDown(with: event)
            return
        }
        if case .fold(let hidden) = parts[index].part {
            showFoldMenu(hidden, below: parts[index].rect)
            return
        }
        pressed = index
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            pressed = nil
            needsDisplay = true
        }
        guard let pressed, part(at: convert(event.locationInWindow, from: nil)) == pressed,
              case .folder(let folder) = parts[pressed].part else { return }
        model?.navigate(to: trail[folder])
    }

    private func showFoldMenu(_ hidden: [URL], below rect: NSRect) {
        let menu = NSMenu()
        for folder in hidden {
            menu.addItem(ActionMenuItem(folder.lastPathComponent) { [weak self] in self?.model?.navigate(to: folder) })
        }
        menu.popUp(positioning: nil, at: NSPoint(x: rect.minX, y: rect.maxY + 4), in: self)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let index = part(at: convert(event.locationInWindow, from: nil)), case .folder(let folder) = parts[index].part else { return nil }
        let url = trail[folder]
        let menu = NSMenu()
        menu.addItem(ActionMenuItem("Open in New Tab") { [weak self] in self?.openTab(url) })
        menu.addItem(ActionMenuItem(FileActions.openInTerminalTitle) { FileActions.openInTerminal(url) })
        menu.addItem(ActionMenuItem("Copy Path") { FileActions.copyPaths([url]) })
        menu.addItem(ActionMenuItem(FileActions.revealTitle) { FileActions.revealInFinder([url]) })
        menu.addItem(ActionMenuItem(FavoritesStore.shared.contains(url) ? "Unpin" : "Pin to Sidebar") { FavoritesStore.shared.toggle(url) })
        return menu
    }

    private func updateToolTips() {
        removeAllToolTips()
        for entry in parts {
            switch entry.part {
            case .folder(let folder): addToolTip(entry.rect, owner: Format.path(trail[folder].path) as NSString, userData: nil)
            case .fold(let hidden): addToolTip(entry.rect, owner: hidden.map(\.lastPathComponent).joined(separator: " / ") as NSString, userData: nil)
            case .slash: break
            }
        }
    }

    // MARK: Dropping

    private func folderIndex(at sender: NSDraggingInfo) -> Int? {
        guard let index = part(at: convert(sender.draggingLocation, from: nil)), case .folder = parts[index].part else { return nil }
        return index
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let index = folderIndex(at: sender)
        if index != dropTarget {
            dropTarget = index
            needsDisplay = true
        }
        guard index != nil else { return [] }
        return NSEvent.modifierFlags.contains(.option) ? .copy : .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropTarget = nil
        needsDisplay = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer {
            dropTarget = nil
            needsDisplay = true
        }
        guard let index = folderIndex(at: sender), case .folder(let folder) = parts[index].part, let model else { return false }
        let urls = FileTableController.urls(from: sender.draggingPasteboard)
        return !urls.isEmpty && model.receiveDrop(urls, into: trail[folder])
    }
}

/// A menu item that runs a closure.
final class ActionMenuItem: NSMenuItem {
    private let run: () -> Void

    init(_ title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(runAction), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func runAction() { run() }
}

/// S3's and Google Drive's paths, as chips that fold like the local path's: when they don't
/// fit, the middle folders go into a "…" menu, keeping the first and as many of the last as
/// fit, and at the narrowest just "…" and the current folder, cut short. They never run past
/// their row (over Back, or into the other pane's path).
struct FoldingCrumbs<Chip: View>: View {
    let titles: [String]
    let open: (Int) -> Void
    /// What follows the path, after a "/" ("Search “receipts”").
    var suffix: String?
    @ViewBuilder let chip: (Int) -> Chip

    private enum Part: Hashable {
        case step(Int)
        case fold([Int])
    }

    /// From the whole path to the shortest, the first that fits is shown.
    private var variants: [[Part]] {
        let count = titles.count
        guard count > 2 else { return [(0..<count).map(Part.step)] }
        var variants: [[Part]] = [(0..<count).map(Part.step)]
        for kept in stride(from: count - 2, through: 1, by: -1) {
            variants.append([.step(0), .fold(Array(1..<(count - kept)))] + ((count - kept)..<count).map(Part.step))
        }
        return variants
    }

    private var narrowest: [Part] {
        let count = titles.count
        return count > 1 ? [.fold(Array(0..<(count - 1))), .step(count - 1)] : (0..<count).map(Part.step)
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(Array(variants.enumerated()), id: \.offset) { _, parts in
                row(parts).fixedSize()
            }
            row(narrowest)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ parts: [Part]) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                if index > 0 { slash }
                switch part {
                case .step(let step): chip(step)
                case .fold(let hidden): fold(hidden)
                }
            }
            if let suffix {
                slash
                Text(suffix)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
            }
        }
    }

    private var slash: some View { Text("/").foregroundStyle(Theme.textTertiary) }

    private func fold(_ hidden: [Int]) -> some View {
        Menu {
            ForEach(hidden, id: \.self) { step in
                Button(titles[step]) { open(step) }
            }
        } label: {
            Text("…")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(CrumbStyle(isCurrent: false))
        .fixedSize()
        .help(hidden.map { titles[$0] }.joined(separator: " / "))
    }
}
