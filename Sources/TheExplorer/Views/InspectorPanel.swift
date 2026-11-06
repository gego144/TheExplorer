import AppKit
import Observation
import QuickLookThumbnailing
import SwiftUI

/// The inspector column. One file or folder (what you see while browsing) is a card drawn by
/// AppKit; previews inside it, several selected items, and S3 and Drive stay SwiftUI.
///
/// The SwiftUI card was laid out again on every selection change, ~9ms each time an arrow key
/// moved the selection.
final class InspectorPanel: NSView {
    private let workspace: Workspace
    private let values: RegionValues
    private let scroll = NSScrollView()
    private let card: ItemCardView
    /// Several selected items, S3 and Drive.
    private var swiftUI: RegionHostingView?
    private var generation = 0

    init(workspace: Workspace, values: RegionValues) {
        self.workspace = workspace
        self.values = values
        card = ItemCardView(values: values)
        super.init(frame: .zero)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.documentView = card
        addSubview(scroll)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private enum Mode: Equatable {
        case item(FileItem, isCurrentFolder: Bool)
        case swiftUI
        case nothing
    }

    private var mode = Mode.nothing

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
        let mode = Self.mode(of: model)
        switch mode {
        case .item(let item, let isCurrentFolder):
            card.show(item, isCurrentFolder: isCurrentFolder, model: model)
            setSwiftUI(nil)
        case .swiftUI:
            card.show(nil, isCurrentFolder: false, model: model)
            setSwiftUI(model)
        case .nothing:
            card.show(nil, isCurrentFolder: false, model: model)
            setSwiftUI(nil)
        }
        if mode != self.mode {
            self.mode = mode
            needsLayout = true
        }
    }

    private static func mode(of model: BrowserModel) -> Mode {
        if model.destination == .s3 || model.destination == .drive { return .swiftUI }
        let urls = model.activeSelection
        if urls.count > 1 { return .swiftUI }
        let browsing = model.destination == .folder && !model.isSearching
        guard let url = urls.first ?? (browsing ? model.currentURL : nil) else { return .nothing }
        let isCurrentFolder = urls.isEmpty
        // What the folder's listing already read, or failing that (search results, Recents),
        // the disk. While a folder you just went to is listed, the old rows stay up and so do
        // their folder's details, for the frame or two until both change together.
        if browsing {
            if isCurrentFolder, let folder = model.folderItem, folder.url == url || model.isLoading {
                return .item(folder, isCurrentFolder: true)
            }
            if !isCurrentFolder, let item = model.listedItem(url) { return .item(item, isCurrentFolder: false) }
        }
        return FileItem(url: url).map { .item($0, isCurrentFolder: isCurrentFolder) } ?? .nothing
    }

    private weak var swiftUIModel: BrowserModel?

    private func setSwiftUI(_ model: BrowserModel?) {
        guard let model else {
            swiftUI?.removeFromSuperview()
            swiftUI = nil
            swiftUIModel = nil
            return
        }
        guard swiftUI == nil || swiftUIModel !== model else { return }
        swiftUIModel = model
        let root = AnyView(InspectorColumn(model: model).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .modifier(RegionStyle(values: values)))
        if let swiftUI {
            swiftUI.rootView = root
        } else {
            let view = RegionHostingView(rootView: root)
            addSubview(view)
            swiftUI = view
            needsLayout = true
        }
    }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        scroll.isHidden = swiftUI != nil
        swiftUI?.frame = bounds
        card.fit(width: bounds.width, height: bounds.height)
    }
}

// MARK: - The card

/// One file's or folder's details: a thumbnail, its name and type, Pin/Open/Reveal, a large
/// preview for documents, media details, sizes and dates, and its path.
private final class ItemCardView: NSView {
    private let values: RegionValues
    private let theme = TableTheme()
    private let surface = NSColor(Theme.surface)
    private let raised = NSColor(Theme.raised)
    private let warning = NSColor(Theme.warning)
    private let labelFont = NSFont.systemFont(ofSize: 11.5)
    private let valueFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    private let emphasizedFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .semibold)
    private let sizeFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
    private let summaryFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
    private let kindFont = NSFont.systemFont(ofSize: 11)
    private let captionFont = NSFont.systemFont(ofSize: 9.5, weight: .semibold)
    private let warningFont = NSFont.systemFont(ofSize: 10.5)
    private let chipFont: NSFont = {
        let base = NSFont.systemFont(ofSize: 9, weight: .bold)
        return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 9) } ?? base
    }()

    private let name = NSTextField(wrappingLabelWithString: "")
    private let path = NSTextField(wrappingLabelWithString: "")
    private let pin: SubtleButton
    private let open: SubtleButton
    private let reveal: SubtleButton
    private let copyPath: SubtleButton
    private let recalculate: BarButton
    private let spinner = NSProgressIndicator()
    private var preview: PreviewHost?

    private weak var model: BrowserModel?
    private var item: FileItem?
    private var isCurrentFolder = false
    private var media: MediaInfo?
    private var lastOpened: Date?
    private var thumbnail: NSImage?
    private var loads: Task<Void, Never>?

    /// What's drawn, worked out in `layoutCard`.
    private var card = NSRect.zero
    private var header = NSRect.zero
    private var dividers: [CGFloat] = []
    private var rows: [(label: String, value: String, emphasized: Bool, y: CGFloat)] = []
    private var folderSize: (text: String?, y: CGFloat)?
    private var warningY: CGFloat?
    private var captionY: CGFloat = 0
    private var chipRect = NSRect.zero
    private var summaryY: CGFloat?

    private static let width: CGFloat = 272
    private static let padding: CGFloat = 14
    private var inner: CGFloat { Self.width - Self.padding * 2 }

    init(values: RegionValues) {
        self.values = values
        pin = SubtleButton("Pin", symbol: "pin", theme: theme)
        open = SubtleButton("Open", theme: theme)
        reveal = SubtleButton("", symbol: "magnifyingglass", help: FileActions.revealTitle, theme: theme)
        copyPath = SubtleButton("Copy Path", theme: theme)
        recalculate = BarButton("arrow.clockwise", style: .ghost, size: 9, weight: .bold, help: "Recalculate", theme: theme)
        super.init(frame: .zero)
        for (field, font, color) in [(name, NSFont.systemFont(ofSize: 13.5, weight: .semibold), theme.text),
                                     (path, NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), theme.textSecondary)] {
            field.font = font
            field.textColor = color
            field.isSelectable = true
            field.drawsBackground = false
            field.isBordered = false
        }
        name.maximumNumberOfLines = 3
        name.lineBreakMode = .byTruncatingTail
        pin.action = { [weak self] in
            guard let url = self?.item?.url else { return }
            FavoritesStore.shared.toggle(url)
        }
        open.action = { [weak self] in
            guard let self, let item = self.item else { return }
            self.model?.open(item)
        }
        reveal.action = { [weak self] in
            guard let url = self?.item?.url else { return }
            FileActions.revealInFinder([url])
        }
        copyPath.action = { [weak self] in
            guard let url = self?.item?.url else { return }
            FileActions.copyPaths([url])
        }
        recalculate.action = { [weak self] in
            guard let path = self?.item?.path else { return }
            FolderSizeStore.shared.request([path], force: true)
        }
        spinner.style = .spinning
        spinner.controlSize = .mini
        spinner.isDisplayedWhenStopped = false
        for view in [name, path, pin, open, reveal, copyPath, recalculate, spinner] as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        loads?.cancel()
    }

    override var isFlipped: Bool { true }

    // MARK: Showing an item

    func show(_ item: FileItem?, isCurrentFolder: Bool, model: BrowserModel) {
        self.model = model
        let isNew = item?.url != self.item?.url
        let changed = item != self.item || isCurrentFolder != self.isCurrentFolder
        self.item = item
        self.isCurrentFolder = isCurrentFolder
        isHidden = item == nil
        if isNew { started(item) }
        // Read under Observation (see InspectorPanel), so pinning and sizes landing redraw it.
        let pinned = item.map { FavoritesStore.shared.contains($0.url) } ?? false
        pin.title = pinned ? "Pinned" : "Pin"
        pin.symbol = pinned ? "pin.fill" : "pin"
        let size = item.flatMap { $0.isFolder ? FolderSizeStore.shared.size(for: $0.path) : nil }
        let sizeKey = size.map { "\($0.bytes)|\($0.files)|\($0.complete)" }
        if changed || sizeKey != shownSizeKey {
            shownSizeKey = sizeKey
            layoutCard()
        }
    }

    private var shownSizeKey: String?

    /// A new item: its thumbnail, last opened date and media details are read afresh.
    private func started(_ item: FileItem?) {
        loads?.cancel()
        media = nil
        lastOpened = nil
        thumbnail = nil
        FolderSizeStore.shared.show(item.map { $0.isFolder ? [$0.path] : [] } ?? [], by: self)
        updatePreview(item)
        guard let item else { return }
        loads = Task { [weak self] in
            let url = item.url
            let opened = await Task.detached(priority: .utility) {
                try? url.resourceValues(forKeys: [.contentAccessDateKey]).contentAccessDate
            }.value
            guard let self, !Task.isCancelled else { return }
            self.lastOpened = opened
            self.layoutCard()
            if !item.isFolder {
                let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 52, height: 52), scale: 2, representationTypes: .thumbnail)
                let image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
                guard !Task.isCancelled else { return }
                self.thumbnail = image
                self.setNeedsDisplay(self.header)
            }
            guard !item.isFolder || item.isPackage else { return }
            let media = await MediaInfoReader.read(url, type: item.contentType, modified: item.modified)
            guard !Task.isCancelled, media != nil else { return }
            self.media = media
            self.layoutCard()
        }
    }

    /// The large preview (documents, images, code…) or an archive's contents, which stay SwiftUI.
    private func updatePreview(_ item: FileItem?) {
        guard let item, let model, FilePreview.kind(for: item) != nil else {
            preview?.view.removeFromSuperview()
            preview = nil
            return
        }
        let root = AnyView(FilePreview(item: item, model: model).frame(width: inner).modifier(RegionStyle(values: values)))
        if let preview {
            preview.controller.rootView = root
        } else {
            let host = PreviewHost(rootView: root) { [weak self] in self?.layoutCard() }
            addSubview(host.view)
            preview = host
        }
    }

    // MARK: Layout

    func fit(width: CGFloat, height: CGFloat) {
        let size = NSSize(width: width, height: max(height, card.maxY + 10))
        if frame.size != size { setFrameSize(size) }
    }

    private func layoutCard() {
        guard let item else { return }
        let x = 14 + Self.padding
        var y = 10 + Self.padding
        let kind = FilePreview.kind(for: item)
        dividers = []
        rows = []
        folderSize = nil
        warningY = nil
        summaryY = nil

        // A large preview first.
        if let preview, kind?.isLarge == true {
            let height = preview.height
            preview.view.frame = NSRect(x: x, y: y, width: inner, height: height)
            y += height + 14
        }
        // The thumbnail, and beside it the name, type and media summary.
        let textX = x + 52 + 11
        let textWidth = x + inner - textX
        name.stringValue = item.name
        let nameHeight = ceil(name.sizeThatFits(NSSize(width: textWidth, height: 200)).height)
        name.frame = NSRect(x: textX - 2, y: y, width: textWidth + 4, height: nameHeight)
        var textY = y + nameHeight + 6
        let style = TypeChip.style(for: item)
        let chipColor = theme.color(for: style.color)
        let label = TextLines.shared.line(style.label, font: chipFont, color: chipColor)
        let chipHeight = ceil(TextLines.height(of: chipFont)) + 3
        chipRect = NSRect(x: textX, y: textY, width: max(34, ceil(label.width) + 10), height: chipHeight)
        textY += chipHeight
        if media?.summary != nil {
            textY += 6
            summaryY = textY
            textY += 15
        }
        header = NSRect(x: x, y: y, width: inner, height: max(52, textY - y))
        y = header.maxY + 14

        // Pin, Open, Reveal.
        var buttonX = x
        for (button, shown) in [(pin, true), (open, !isCurrentFolder), (reveal, true)] {
            button.isHidden = !shown
            guard shown else { continue }
            button.frame = NSRect(x: buttonX, y: y, width: button.width, height: Theme.smallControlHeight)
            buttonX += button.width + 6
        }
        y += Theme.smallControlHeight + 14

        // An archive's contents.
        if let preview, kind == .archive {
            dividers.append(y)
            y += 1 + 14
            let height = preview.height
            preview.view.frame = NSRect(x: x, y: y, width: inner, height: height)
            y += height + 14
        }
        // Media details.
        if let media, !media.rows.isEmpty {
            dividers.append(y)
            y += 1 + 14
            for row in media.rows {
                rows.append((row.label, row.value, false, y))
                y += 15 + 6
            }
            y += 14 - 6
        }
        // Sizes and dates.
        dividers.append(y)
        y += 1 + 14
        recalculate.isHidden = true
        spinner.stopAnimation(nil)
        if item.isFolder {
            let size = FolderSizeStore.shared.size(for: item.path)
            folderSize = (size.map { ($0.complete ? "" : "≥ ") + Format.bytes($0.bytes) }, y)
            if size != nil {
                recalculate.isHidden = false
                recalculate.frame = NSRect(x: x + inner - 15, y: y, width: 15, height: 15)
            } else {
                spinner.frame = NSRect(x: x + inner - 12, y: y + 1.5, width: 12, height: 12)
                spinner.startAnimation(nil)
            }
            y += 15 + 6
            if let size {
                rows.append(("files", size.files.formatted(), false, y))
                y += 15 + 6
                if !size.complete {
                    warningY = y
                    y += 14 + 6
                }
            }
        } else {
            if let bytes = item.fileSize {
                rows.append(("size", Format.bytes(bytes), true, y))
                y += 15 + 6
            }
            if let allocated = item.allocatedSize {
                rows.append(("on disk", Format.bytes(allocated), false, y))
                y += 15 + 6
            }
        }
        var dates = [("created", Format.compactDate(item.created)), ("changed", Format.compactDate(item.modified))]
        if let lastOpened { dates.append(("opened", Format.compactDate(lastOpened))) }
        if item.isSymlink, let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: item.path) {
            dates.append(("points to", Format.path(destination)))
        }
        for (label, value) in dates {
            rows.append((label, value, false, y))
            y += 15 + 6
        }
        y += 14 - 6

        // The path.
        dividers.append(y)
        y += 1 + 14
        captionY = y
        y += 12 + 6
        path.stringValue = Format.path(item.path)
        let pathHeight = ceil(path.sizeThatFits(NSSize(width: inner, height: 400)).height)
        path.frame = NSRect(x: x - 2, y: y, width: inner + 4, height: pathHeight)
        y += pathHeight + 6
        copyPath.frame = NSRect(x: x, y: y, width: copyPath.width, height: Theme.smallControlHeight)
        y += Theme.smallControlHeight + Self.padding

        card = NSRect(x: 14, y: 10, width: Self.width, height: y - 10)
        if let superview = superview { fit(width: superview.bounds.width, height: superview.bounds.height) }
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let item else { return }
        surface.setFill()
        NSBezierPath(roundedRect: card, xRadius: 10, yRadius: 10).fill()
        let x = card.minX + Self.padding

        // Thumbnail.
        let thumb = NSRect(x: header.minX, y: header.minY, width: 52, height: 52)
        let tile = NSBezierPath(roundedRect: thumb, xRadius: 10, yRadius: 10)
        (item.isFolder ? theme.accentSoft : raised).setFill()
        tile.fill()
        if item.isFolder {
            let glyph = theme.symbol("folder.fill", size: 52 * 0.42, weight: .regular, color: theme.accent)
            glyph.draw(in: TextLinesRect.centered(glyph.size, in: thumb))
        } else if let thumbnail {
            let inset = thumb.insetBy(dx: 4, dy: 4)
            let scale = min(inset.width / max(thumbnail.size.width, 1), inset.height / max(thumbnail.size.height, 1))
            let size = NSSize(width: thumbnail.size.width * scale, height: thumbnail.size.height * scale)
            thumbnail.draw(in: TextLinesRect.centered(size, in: inset), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else {
            let icon = Icons.icon(for: item)
            icon.draw(in: TextLinesRect.centered(NSSize(width: 52 * 0.7, height: 52 * 0.7), in: thumb), from: .zero, operation: .sourceOver,
                      fraction: 1, respectFlipped: true, hints: nil)
        }
        theme.border.setStroke()
        NSBezierPath(roundedRect: thumb.insetBy(dx: 0.5, dy: 0.5), xRadius: 9.5, yRadius: 9.5).stroke()

        // Type chip and kind; media summary.
        let style = TypeChip.style(for: item)
        let chipColor = theme.color(for: style.color)
        theme.chipFill(chipColor).setFill()
        NSBezierPath(roundedRect: chipRect, xRadius: 4, yRadius: 4).fill()
        FileCellView.drawText(style.label, font: chipFont, color: chipColor, x: chipRect.minX, midY: chipRect.midY,
                              width: chipRect.width, alignment: .center)
        let kindX = chipRect.maxX + 6
        FileCellView.drawText(isCurrentFolder ? "this folder" : item.kindDescription.lowercased(), font: kindFont, color: theme.textTertiary,
                              x: kindX, midY: chipRect.midY, width: card.maxX - Self.padding - kindX)
        if let summaryY, let summary = media?.summary {
            FileCellView.drawText(summary, font: summaryFont, color: theme.accent, x: chipRect.minX, midY: summaryY + 7.5,
                                  width: card.maxX - Self.padding - chipRect.minX)
        }

        theme.border.setFill()
        for y in dividers { NSRect(x: x, y: y, width: inner, height: 1).fill() }

        // Sizes and dates: label on the left, value on the right.
        if let (text, y) = folderSize {
            FileCellView.drawText("size", font: labelFont, color: theme.textTertiary, x: x, midY: y + 7.5, width: 80)
            if let text {
                FileCellView.drawText(text, font: sizeFont, color: theme.accent, x: x + 60, midY: y + 7.5, width: inner - 60 - 15 - 4, alignment: .right)
            }
        }
        for row in rows {
            FileCellView.drawText(row.label, font: labelFont, color: theme.textTertiary, x: x, midY: row.y + 7.5, width: 80)
            let labelWidth = ceil(TextLines.shared.line(row.label, font: labelFont, color: theme.textTertiary).width) + 10
            FileCellView.drawText(row.value, font: row.emphasized ? emphasizedFont : valueFont, color: row.emphasized ? theme.accent : theme.text,
                                  x: x + labelWidth, midY: row.y + 7.5, width: inner - labelWidth, alignment: .right, truncation: .byTruncatingMiddle)
        }
        if let warningY {
            FileCellView.drawText("Some subfolders couldn't be read.", font: warningFont, color: warning, x: x, midY: warningY + 7, width: inner)
        }
        let caption = NSAttributedString(string: "PATH", attributes: [.font: captionFont, .foregroundColor: theme.textTertiary, .kern: 0.8])
        caption.draw(at: NSPoint(x: x, y: captionY))
    }
}

private enum TextLinesRect {
    static func centered(_ size: NSSize, in rect: NSRect) -> NSRect {
        NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
    }
}

/// A SwiftUI preview inside the card, which says when its height changes.
private final class PreviewHost {
    let controller: NSHostingController<AnyView>
    var view: NSView { controller.view }
    private var observation: NSKeyValueObservation?

    init(rootView: AnyView, onResize: @escaping () -> Void) {
        controller = NSHostingController(rootView: rootView)
        controller.sizingOptions = [.preferredContentSize]
        observation = controller.observe(\.preferredContentSize, options: [.new]) { _, _ in
            DispatchQueue.main.async { onResize() }
        }
    }

    var height: CGFloat { ceil(max(controller.preferredContentSize.height, 0)) }
}
