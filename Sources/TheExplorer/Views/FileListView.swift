import SwiftUI

/// One line in a file list: the item plus whatever the list should show about it.
struct ListRow: Identifiable, Sendable {
    let item: FileItem
    /// Known size (files, or folders whose size the caller already has).
    var size: Int64?
    /// Folder sizes measured on demand: the row reads FolderSizeStore itself, so sizes landing
    /// only redraw the rows on screen instead of rebuilding the whole list.
    var liveFolderSize = false
    /// Value of the date column (modified, created, added… depending on the view).
    var date: Date?
    /// Enclosing folder, shown when the list mixes folders (search, recents).
    var location: String?
    /// Group header shown above this row; set on the first row of each group only.
    var group: String?
    /// Nesting level inside inline-expanded folders.
    var depth = 0
    /// Folder rows that can expand inline: whether they are. nil when the row can't expand.
    var expansion: Bool?

    var id: URL { item.url }
}

/// What an empty list says.
struct EmptyState {
    var symbol: String
    var title: String
    var hint: String?
}

/// Column geometry shared by the header and every row, so they can never drift apart.
private enum Column {
    static let marker: CGFloat = 10
    static let type: CGFloat = 44
    static let size: CGFloat = 112
    static let date: CGFloat = 70
    static let spacing: CGFloat = 10
    /// Outer gutter (list) + inner padding (row).
    static let gutter: CGFloat = 8
    static let inset: CGFloat = 10
}

/// The Workbench file list: dense rows, type chips, size bars, full keyboard and mouse
/// selection, drag and drop, and context menus. Sorting is owned by the caller.
struct FileListView<RowMenu: View, BackgroundMenu: View>: View {
    let rows: [ListRow]
    @Binding var selection: Set<URL>
    var sort: SortSpec?
    var onSort: ((SortKey) -> Void)?
    /// Largest size in the list, for scaling size bars. Computed from `rows` when nil.
    var maxSize: Int64?
    var dateTitle = "Changed"
    var dateSortKey: SortKey = .modified
    var showLocation = false
    var empty: EmptyState?
    var focusRequest = 0
    /// Open the given items; `newTab` is true for ⌘-double-click.
    let onOpen: (Set<URL>, _ newTab: Bool) -> Void
    /// Quick Look the selection; gets the rows too, so the preview can step through them in order.
    var onQuickLook: (Set<URL>, [ListRow]) -> Void = { _, _ in }
    /// Drop onto a folder row. Return false to reject.
    var onDropInto: (([URL], URL) -> Bool)?
    /// Drop onto empty space.
    var onDropBackground: (([URL]) -> Bool)?
    /// Expands or collapses a folder inline (its arrow, or → and ←).
    var onToggleExpand: ((URL) -> Void)?
    /// Called when the last row scrolls into view, to load the next page.
    var onReachEnd: (() -> Void)?
    /// Shown below the last row.
    var footer: AnyView?
    /// Git status for a row, in a repository.
    var gitMark: ((URL) -> GitMark?)?
    @ViewBuilder let rowMenu: (Set<URL>) -> RowMenu
    @ViewBuilder let backgroundMenu: () -> BackgroundMenu

    @FocusState private var focused: Bool
    @Environment(\.isActivePane) private var isActivePane
    @Environment(\.activatePane) private var activatePane
    @Environment(\.switchPane) private var switchPane
    @State private var anchor: URL?
    @State private var cursor: URL?
    @State private var dropTarget: URL?
    @State private var backgroundTargeted = false
    /// Where each row on screen is, for finding the row under a drop.
    @State private var rowFrames = RowFrames()
    @State private var multiDrag = MultiDragSource()
    private static var listSpace: String { "fileList" }
    @State private var typeBuffer = ""
    @State private var lastTypeTime = Date.distantPast

    var body: some View {
        let maxSize = self.maxSize ?? rows.lazy.compactMap(\.size).max() ?? 0
        let _ = multiDrag.update(rows: rows, selection: selection)
        GeometryReader { proxy in
            ScrollViewReader { scroller in
                ScrollView {
                    LazyVStack(spacing: 1, pinnedViews: [.sectionHeaders]) {
                        Section {
                            ForEach(rows) { row in
                                // Exactly one view per row (header included) keeps the lazy
                                // stack's scrolling cost independent of the row count.
                                VStack(spacing: 1) {
                                    if let group = row.group {
                                        GroupHeader(title: group)
                                    }
                                    rowView(row, maxSize: maxSize)
                                        .padding(.horizontal, Column.gutter)
                                }
                                .id(row.id)
                            }
                            if let onReachEnd, !rows.isEmpty {
                                // Lazy, so this only appears (and fires) once you scroll to the end.
                                Color.clear.frame(height: 1)
                                    .onAppear(perform: onReachEnd)
                                    .id(rows.count)
                            }
                            if let footer, !rows.isEmpty {
                                footer
                            }
                        } header: {
                            header
                        }
                    }
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .top)
                    .contentShape(.rect)
                    .onTapGesture {
                        focused = true
                        selection = []
                    }
                    .contextMenu { backgroundMenu() }
                    // One drop target for the whole list, which works out the row under the
                    // cursor itself. SwiftUI gives a list-wide drop target every drop, even over
                    // rows with their own, so folder rows never received theirs.
                    .coordinateSpace(.named(Self.listSpace))
                    .onDrop(of: [.fileURL, .url], delegate: ListDropDelegate(
                        frames: rowFrames, folders: { url in rows.first { $0.id == url }?.item.isFolder == true },
                        canDropInto: onDropInto != nil, canDropOnBackground: onDropBackground != nil,
                        dropTarget: $dropTarget, backgroundTargeted: $backgroundTargeted,
                        onDropInto: { urls, folder in onDropInto?(urls, folder) ?? false },
                        onDropBackground: { urls in onDropBackground?(urls) ?? false }
                    ))
                }
                .scrollContentBackground(.hidden)
                .onChange(of: cursor) { _, target in
                    if let target { scroller.scrollTo(target) }
                }
            }
        }
        .overlay {
            if rows.isEmpty, let empty {
                EmptyStateView(state: empty)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if backgroundTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Theme.accent.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            expandOrCollapse(expanding: press.key == .rightArrow)
        }
        .onKeyPress(keys: [.upArrow, .downArrow]) { press in
            move(press.key == .upArrow ? -1 : 1, extend: press.modifiers.contains(.shift))
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
            // In a split tab, Tab moves to the other pane.
            guard let switchPane else { return .ignored }
            switchPane()
            return .handled
        }
        .onKeyPress(phases: .down) { press in
            typeSelect(press)
        }
        .onChange(of: focusRequest) { focused = true }
        .onChange(of: focused) { if focused { activatePane?() } }
        .onAppear {
            // Lists appear mid-typing (search results replace the folder after the first
            // character); never pull focus out of a text field you're typing in. In a split
            // tab, only the active pane's list takes it.
            if isActivePane && !NSApp.windows.contains(where: { $0.isVisible && $0.firstResponder is NSText }) { focused = true }
            multiDrag.install()
        }
        .onDisappear { multiDrag.uninstall() }
        .background(WindowReader { multiDrag.window = $0 })
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Column.spacing) {
            Color.clear.frame(width: Column.marker, height: 1)
            headerCell("Name", key: .name, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            if showLocation {
                headerCell("Location", key: nil, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            headerCell("Type", key: .kind, alignment: .center)
                .frame(width: Column.type)
            headerCell("Size", key: .size, alignment: .trailing)
                .frame(width: Column.size, alignment: .trailing)
            headerCell(dateTitle, key: dateSortKey, alignment: .trailing)
                .frame(width: Column.date, alignment: .trailing)
        }
        .padding(.horizontal, Column.gutter + Column.inset)
        .frame(height: 30)
        .background(Theme.background)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    /// Column title with a sort arrow whose space is always reserved, so titles never reflow.
    /// Trailing columns put the arrow first so the title stays flush with the numbers below.
    @ViewBuilder
    private func headerCell(_ title: String, key: SortKey?, alignment: HorizontalAlignment) -> some View {
        let isActive = key != nil && sort?.key == key
        let arrow = Image(systemName: sort?.ascending == true ? "arrow.up" : "arrow.down")
            .font(.system(size: 8, weight: .bold))
            .frame(width: 9)
            .opacity(isActive ? 1 : 0)
        let label = HStack(spacing: 3) {
            if alignment == .trailing { arrow }
            Text(title.uppercased())
                .lineLimit(1)
                .fixedSize()
            if alignment != .trailing && key != nil { arrow }
        }
        .font(.system(size: 9.5, weight: .semibold))
        .tracking(0.7)

        if let key, let onSort {
            Button { onSort(key) } label: { label }
                .buttonStyle(HeaderCellStyle(isActive: isActive))
                .help("Sort by \(title.lowercased())")
        } else {
            label.foregroundStyle(Theme.textTertiary)
        }
    }

    // MARK: - Rows

    private func rowView(_ row: ListRow, maxSize: Int64) -> some View {
        let isSelected = selection.contains(row.id)
        let cut = FileClipboard.shared.cutItems
        return RowContent(row: row, isSelected: isSelected, listFocused: focused, isDropTarget: dropTarget == row.id,
                          isCut: !cut.isEmpty && cut.contains(row.id.standardizedFileURL),
                          git: gitMark?(row.id),
                          maxSize: maxSize, showLocation: showLocation,
                          onToggle: row.expansion != nil ? onToggleExpand.map { toggle in { toggle(row.id) } } : nil)
            .equatable()
            .contentShape(.rect)
            .clickable()
            .onTapGesture { click(row.id) }
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                onOpen([row.id], NSEvent.modifierFlags.contains(.command))
            })
            .draggable(row.item.url)
            // Frames for drops (list coordinates) and for multi-item drags (window coordinates).
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.listSpace)) } action: { rowFrames.frames[row.id] = $0 }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { multiDrag.frames[row.id] = $0 }
            .onDisappear {
                rowFrames.frames[row.id] = nil
                multiDrag.frames[row.id] = nil
            }
            #if DEBUG
            .debugRowFrame(row)
            #endif
            .contextMenu {
                rowMenu(selection.contains(row.id) ? selection : [row.id])
            }
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

    /// → expands the selected folders; ← collapses them, or from inside one, selects its folder.
    private func expandOrCollapse(expanding: Bool) -> KeyPress.Result {
        guard let onToggleExpand, !selection.isEmpty else { return .ignored }
        let selected = rows.filter { selection.contains($0.id) }
        if expanding {
            selected.filter { $0.expansion == false }.forEach { onToggleExpand($0.id) }
        } else if selected.contains(where: { $0.expansion == true }) {
            selected.filter { $0.expansion == true }.forEach { onToggleExpand($0.id) }
        } else if selected.count == 1, let row = selected.first, row.depth > 0,
                  let parent = rows.first(where: { $0.id == row.id.deletingLastPathComponent() }) {
            selection = [parent.id]
            anchor = parent.id
            cursor = parent.id
        }
        return .handled
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

    /// Typing letters jumps to the first name starting with them (like Finder).
    private func typeSelect(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.isDisjoint(with: [.command, .control, .option]),
              let character = press.characters.first, character.isLetter || character.isNumber || character == "." || character == "_"
        else { return .ignored }
        let now = Date()
        typeBuffer = now.timeIntervalSince(lastTypeTime) > 0.9 ? String(character) : typeBuffer + String(character)
        lastTypeTime = now
        let needle = typeBuffer.lowercased()
        guard let match = rows.first(where: { $0.item.name.lowercased().hasPrefix(needle) }) else { return .handled }
        selection = [match.id]
        anchor = match.id
        cursor = match.id
        return .handled
    }
}

/// What a row draws. Equatable, so when the selection moves SwiftUI only redraws the rows whose
/// state changed; hover is local for the same reason.
/// A row's git status: a letter for a changed file, a dot for a folder with changes inside.
private struct GitBadge: View {
    let mark: GitMark

    var body: some View {
        switch mark {
        case .changed(let change):
            Text(change.letter)
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .foregroundStyle(change.color)
                .help(change.title)
        case .contains(let change, let count):
            Circle()
                .fill(change.color)
                .frame(width: 5, height: 5)
                .help(count == 1 ? "1 change inside" : "\(count) changes inside")
        case .ignored:
            EmptyView()
        }
    }
}

private struct RowContent: View, Equatable {
    let row: ListRow
    let isSelected: Bool
    let listFocused: Bool
    let isDropTarget: Bool
    /// Cut with ⌘X and waiting to be pasted: shown faded.
    let isCut: Bool
    let git: GitMark?
    let maxSize: Int64
    let showLocation: Bool
    /// Expands or collapses this folder. Not part of equality.
    var onToggle: (() -> Void)?

    @State private var hovered = HoverPreview.on

    private static let indent: CGFloat = 16

    static func == (lhs: RowContent, rhs: RowContent) -> Bool {
        lhs.isSelected == rhs.isSelected && lhs.listFocused == rhs.listFocused && lhs.isDropTarget == rhs.isDropTarget
            && lhs.isCut == rhs.isCut && lhs.git == rhs.git
            && lhs.maxSize == rhs.maxSize && lhs.showLocation == rhs.showLocation
            && lhs.row.item == rhs.row.item && lhs.row.size == rhs.row.size && lhs.row.date == rhs.row.date
            && lhs.row.location == rhs.row.location && lhs.row.liveFolderSize == rhs.row.liveFolderSize
            && lhs.row.depth == rhs.row.depth && lhs.row.expansion == rhs.row.expansion
            && (lhs.onToggle == nil) == (rhs.onToggle == nil)
    }

    var body: some View {
        let item = row.item
        HStack(spacing: Column.spacing) {
            disclosure
                .padding(.leading, CGFloat(row.depth) * Self.indent)
                .opacity(item.isFolder ? 1 : 0)
            HStack(spacing: 5) {
                Text(item.name)
                    .font(.system(size: 12.5, weight: item.isFolder ? .semibold : .regular))
                    .foregroundStyle(item.isHidden || git == .ignored ? Theme.textTertiary : Theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if item.isSymlink {
                    Image(systemName: "arrow.turn.up.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                        .help("Alias or symbolic link")
                }
                if let git { GitBadge(mark: git) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if showLocation {
                Text(row.location.map(Format.path) ?? "")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(row.location ?? "")
            }
            TypeChip(item: item)
                .frame(width: Column.type)
            sizeCell
                .frame(width: Column.size, alignment: .trailing)
            Text(RelativeTime.short(row.date))
                .font(Theme.mono)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .frame(width: Column.date, alignment: .trailing)
                .help(Format.date(row.date))
        }
        .opacity(isCut ? 0.4 : 1)
        .padding(.horizontal, Column.inset)
        .frame(height: 28)
        .background(background, in: .rect(cornerRadius: 6))
        .overlay(alignment: .leading) {
            if isSelected {
                Capsule().fill(Theme.accent).frame(width: 2.5, height: 14).padding(.leading, 1.5)
            }
        }
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.accent, lineWidth: 1.5)
            }
        }
        .hoverTracking { hovered = $0 }
    }

    /// The folder arrow. Where folders can expand inline it's a button with a generous hit area
    /// that turns down when open; clicking it never selects or opens the row.
    @ViewBuilder
    private var disclosure: some View {
        let arrow = Image(systemName: "chevron.right")
            .font(.system(size: 8, weight: .heavy))
            .rotationEffect(.degrees(row.expansion == true ? 90 : 0))
            .animation(.snappy(duration: 0.15), value: row.expansion)
            .frame(width: Column.marker)
        if let onToggle {
            Hovering { hovering in
                arrow
                    .foregroundStyle(hovering || row.expansion == true ? Theme.text : Theme.textSecondary)
                    .frame(width: 16, height: 16)
                    .background(hovering ? Theme.raisedHover : .clear, in: .rect(cornerRadius: 4))
                    .frame(width: Column.marker + 12, height: 26)
                    .contentShape(.rect)
                    .padding(.horizontal, -6)
                    .clickable()
            }
            .highPriorityGesture(TapGesture().onEnded(onToggle))
            .help(row.expansion == true ? "Collapse (←)" : "Expand (→)")
        } else {
            arrow.foregroundStyle(Theme.textSecondary)
        }
    }

    private var background: Color {
        if isSelected { return listFocused ? Theme.accentSoft : Theme.accentSoft.opacity(0.6) }
        return hovered ? Theme.hoverFill : .clear
    }

    /// "▬▬──  12.4 GB": a short bar for scale beside the number.
    @ViewBuilder
    private var sizeCell: some View {
        let measured = row.liveFolderSize && row.size == nil ? FolderSizeStore.shared.size(for: row.item.path) : nil
        let size = row.size ?? measured?.bytes
        let partial = measured.map { !$0.complete } ?? false
        HStack(spacing: 8) {
            if let size, maxSize > 0 {
                HeatBar(fraction: Double(size) / Double(maxSize), height: 3, track: Theme.hoverFill, hidesTiny: true)
                    .frame(width: 30)
            } else {
                Color.clear.frame(width: 30, height: 3)
            }
            Group {
                if let size {
                    Text((partial ? "≥ " : "") + Format.bytes(size))
                        .foregroundStyle(Theme.text)
                        .help(partial ? "Some subfolders couldn't be read, so this is a minimum." : "")
                } else if row.liveFolderSize && FolderSizeStore.shared.isCalculating(row.item.path) {
                    Text("···").foregroundStyle(Theme.textTertiary)
                        .help("Calculating…")
                } else {
                    Text("—").foregroundStyle(Theme.textTertiary)
                }
            }
            .font(Theme.mono)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

/// A sortable column title: brightens on hover, brightest while it's the sort column.
private struct HeaderCellStyle: ButtonStyle {
    let isActive: Bool

    func makeBody(configuration: Configuration) -> some View {
        Hovering { hovering in
            configuration.label
                .foregroundStyle(isActive || hovering ? (hovering ? Theme.text : Theme.textSecondary) : Theme.textTertiary)
                .padding(.vertical, 6)
                .clickable()
        }
    }
}

/// Folder rows accept drops (items go inside); other rows don't.
/// Row frames in the list's coordinate space. Not observed: they change on every scroll.
final class RowFrames {
    var frames: [URL: CGRect] = [:]

    func row(at point: CGPoint) -> URL? {
        frames.first { $0.value.contains(point) }?.key
    }
}

/// Drops onto the list: into the folder row under the cursor, or else into the folder shown.
private struct ListDropDelegate: DropDelegate {
    let frames: RowFrames
    let folders: (URL) -> Bool
    let canDropInto: Bool
    let canDropOnBackground: Bool
    @Binding var dropTarget: URL?
    @Binding var backgroundTargeted: Bool
    let onDropInto: ([URL], URL) -> Bool
    let onDropBackground: ([URL]) -> Bool

    /// The folder row under the cursor, if drops can go into rows.
    private func folder(at info: DropInfo) -> URL? {
        guard canDropInto, let url = frames.row(at: info.location), folders(url) else { return nil }
        return url
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL, .url]) && (canDropInto || canDropOnBackground)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let target = folder(at: info)
        if dropTarget != target { dropTarget = target }
        let onBackground = target == nil && canDropOnBackground
        if backgroundTargeted != onBackground { backgroundTargeted = onBackground }
        guard target != nil || canDropOnBackground else { return DropProposal(operation: .forbidden) }
        return DropProposal(operation: NSEvent.modifierFlags.contains(.option) ? .copy : .move)
    }

    func dropExited(info: DropInfo) {
        dropTarget = nil
        backgroundTargeted = false
    }

    func performDrop(info: DropInfo) -> Bool {
        let target = folder(at: info)
        dropTarget = nil
        backgroundTargeted = false
        guard target != nil || canDropOnBackground else { return false }
        let providers = info.itemProviders(for: [.fileURL, .url])
        Self.load(providers) { urls in
            guard !urls.isEmpty else { return }
            if let target { _ = onDropInto(urls, target) } else { _ = onDropBackground(urls) }
        }
        return true
    }

    /// Reads every dropped URL (files, and S3 items, which are plain URLs), then calls back on main.
    private static func load(_ providers: [NSItemProvider], then use: @escaping ([URL]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [(Int, URL)] = []
        for (index, provider) in providers.enumerated() {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { lock.withLock { urls.append((index, url)) } }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            use(urls.sorted { $0.0 < $1.0 }.map(\.1))
        }
    }
}

private struct GroupHeader: View {
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            SectionCaption(title: title)
            Rectangle().fill(Theme.border).frame(height: 1)
        }
        .padding(.horizontal, Column.gutter + Column.inset)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }
}

struct EmptyStateView: View {
    let state: EmptyState

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: state.symbol)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Theme.textTertiary)
            Text(state.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            if let hint = state.hint {
                Text(hint)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: 280)
    }
}
