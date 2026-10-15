import SwiftUI

struct FolderView: View {
    @Bindable var model: BrowserModel
    @Environment(\.openTab) private var openTab

    var body: some View {
        let sizes = FolderSizeStore.shared
        let rows = model.rows.map { row in
            ListRow(
                item: row.item,
                size: row.displaySize,
                sizeCalculating: row.item.isFolder && sizes.isCalculating(row.item.path),
                sizePartial: row.folderSize.map { !$0.complete } ?? false,
                date: row.item.modified
            )
        }

        VStack(spacing: 0) {
            if let error = model.loadError {
                ErrorBanner(message: error) { model.dismissError() }
            }
            FileListView(
                rows: rows,
                selection: $model.selection,
                sort: model.sort,
                onSort: { model.sort = model.sort.toggled(to: $0) },
                empty: emptyState,
                focusRequest: model.listFocusRequest,
                onOpen: { urls, newTab in
                    let folders = model.items.filter { urls.contains($0.url) && $0.isFolder }
                    if newTab, !folders.isEmpty {
                        folders.forEach { openTab($0.url) }
                    } else {
                        model.open(urls: urls)
                    }
                },
                onQuickLook: { model.quickLook($0) },
                onDropInto: { urls, folder in model.receiveDrop(urls, into: folder) },
                onDropBackground: { model.receiveDrop($0, into: model.currentURL) },
                rowMenu: { FileContextMenu(urls: $0, model: model) },
                backgroundMenu: { FolderBackgroundMenu(model: model) }
            )
        }
    }

    private var emptyState: EmptyState? {
        guard !model.isLoading, model.loadError == nil else { return nil }
        if model.items.isEmpty {
            return EmptyState(symbol: "tray", title: "This folder is empty",
                              hint: "Drop files here, or right-click to create a folder or file.")
        }
        return EmptyState(symbol: "line.3.horizontal.decrease", title: "Nothing to show",
                          hint: "Hidden files or the Dirs/Files filter are hiding everything here.")
    }
}

/// Menu for right-clicking empty space: acts on the folder being viewed.
struct FolderBackgroundMenu: View {
    let model: BrowserModel

    var body: some View {
        let folder = model.currentURL
        Button("New Folder…") { model.creating = .folder }
        Button("New File…") { model.creating = .file }
        Divider()
        Button("Open in Terminal") { FileActions.openInTerminal(folder) }
        Button("Copy Path") { FileActions.copyPaths([folder]) }
        Button("Reveal in Finder") { FileActions.revealInFinder([folder]) }
        Button(FavoritesStore.shared.contains(folder) ? "Unpin" : "Pin to Sidebar") {
            FavoritesStore.shared.toggle(folder)
        }
        Divider()
        Button(model.showHidden ? "Hide Hidden Files" : "Show Hidden Files") { model.showHidden.toggle() }
        Button("Refresh") { model.reload(keepSelection: true) }
    }
}
