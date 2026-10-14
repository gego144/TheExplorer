import SwiftUI

/// Details for whatever is selected — or the current folder when nothing is.
struct InspectorView: View {
    let model: BrowserModel

    var body: some View {
        let urls = model.activeSelection
        ScrollView {
            Group {
                if urls.count > 1 {
                    MultipleSelectionSummary(urls: urls)
                } else if let url = urls.first ?? (model.destination == .folder && !model.isSearching ? model.currentURL : nil),
                          let item = FileItem(url: url) {
                    ItemDetails(item: item, model: model, isCurrentFolder: urls.isEmpty)
                        .id(url)
                } else {
                    Text("No Selection")
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                }
            }
            .padding(16)
        }
        .inspectorColumnWidth(min: 240, ideal: 280, max: 400)
    }
}

private struct ItemDetails: View {
    let item: FileItem
    let model: BrowserModel
    let isCurrentFolder: Bool

    private var sizes: FolderSizeStore { .shared }
    private var favorites: FavoritesStore { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(spacing: 8) {
                Image(nsImage: Icons.icon(for: item))
                    .resizable()
                    .frame(width: 72, height: 72)
                Text(item.name)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                KindLabel(item: item)
                if isCurrentFolder {
                    Text("Current folder").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity)

            HStack {
                Button {
                    favorites.toggle(item.url)
                } label: {
                    Label(favorites.contains(item.url) ? "Favorited" : "Favorite",
                          systemImage: favorites.contains(item.url) ? "star.fill" : "star")
                }
                .tint(favorites.contains(item.url) ? .yellow : nil)
                if !isCurrentFolder {
                    Button("Open") { model.open(item) }
                }
                Button {
                    FileActions.revealInFinder([item.url])
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .help("Reveal in Finder")
            }
            .controlSize(.small)
            .frame(maxWidth: .infinity)

            Divider()

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
                sizeRows
                DetailRow(label: "Created", value: Format.date(item.created))
                DetailRow(label: "Modified", value: Format.date(item.modified))
                if let opened = lastOpened {
                    DetailRow(label: "Last opened", value: Format.date(opened))
                }
                if item.isSymlink, let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: item.path) {
                    DetailRow(label: "Points to", value: Format.path(destination))
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Where").font(.caption).foregroundStyle(.secondary)
                Text(Format.path(item.path))
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Copy Path") { FileActions.copyPaths([item.url]) }
                    .controlSize(.small)
            }
        }
        .onAppear {
            if item.isFolder { sizes.request([item.path]) }
        }
    }

    @ViewBuilder private var sizeRows: some View {
        if item.isFolder {
            let size = sizes.size(for: item.path)
            GridRow {
                Text("Size").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                HStack(spacing: 6) {
                    if let size {
                        Text((size.complete ? "" : "≥ ") + Format.bytes(size.bytes)).monospacedDigit()
                        Button {
                            sizes.request([item.path], force: true)
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .help("Recalculate")
                    } else {
                        ProgressView().controlSize(.mini)
                        Text("Calculating…").foregroundStyle(.secondary)
                    }
                }
            }
            if let size {
                DetailRow(label: "Contains", value: "\(size.files.formatted()) files")
                if !size.complete {
                    DetailRow(label: "", value: "Some subfolders couldn't be read.")
                }
            }
        } else {
            if let bytes = item.fileSize {
                DetailRow(label: "Size", value: "\(Format.bytes(bytes)) (\(bytes.formatted()) bytes)")
            }
            if let allocated = item.allocatedSize {
                DetailRow(label: "On disk", value: Format.bytes(allocated))
            }
        }
    }

    private var lastOpened: Date? {
        try? item.url.resourceValues(forKeys: [.contentAccessDateKey]).contentAccessDate
    }
}

private struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).textSelection(.enabled)
        }
    }
}

private struct MultipleSelectionSummary: View {
    let urls: Set<URL>

    var body: some View {
        let items = urls.compactMap(FileItem.init(url:))
        let folders = items.filter(\.isFolder)
        let sizes = FolderSizeStore.shared
        let fileBytes = items.compactMap(\.fileSize).reduce(0, +)
        let folderBytes = folders.compactMap { sizes.size(for: $0.path)?.bytes }.reduce(0, +)
        let pending = folders.contains { sizes.size(for: $0.path) == nil }

        VStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("\(items.count) items selected").font(.headline)
            Text("\(folders.count) folders, \(items.count - folders.count) files")
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text("Total: " + Format.bytes(fileBytes + folderBytes)).monospacedDigit()
                if pending { ProgressView().controlSize(.mini) }
            }
            Button("Copy Paths") { FileActions.copyPaths(urls) }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .onAppear { sizes.request(folders.map(\.path)) }
    }
}
