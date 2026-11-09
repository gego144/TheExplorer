import AppKit
import Observation
import QuickLookThumbnailing
import SwiftUI

/// The inspector column. One file or folder (what you see while browsing) is drawn by
/// AppKit; previews inside it, several selected items, and S3 and Drive stay SwiftUI.
///
/// The SwiftUI card was laid out again on every selection change, ~9ms each time an arrow key
/// moved the selection.
final class InspectorPanel: NSView {
    private let workspace: Workspace
    private let values: RegionValues
    private let scroll = NSScrollView()
    private let edge = NSView()
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
        edge.wantsLayer = true
        edge.layer?.backgroundColor = NSColor(Theme.border).cgColor
        addSubview(edge)
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
        let content = NSRect(x: 1, y: 0, width: max(0, bounds.width - 1), height: bounds.height)
        edge.frame = NSRect(x: 0, y: 0, width: 1, height: bounds.height)
        scroll.frame = content
        scroll.isHidden = swiftUI != nil
        swiftUI?.frame = content
        card.fit(width: bounds.width, height: bounds.height)
    }
}

// MARK: - The card

/// One file's or folder's details, as a plain column in the window's own greys: a preview, the
/// name, one line of kind · size · state, a short list of facts, and Open, Copy path and more.
private final class ItemCardView: NSView {
    private let values: RegionValues
    private let theme = TableTheme()
    private let surface = NSColor(Theme.surface)
    private let warning = NSColor(Theme.warning)
    private let labelFont = NSFont.systemFont(ofSize: 12)
    private let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    private let subtitleFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    private let warningFont = NSFont.systemFont(ofSize: 11)

    private let name = NSTextField(wrappingLabelWithString: "")
    private let path = NSTextField(wrappingLabelWithString: "")
    private let open: SubtleButton
    private let copyPath: SubtleButton
    private let more: SubtleButton
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
    private var content = NSRect.zero
    private var previewBox: NSRect?
    private var subtitle: [(text: String, color: NSColor)] = []
    private var subtitleY: CGFloat = 0
    private var summaryY: CGFloat?
    private var rows: [(label: String, value: String, y: CGFloat)] = []
    private var folderSize: (text: String?, y: CGFloat)?
    private var warningY: CGFloat?
    private var whereY: CGFloat = 0

    private static let padding: CGFloat = 16
    private static let labelColumn: CGFloat = 84
    private var inner: CGFloat { max(0, bounds.width - Self.padding * 2) }

    init(values: RegionValues) {
        self.values = values
        open = SubtleButton("Open", theme: theme)
        copyPath = SubtleButton("Copy path", theme: theme)
        more = SubtleButton("", symbol: "ellipsis", help: "More", theme: theme)
        recalculate = BarButton("arrow.clockwise", style: .ghost, size: 9, weight: .bold, help: "Recalculate", theme: theme)
        super.init(frame: .zero)
        open.prominent = true
        for (field, font, color) in [(name, NSFont.systemFont(ofSize: 14, weight: .semibold), theme.text),
                                     (path, labelFont, theme.textSecondary)] {
            field.font = font
            field.textColor = color
            field.isSelectable = true
            field.drawsBackground = false
            field.isBordered = false
        }
        name.maximumNumberOfLines = 3
        name.lineBreakMode = .byTruncatingTail
        open.action = { [weak self] in
            guard let self, let item = self.item else { return }
            self.model?.open(item)
        }
        copyPath.action = { [weak self] in
            guard let url = self?.item?.url else { return }
            FileActions.copyPaths([url])
        }
        more.action = { [weak self] in self?.showMore() }
        recalculate.action = { [weak self] in
            guard let path = self?.item?.path else { return }
            FolderSizeStore.shared.request([path], force: true)
        }
        spinner.style = .spinning
        spinner.controlSize = .mini
        spinner.isDisplayedWhenStopped = false
        for view in [name, path, open, copyPath, more, recalculate, spinner] as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        loads?.cancel()
    }

    override var isFlipped: Bool { true }

    /// Pin, Show in Finder and Open in Terminal, under the ··· button.
    private func showMore() {
        guard let url = item?.url else { return }
        let menu = NSMenu()
        let pinned = FavoritesStore.shared.contains(url)
        menu.addItem(ActionMenuItem(pinned ? "Unpin from Sidebar" : "Pin to Sidebar") { FavoritesStore.shared.toggle(url) })
        menu.addItem(ActionMenuItem(FileActions.revealTitle) { FileActions.revealInFinder([url]) })
        let folder = item?.isFolder == true ? url : url.deletingLastPathComponent()
        menu.addItem(ActionMenuItem(FileActions.openInTerminalTitle) { FileActions.openInTerminal(folder) })
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.maxY + 4), in: more)
    }

    // MARK: Showing an item

    func show(_ item: FileItem?, isCurrentFolder: Bool, model: BrowserModel) {
        self.model = model
        let isNew = item?.url != self.item?.url
        let changed = item != self.item || isCurrentFolder != self.isCurrentFolder
        self.item = item
        self.isCurrentFolder = isCurrentFolder
        isHidden = item == nil
        if isNew { started(item) }
        // Read under Observation (see InspectorPanel), so sizes landing and git changes redraw it.
        let size = item.flatMap { $0.isFolder ? FolderSizeStore.shared.size(for: $0.path) : nil }
        let mark = item.flatMap { model.git?.snapshot?.mark(for: $0.url.standardizedFileURL.path) }
        let key = "\(size.map { "\($0.bytes)|\($0.files)|\($0.complete)" } ?? "")|\(String(describing: mark))"
        if changed || key != shownKey {
            shownKey = key
            layoutCard()
        }
    }

    private var shownKey: String?
    /// The name's and path's heights, measured when they change.
    private var nameMeasured: (text: String, width: CGFloat, height: CGFloat)?
    private var pathMeasured: (text: String, width: CGFloat, height: CGFloat)?

    /// A new item: its picture, last opened date and media details are read afresh.
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
            if !item.isFolder, FilePreview.kind(for: item)?.isLarge != true {
                let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 260, height: 150), scale: 2, representationTypes: .thumbnail)
                let image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
                guard !Task.isCancelled else { return }
                self.thumbnail = image
                if let previewBox = self.previewBox { self.setNeedsDisplay(previewBox) }
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
        let root = AnyView(FilePreview(item: item, model: model).frame(width: max(inner, 200)).modifier(RegionStyle(values: values)))
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
        let size = NSSize(width: width, height: max(height, content.maxY + Self.padding))
        if frame.size != size {
            let widthChanged = frame.width != width
            setFrameSize(size)
            if widthChanged { layoutCard() }
        }
    }

    private func measure(_ field: NSTextField, _ text: String, width: CGFloat, cache: inout (text: String, width: CGFloat, height: CGFloat)?) -> CGFloat {
        if let cache, cache.text == text, cache.width == width { return cache.height }
        field.stringValue = text
        let height = ceil(field.sizeThatFits(NSSize(width: width, height: 400)).height)
        cache = (text, width, height)
        return height
    }

    private func layoutCard() {
        guard let item, bounds.width > 0 else { return }
        let x = Self.padding
        var y = Self.padding
        let kind = FilePreview.kind(for: item)
        rows = []
        folderSize = nil
        warningY = nil
        summaryY = nil
        previewBox = nil

        // The preview: the file itself where it can be shown, otherwise its picture or icon.
        if let preview, kind?.isLarge == true {
            let height = preview.height
            preview.view.frame = NSRect(x: x, y: y, width: inner, height: height)
            y += height + 16
        } else {
            previewBox = NSRect(x: x, y: y, width: inner, height: item.isFolder ? 120 : 150)
            y += (previewBox?.height ?? 0) + 16
        }

        // The name, then one line: kind · size · what git says about it.
        let nameHeight = measure(name, item.name, width: inner, cache: &nameMeasured)
        name.frame = NSRect(x: x - 2, y: y, width: inner + 4, height: nameHeight)
        y += nameHeight + 3
        subtitle = [(isCurrentFolder ? "This folder" : (item.isFolder ? "Folder" : item.kindDescription), theme.textSecondary)]
        if !item.isFolder, let bytes = item.fileSize {
            subtitle.append((Format.bytes(bytes), theme.textSecondary))
        } else if item.isFolder, let size = FolderSizeStore.shared.size(for: item.path) {
            subtitle.append(((size.complete ? "" : "≥ ") + Format.bytes(size.bytes), theme.textSecondary))
        }
        if let mark = model?.git?.snapshot?.mark(for: item.url.standardizedFileURL.path) {
            switch mark {
            case .changed(let change): subtitle.append((change.title, NSColor(change.color)))
            case .contains(let change, let count): subtitle.append((count == 1 ? "1 change inside" : "\(count) changes inside", NSColor(change.color)))
            case .ignored: subtitle.append(("Ignored by git", theme.textTertiary))
            }
        }
        subtitleY = y
        y += 16
        if media?.summary != nil {
            summaryY = y
            y += 16
        }
        y += 16

        // Facts, label then value.
        func row(_ label: String, _ value: String) {
            rows.append((label, value, y))
            y += 16 + 6
        }
        for media in media?.rows ?? [] { row(media.label.prefix(1).uppercased() + media.label.dropFirst(), media.value) }
        recalculate.isHidden = true
        spinner.stopAnimation(nil)
        if item.isFolder {
            let size = FolderSizeStore.shared.size(for: item.path)
            folderSize = (size.map { ($0.complete ? "" : "≥ ") + Format.bytes($0.bytes) }, y)
            let valueX = x + Self.labelColumn
            if let size {
                let width = ceil(TextLines.shared.line(folderSize?.text ?? "", font: valueFont, color: theme.text).width)
                recalculate.isHidden = false
                recalculate.frame = NSRect(x: valueX + width + 6, y: y + 0.5, width: 15, height: 15)
                y += 16 + 6
                row("Items", size.files.formatted())
                if !size.complete {
                    warningY = y
                    y += 14 + 6
                }
            } else {
                spinner.frame = NSRect(x: valueX, y: y + 2, width: 12, height: 12)
                spinner.startAnimation(nil)
                y += 16 + 6
            }
        } else if let allocated = item.allocatedSize, allocated != item.fileSize {
            row("On disk", Format.bytes(allocated))
        }
        row("Modified", Format.date(item.modified))
        row("Created", Format.date(item.created))
        if let lastOpened { row("Opened", Format.date(lastOpened)) }
        if item.isSymlink, let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: item.path) {
            row("Points to", Format.path(destination))
        }
        // Where it is, selectable.
        whereY = y
        let folder = Format.path(item.url.deletingLastPathComponent().path)
        let pathWidth = inner - Self.labelColumn
        let pathHeight = measure(path, folder, width: pathWidth, cache: &pathMeasured)
        path.frame = NSRect(x: x + Self.labelColumn - 2, y: y, width: pathWidth + 4, height: pathHeight)
        y += pathHeight

        // An archive's contents.
        if let preview, kind == .archive {
            y += 16
            let height = preview.height
            preview.view.frame = NSRect(x: x, y: y, width: inner, height: height)
            y += height
        }

        // Open, Copy path and more, right under what they act on.
        let buttonHeight: CGFloat = 28
        let buttonsY = y + 20
        var buttonX = x
        open.isHidden = isCurrentFolder
        for button in [open, copyPath, more] where !button.isHidden {
            let width = button == more ? buttonHeight : button.width
            button.frame = NSRect(x: buttonX, y: buttonsY, width: width, height: buttonHeight)
            buttonX += width + 6
        }
        content = NSRect(x: 0, y: 0, width: bounds.width, height: buttonsY + buttonHeight)
        if let superview { fit(width: superview.bounds.width, height: superview.bounds.height) }
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let item else { return }
        let x = Self.padding

        // The preview box: the file's picture, or its icon.
        if let box = previewBox {
            surface.setFill()
            NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
            if item.isFolder {
                let glyph = theme.symbol("folder", size: 34, weight: .light, color: theme.textSecondary)
                glyph.draw(in: TextLinesRect.centered(glyph.size, in: box))
            } else if let thumbnail {
                let inset = box.insetBy(dx: 12, dy: 12)
                let scale = min(inset.width / max(thumbnail.size.width, 1), inset.height / max(thumbnail.size.height, 1))
                let size = NSSize(width: thumbnail.size.width * scale, height: thumbnail.size.height * scale)
                thumbnail.draw(in: TextLinesRect.centered(size, in: inset), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            } else {
                Icons.icon(for: item).draw(in: TextLinesRect.centered(NSSize(width: 64, height: 64), in: box), from: .zero,
                                           operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }

        // Kind · size · state.
        var cursor = x
        for (index, part) in subtitle.enumerated() {
            if index > 0 {
                cursor += FileCellView.drawText(" · ", font: subtitleFont, color: theme.textTertiary, x: cursor, midY: subtitleY + 8, width: 20)
            }
            cursor += FileCellView.drawText(part.text, font: subtitleFont, color: part.color, x: cursor, midY: subtitleY + 8,
                                            width: max(0, x + inner - cursor))
        }
        if let summaryY, let summary = media?.summary {
            FileCellView.drawText(summary, font: subtitleFont, color: theme.textSecondary, x: x, midY: summaryY + 8, width: inner)
        }

        // Facts: the label, then the value beside it.
        let valueX = x + Self.labelColumn
        if let (text, y) = folderSize {
            FileCellView.drawText("Size", font: labelFont, color: theme.textTertiary, x: x, midY: y + 8, width: Self.labelColumn)
            if let text { FileCellView.drawText(text, font: valueFont, color: theme.text, x: valueX, midY: y + 8, width: inner - Self.labelColumn - 22) }
        }
        for row in rows {
            FileCellView.drawText(row.label, font: labelFont, color: theme.textTertiary, x: x, midY: row.y + 8, width: Self.labelColumn)
            FileCellView.drawText(row.value, font: valueFont, color: theme.text, x: valueX, midY: row.y + 8,
                                  width: inner - Self.labelColumn, truncation: .byTruncatingMiddle)
        }
        if let warningY {
            FileCellView.drawText("Some folders inside couldn't be read.", font: warningFont, color: warning, x: valueX, midY: warningY + 7, width: inner - Self.labelColumn)
        }
        FileCellView.drawText("Where", font: labelFont, color: theme.textTertiary, x: x, midY: whereY + 8, width: Self.labelColumn)
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
