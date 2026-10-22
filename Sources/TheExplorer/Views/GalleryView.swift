import SwiftUI
import UniformTypeIdentifiers

/// The gallery: the same items as the list, as a grid of thumbnails, for scrolling through
/// photos and videos. Selection, opening, Quick Look, menus and dragging work as in the list.
/// Pinch, ⌘+ and ⌘− (or the slider in the bar) change the tile size.
struct GalleryView<RowMenu: View, BackgroundMenu: View>: View {
    let rows: [ListRow]
    @Binding var selection: Set<URL>
    var empty: EmptyState?
    var focusRequest = 0
    let onOpen: (Set<URL>, _ newTab: Bool) -> Void
    var onQuickLook: (Set<URL>, [ListRow]) -> Void = { _, _ in }
    var onDropBackground: (([URL]) -> Bool)?
    var onReachEnd: (() -> Void)?
    var footer: AnyView?
    @ViewBuilder let rowMenu: (Set<URL>) -> RowMenu
    @ViewBuilder let backgroundMenu: () -> BackgroundMenu

    @FocusState private var focused: Bool
    @Environment(\.isActivePane) private var isActivePane
    @Environment(\.activatePane) private var activatePane
    @Environment(\.switchPane) private var switchPane
    @State private var anchor: URL?
    @State private var cursor: URL?
    @State private var columnCount = 1
    /// The tile size when a pinch began.
    @State private var pinchStart: Double?
    @State private var dropTargeted = false

    private static var spacing: CGFloat { 12 }
    private static var padding: CGFloat { 16 }
    private var prefs: Prefs { .shared }

    /// Rows split where a group starts (Recents' days), so each group gets its own header.
    private var sections: [GallerySection] {
        guard rows.contains(where: { $0.group != nil }) else { return [GallerySection(title: nil, rows: rows)] }
        var sections: [GallerySection] = []
        for row in rows {
            if row.group != nil || sections.isEmpty {
                sections.append(GallerySection(title: row.group, rows: [row]))
            } else {
                sections[sections.count - 1].rows.append(row)
            }
        }
        return sections
    }

    var body: some View {
        keyboard(grid
            .overlay {
                if rows.isEmpty, let empty {
                    EmptyStateView(state: empty)
                        .allowsHitTesting(false)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                onDropBackground?(urls) ?? false
            } isTargeted: { dropTargeted = $0 && onDropBackground != nil }
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Theme.accent.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                        .padding(6)
                        .allowsHitTesting(false)
                }
            }
            .simultaneousGesture(pinch))
    }

    private var grid: some View {
        GeometryReader { proxy in
            let layout = TileLayout(width: proxy.size.width, tile: CGFloat(prefs.galleryTileSize),
                                    spacing: Self.spacing, padding: Self.padding)
            ScrollViewReader { scroller in
                ScrollView {
                    tiles(layout)
                        .padding(Self.padding)
                        .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .topLeading)
                        .contentShape(.rect)
                        .onTapGesture {
                            focused = true
                            selection = []
                        }
                        .contextMenu { backgroundMenu() }
                }
                .scrollContentBackground(.hidden)
                .onChange(of: cursor) { _, target in
                    if let target { scroller.scrollTo(target) }
                }
            }
            .onChange(of: layout.columns, initial: true) { columnCount = layout.columns }
        }
    }

    private func tiles(_ layout: TileLayout) -> some View {
        let columns = Array(repeating: GridItem(.fixed(layout.tileWidth), spacing: Self.spacing), count: layout.columns)
        let side = Thumbnails.step(layout.tileWidth * 2)
        return LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(sections) { section in
                if let title = section.title {
                    GroupHeader(title: title)
                        .padding(.horizontal, -Self.padding + 2)
                }
                LazyVGrid(columns: columns, alignment: .leading, spacing: Self.spacing) {
                    ForEach(section.rows) { row in
                        tile(row, width: layout.tileWidth, side: side)
                    }
                }
            }
            if let onReachEnd, !rows.isEmpty {
                Color.clear.frame(height: 1)
                    .onAppear(perform: onReachEnd)
                    .id(rows.count)
            }
            if let footer, !rows.isEmpty {
                footer
            }
        }
    }

    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = pinchStart ?? prefs.galleryTileSize
                pinchStart = start
                resize(to: start * value.magnification)
            }
            .onEnded { _ in pinchStart = nil }
    }

    private func keyboard(_ content: some View) -> some View {
        content
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                let step = switch press.key {
                case .leftArrow: -1
                case .rightArrow: 1
                case .upArrow: -columnCount
                default: columnCount
                }
                move(step, extend: press.modifiers.contains(.shift))
                return .handled
            }
            .onKeyPress(.return) {
                guard !selection.isEmpty else { return .ignored }
                onOpen(selection, false)
                return .handled
            }
            .onKeyPress(.space) {
                onQuickLook(selection, rows)
                return .handled
            }
            .onKeyPress(.escape) {
                guard !selection.isEmpty else { return .ignored }
                selection = []
                return .handled
            }
            .onKeyPress(.tab) {
                guard let switchPane else { return .ignored }
                switchPane()
                return .handled
            }
            .onChange(of: focusRequest) { focused = true }
            .onChange(of: focused) { if focused { activatePane?() } }
            .onAppear {
                if isActivePane && !NSApp.windows.contains(where: { $0.isVisible && $0.firstResponder is NSText }) { focused = true }
            }
    }

    private func tile(_ row: ListRow, width: CGFloat, side: Int) -> some View {
        GalleryTile(item: row.item, width: width, side: side, isSelected: selection.contains(row.id), listFocused: focused)
            .equatable()
            .contentShape(.rect)
            .clickable()
            .onTapGesture { click(row.id) }
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                onOpen([row.id], NSEvent.modifierFlags.contains(.command))
            })
            .draggable(row.item.url)
            .contextMenu {
                rowMenu(selection.contains(row.id) ? selection : [row.id])
                    .environment(\.listedItems, ListedItems(rows))
            }
            .id(row.id)
    }

    private func resize(to size: Double) {
        let range = Prefs.galleryTileSizes
        let clamped = min(range.upperBound, max(range.lowerBound, size))
        if abs(clamped - prefs.galleryTileSize) >= 1 { prefs.galleryTileSize = clamped }
    }

    // MARK: - Selection

    private func click(_ url: URL) {
        focused = true
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if selection.contains(url) { selection.remove(url) } else { selection.insert(url) }
            anchor = url
        } else if flags.contains(.shift), let anchor, let range = indices(from: anchor, to: url) {
            selection = Set(rows[range].map(\.id))
        } else {
            selection = [url]
            anchor = url
        }
        cursor = url
    }

    private func indices(from a: URL, to b: URL) -> ClosedRange<Int>? {
        guard let i = rows.firstIndex(where: { $0.id == a }), let j = rows.firstIndex(where: { $0.id == b }) else { return nil }
        return min(i, j)...max(i, j)
    }

    private func move(_ delta: Int, extend: Bool) {
        guard !rows.isEmpty else { return }
        let current = cursor.flatMap { c in rows.firstIndex { $0.id == c } }
            ?? rows.firstIndex { selection.contains($0.id) }
        let next = current.map { min(max(0, $0 + delta), rows.count - 1) } ?? (delta > 0 ? 0 : rows.count - 1)
        let url = rows[next].id
        if extend, let anchor, let range = indices(from: anchor, to: url) {
            selection = Set(rows[range].map(\.id))
        } else {
            selection = [url]
            anchor = url
        }
        cursor = url
    }
}

/// How many tiles fit across, and how wide each is so they fill the row.
private struct TileLayout {
    let columns: Int
    let tileWidth: CGFloat

    init(width: CGFloat, tile: CGFloat, spacing: CGFloat, padding: CGFloat) {
        let available = max(tile, width - padding * 2)
        columns = max(1, Int((available + spacing) / (tile + spacing)))
        tileWidth = floor((available - CGFloat(columns - 1) * spacing) / CGFloat(columns))
    }
}

private struct GallerySection: Identifiable {
    let title: String?
    var rows: [ListRow]
    var id: URL? { rows.first?.id }
}

/// One tile: the thumbnail (cropped to a square, like Photos), a badge for videos, and the name.
/// Equatable, so moving the selection only redraws the tiles it touched.
private struct GalleryTile: View, Equatable {
    let item: FileItem
    let width: CGFloat
    /// Pixels to ask for: the tile at 2×, rounded to a cached size.
    let side: Int
    let isSelected: Bool
    let listFocused: Bool

    @State private var entry: Thumbnails.Entry?
    /// Which file version and size `entry` is for. Until a new one loads (after a zoom), the
    /// old picture stays.
    @State private var loadedKey: String?
    @State private var hovered = HoverPreview.on

    init(item: FileItem, width: CGFloat, side: Int, isSelected: Bool, listFocused: Bool) {
        self.item = item
        self.width = width
        self.side = side
        self.isSelected = isSelected
        self.listFocused = listFocused
        // Already made (scrolling back): shown straight away, with no blank frame first.
        let cached = MainActor.assumeIsolated { Thumbnails.cached(item, side: side) }
        _entry = State(initialValue: cached)
        _loadedKey = State(initialValue: cached == nil ? nil : Self.key(item, side))
    }

    private static func key(_ item: FileItem, _ side: Int) -> String {
        "\(side)|\(item.url.absoluteString)|\(item.modified?.timeIntervalSinceReferenceDate ?? 0)"
    }

    static func == (lhs: GalleryTile, rhs: GalleryTile) -> Bool {
        lhs.item == rhs.item && lhs.width == rhs.width && lhs.side == rhs.side
            && lhs.isSelected == rhs.isSelected && lhs.listFocused == rhs.listFocused
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Theme.surface
                if let image = entry?.image {
                    Image(decorative: image, scale: 2)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: width, height: width)
                        .clipped()
                } else {
                    icon
                }
            }
            .frame(width: width, height: width)
            .clipShape(.rect(cornerRadius: 8))
            .overlay(alignment: .bottomTrailing) {
                if Thumbnails.isVideo(item) { videoBadge }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? Theme.accent : (hovered ? Theme.fieldBorder : Theme.border),
                                  lineWidth: isSelected ? 2.5 : 1)
            }
            .brightness(hovered && !isSelected ? 0.04 : 0)
            Text(item.name)
                .font(.system(size: 11.5, weight: item.isFolder ? .semibold : .regular))
                .foregroundStyle(isSelected ? Theme.text : Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(isSelected ? (listFocused ? Theme.accentSoft : Theme.accentSoft.opacity(0.6)) : .clear,
                            in: .rect(cornerRadius: 4))
                .frame(maxWidth: width)
        }
        .hoverTracking { hovered = $0 }
        .help(item.name)
        .task(id: Self.key(item, side)) {
            let key = Self.key(item, side)
            guard !item.isFolder, loadedKey != key else { return }
            let loaded = await Thumbnails.load(item, side: side)
            guard !Task.isCancelled else { return }
            entry = loaded
            loadedKey = key
        }
    }

    /// Folders and files without a picture: their icon, on the tile's plain background.
    @ViewBuilder
    private var icon: some View {
        if item.isFolder {
            Image(systemName: "folder.fill")
                .font(.system(size: width * 0.32))
                .foregroundStyle(Theme.accent.opacity(0.85))
        } else {
            Image(nsImage: FileIcons.icon(for: item))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: width * 0.42, height: width * 0.42)
        }
    }

    private var videoBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "play.fill").font(.system(size: 7.5, weight: .bold))
            if let duration = entry?.duration {
                Text(Thumbnails.durationText(duration))
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.black.opacity(0.55), in: .capsule)
        .padding(6)
    }
}

/// File icons by type, from the system, kept so tiles don't ask again.
@MainActor
enum FileIcons {
    private static var byType: [String: NSImage] = [:]

    static func icon(for item: FileItem) -> NSImage {
        let type = item.contentType ?? UTType(filenameExtension: item.fileExtension) ?? .data
        if let icon = byType[type.identifier] { return icon }
        let icon = NSWorkspace.shared.icon(for: type)
        byType[type.identifier] = icon
        return icon
    }
}
