import QuickLookThumbnailing
import SwiftUI

/// Floating card with details for whatever is selected, or the current folder when nothing is.
struct InspectorView: View {
    let model: BrowserModel

    /// Whether there's anything to show; the column collapses otherwise.
    static func hasContent(_ model: BrowserModel) -> Bool {
        !model.activeSelection.isEmpty || (model.destination == .folder && !model.isSearching)
    }

    var body: some View {
        let urls = model.activeSelection
        let focusURL = urls.first ?? (model.destination == .folder && !model.isSearching ? model.currentURL : nil)
        ScrollView {
            // Nothing to describe means no card at all, rather than an empty box.
            if urls.count > 1 {
                MultipleSelectionSummary(urls: urls).panel(padding: 14)
            } else if let focusURL, let item = FileItem(url: focusURL) {
                ItemDetails(item: item, model: model, isCurrentFolder: urls.isEmpty)
                    .id(focusURL)
                    .panel(padding: 14)
            }
        }
        .scrollContentBackground(.hidden)
        .scrollIndicators(.never)
    }
}

/// Quick Look thumbnail for files (real previews for images, PDFs, videos…); a mint glyph for folders.
struct ItemPreview: View {
    let item: FileItem
    var side: CGFloat = 52
    @State private var thumbnail: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(item.isFolder ? Theme.accentSoft : Theme.raised)
            if item.isFolder {
                Image(systemName: "folder.fill")
                    .font(.system(size: side * 0.42))
                    .foregroundStyle(Theme.accent)
            } else if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(4)
            } else {
                Image(nsImage: Icons.icon(for: item))
                    .resizable()
                    .frame(width: side * 0.7, height: side * 0.7)
            }
        }
        .frame(width: side, height: side)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
        .task(id: item.url) {
            guard !item.isFolder else { return }
            let request = QLThumbnailGenerator.Request(fileAt: item.url, size: CGSize(width: side, height: side),
                                                       scale: 2, representationTypes: .thumbnail)
            thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
        }
    }
}

private struct ItemDetails: View {
    let item: FileItem
    let model: BrowserModel
    let isCurrentFolder: Bool

    private var sizes: FolderSizeStore { .shared }
    private var favorites: FavoritesStore { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 11) {
                ItemPreview(item: item)
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.name)
                        .font(.system(size: 13.5, weight: .semibold))
                        .lineLimit(3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        TypeChip(item: item)
                        Text(isCurrentFolder ? "this folder" : item.kindDescription.lowercased())
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                }
            }

            HStack(spacing: 6) {
                let pinned = favorites.contains(item.url)
                Button {
                    favorites.toggle(item.url)
                } label: {
                    Label(pinned ? "Pinned" : "Pin", systemImage: pinned ? "pin.fill" : "pin")
                }
                .buttonStyle(SubtleButtonStyle())
                if !isCurrentFolder {
                    Button("Open") { model.open(item) }
                        .buttonStyle(SubtleButtonStyle())
                }
                Button {
                    FileActions.revealInFinder([item.url])
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(SubtleButtonStyle())
                .help("Reveal in Finder")
            }

            Rectangle().fill(Theme.border).frame(height: 1)

            VStack(spacing: 6) {
                sizeRows
                DetailRow(label: "created", value: Format.compactDate(item.created))
                DetailRow(label: "changed", value: Format.compactDate(item.modified))
                if let opened = lastOpened {
                    DetailRow(label: "opened", value: Format.compactDate(opened))
                }
                if item.isSymlink, let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: item.path) {
                    DetailRow(label: "points to", value: Format.path(destination))
                }
            }

            Rectangle().fill(Theme.border).frame(height: 1)

            VStack(alignment: .leading, spacing: 6) {
                SectionCaption(title: "Path")
                Text(Format.path(item.path))
                    .font(Theme.mono)
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Copy Path") { FileActions.copyPaths([item.url]) }
                    .buttonStyle(SubtleButtonStyle())
            }
        }
        .onAppear {
            if item.isFolder { sizes.request([item.path]) }
        }
    }

    @ViewBuilder private var sizeRows: some View {
        if item.isFolder {
            let size = sizes.size(for: item.path)
            HStack {
                Text("size").foregroundStyle(Theme.textTertiary)
                Spacer()
                if let size {
                    Text((size.complete ? "" : "≥ ") + Format.bytes(size.bytes))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.accent)
                    Button {
                        sizes.request([item.path], force: true)
                    } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 9, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textTertiary)
                    .help("Recalculate")
                } else {
                    ProgressView().controlSize(.mini)
                }
            }
            .font(.system(size: 11.5))
            if let size {
                DetailRow(label: "files", value: size.files.formatted())
                if !size.complete {
                    Text("Some subfolders couldn't be read.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.warning)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else {
            if let bytes = item.fileSize {
                DetailRow(label: "size", value: Format.bytes(bytes), emphasized: true)
            }
            if let allocated = item.allocatedSize {
                DetailRow(label: "on disk", value: Format.bytes(allocated))
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
    var emphasized = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(Theme.textTertiary)
            Spacer(minLength: 10)
            Text(value)
                .font(.system(size: 11.5, weight: emphasized ? .semibold : .regular, design: .monospaced))
                .foregroundStyle(emphasized ? Theme.accent : Theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .textSelection(.enabled)
        }
        .font(.system(size: 11.5))
    }
}

private struct MultipleSelectionSummary: View {
    let urls: Set<URL>
    /// Read off the main thread: selecting everything in a huge folder must not stall.
    @State private var items: [FileItem] = []

    var body: some View {
        let folders = items.filter(\.isFolder)
        let sizes = FolderSizeStore.shared
        let fileBytes = items.compactMap(\.fileSize).reduce(0, +)
        let folderBytes = folders.compactMap { sizes.size(for: $0.path)?.bytes }.reduce(0, +)
        let pending = folders.contains { sizes.size(for: $0.path) == nil }

        VStack(alignment: .leading, spacing: 10) {
            Text("\(urls.count) selected")
                .font(.system(size: 14, weight: .semibold))
            Text("\(folders.count) dirs · \(items.count - folders.count) files")
                .font(Theme.mono)
                .foregroundStyle(Theme.textSecondary)
            HStack(spacing: 6) {
                Text(Format.bytes(fileBytes + folderBytes))
                    .font(.system(size: 18, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.accent)
                if pending { ProgressView().controlSize(.mini) }
            }
            Button("Copy Paths") { FileActions.copyPaths(urls) }
                .buttonStyle(SubtleButtonStyle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: urls) {
            let urls = urls
            items = await Task.detached(priority: .userInitiated) { urls.compactMap(FileItem.init(url:)) }.value
            FolderSizeStore.shared.request(items.filter(\.isFolder).map(\.path))
        }
    }
}
