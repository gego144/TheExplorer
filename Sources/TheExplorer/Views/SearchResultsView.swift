import SwiftUI

struct SearchResultsView: View {
    @Bindable var model: BrowserModel
    /// Newest changed first by default; nil would keep Spotlight's relevance order.
    @State private var sort: SortSpec? = .byChanged
    @Environment(\.openTab) private var openTab

    var body: some View {
        @Bindable var search = model.search
        var rows = search.visibleHits.map { hit in
            ListRow(
                item: hit.item,
                size: hit.item.isFolder ? nil : hit.item.fileSize,
                liveFolderSize: hit.item.isFolder,
                date: hit.item.modified,
                location: (hit.item.path as NSString).deletingLastPathComponent
            )
        }
        if let sort {
            let sizes = FolderSizeStore.shared
            rows = RowSorter.sorted(rows, by: sort) { sizes.size(for: $0)?.bytes }
        }

        return VStack(spacing: 0) {
            PaneHeader {
                Image(systemName: model.searchScope == .mac ? "globe" : "folder")
                    .foregroundStyle(Theme.accent)
                Text(scopeDescription)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if search.isRunning && model.searchScope == .folder && search.scannedCount > 0 {
                    Text("\(search.scannedCount.formatted()) checked")
                        .font(Theme.mono)
                        .foregroundStyle(Theme.textTertiary)
                }
                Text(countDescription(rows.count))
                    .font(Theme.mono)
                    .foregroundStyle(Theme.textSecondary)
                Segmented(selection: $search.kindFilter, options: [(.all, "All"), (.folders, "Dirs"), (.files, "Files")])
                    .fixedSize()
            }

            FileListView(
                rows: rows,
                selection: $search.selection,
                sort: sort,
                onSort: { key in sort = (sort ?? SortSpec(key: key, ascending: key == .name)).toggled(to: key) },
                showLocation: true,
                empty: search.isRunning ? nil : EmptyState(
                    symbol: "magnifyingglass", title: "No matches for “\(model.searchText)”",
                    hint: model.searchScope == .folder ? "Try “Everywhere” to search the whole Mac." : "Try “Here” to search hidden and unindexed files in this folder."),
                focusRequest: model.listFocusRequest,
                onOpen: { urls, newTab in open(urls, newTab: newTab, rows: rows) },
                onQuickLook: { model.quickLook($0, in: $1) },
                rowMenu: { FileContextMenu(urls: $0, model: model) },
                backgroundMenu: { EmptyView() }
            )
            .onChange(of: search.selection) {
                // Measure folders as you select them so the inspector can show their size.
                FolderSizeStore.shared.request(rows.filter { search.selection.contains($0.id) && $0.item.isFolder }.map(\.item.path))
            }

            if model.searchScope == .mac {
                Text("Everywhere uses the Spotlight index, so hidden, system and excluded folders are skipped. “Here” searches every file in the current folder.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
            }
        }
    }

    private func open(_ urls: Set<URL>, newTab: Bool, rows: [ListRow]) {
        let items = rows.filter { urls.contains($0.id) }.map(\.item)
        if newTab {
            items.filter(\.isFolder).forEach { openTab($0.url) }
        } else if items.count == 1, let item = items.first {
            model.open(item)
        } else {
            items.forEach { NSWorkspace.shared.open($0.url) }
        }
    }

    private var scopeDescription: String {
        switch model.searchScope {
        case .mac: "Searching everywhere"
        case .folder: "Searching “\(FileManager.default.displayName(atPath: model.currentURL.path))” and below"
        }
    }

    private func countDescription(_ count: Int) -> String {
        let base = "\(count.formatted()) \(count == 1 ? "result" : "results")"
        return model.search.truncated ? base + " · best matches" : base
    }
}
