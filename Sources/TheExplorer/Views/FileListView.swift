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

/// A list's items by URL, for menus that need to know about every selected item (thousands,
/// after ⌘A). The lookup table is only built if something asks.
final class ListedItems {
    private let rows: [ListRow]
    private lazy var byURL: [URL: FileItem] = Dictionary(rows.map { ($0.id, $0.item) }, uniquingKeysWith: { first, _ in first })

    init(_ rows: [ListRow]) { self.rows = rows }

    /// The listed item, or else what's on disk.
    func item(_ url: URL) -> FileItem? { byURL[url] ?? FileItem(url: url) }
}

/// What an empty list says.
struct EmptyState {
    var symbol: String
    var title: String
    var hint: String?
}

/// The Workbench file list: dense rows, type chips, size bars, full keyboard and mouse
/// selection, drag and drop, and context menus. Sorting is owned by the caller. The list is
/// drawn by AppKit (see FileTable), and so is the gallery (see GalleryGrid).
struct FileListView<RowMenu: View, BackgroundMenu: View>: View {
    let rows: [ListRow]
    @Binding var selection: Set<URL>
    var sort: SortSpec?
    var onSort: ((SortKey) -> Void)?
    /// Largest size in the list, for scaling size bars. Computed from `rows` when nil.
    var maxSize: Int64?
    var dateTitle = "Modified"
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

    @Environment(\.fileLayout) private var layout

    /// Whether the gallery has been shown in this list: from then on both are kept, and
    /// switching only hides one and shows the other (building either took ~15ms).
    @State private var galleryUsed = false

    var body: some View {
        let gallery = layout == .gallery
        ZStack {
            FileTable(rows: rows, selection: $selection, sort: sort, onSort: onSort, maxSize: maxSize, dateTitle: dateTitle,
                      dateSortKey: dateSortKey, showLocation: showLocation, focusRequest: focusRequest, onOpen: onOpen,
                      onQuickLook: onQuickLook, onDropInto: onDropInto, onDropBackground: onDropBackground,
                      onToggleExpand: onToggleExpand, onReachEnd: onReachEnd, footer: footer, gitMark: gitMark,
                      cut: FileClipboard.shared.cutItems, isHidden: gallery, rowMenu: rowMenu, backgroundMenu: backgroundMenu)
            if gallery || galleryUsed {
                GalleryGrid(rows: rows, selection: $selection, focusRequest: focusRequest, onOpen: onOpen,
                            onQuickLook: onQuickLook, onDropBackground: onDropBackground, onReachEnd: onReachEnd,
                            footer: footer, isHidden: !gallery, rowMenu: rowMenu, backgroundMenu: backgroundMenu)
            }
        }
        .overlay {
            if rows.isEmpty, let empty {
                EmptyStateView(state: empty)
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: gallery, initial: true) { if gallery { galleryUsed = true } }
    }
}

struct GroupHeader: View {
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            SectionCaption(title: title)
            Rectangle().fill(Theme.border).frame(height: 1)
        }
        .padding(.horizontal, FileTableLayout.gutter + FileTableLayout.inset)
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
