import QuickLookThumbnailing
import SwiftUI

/// Floating card with details for whatever is selected, or the current folder when nothing is.
struct InspectorView: View {
    let model: BrowserModel

    /// Whether there's anything to show; the column collapses otherwise.
    static func hasContent(_ model: BrowserModel) -> Bool {
        !model.activeSelection.isEmpty || (model.destination == .folder && !model.isSearching) || model.destination == .drive
    }

    var body: some View {
        if model.destination == .s3 {
            ScrollView { S3Inspector(model: model) }
                .scrollContentBackground(.hidden)
                .scrollIndicators(.never)
        } else if model.destination == .drive {
            ScrollView { DriveInspector(model: model) }
                .scrollContentBackground(.hidden)
                .scrollIndicators(.never)
        } else {
            local
        }
    }

    @ViewBuilder private var local: some View {
        let urls = model.activeSelection
        let focusURL = urls.first ?? (model.destination == .folder && !model.isSearching ? model.currentURL : nil)
        ScrollView {
            // Nothing to describe means no card at all, rather than an empty box.
            if urls.count > 1 {
                MultipleSelectionSummary(urls: urls).panel(padding: 14)
            } else if let focusURL, let item = details(of: focusURL, isCurrentFolder: urls.isEmpty) {
                // Updated in place as the selection moves, rather than built anew for each item.
                ItemDetails(item: item, model: model, isCurrentFolder: urls.isEmpty)
                    .panel(padding: 14)
            }
        }
        .scrollContentBackground(.hidden)
        .scrollIndicators(.never)
    }

    /// What the folder's listing already read, or failing that (search results, Recents), the disk.
    private func details(of url: URL, isCurrentFolder: Bool) -> FileItem? {
        if model.destination == .folder && !model.isSearching {
            // While a folder you just went to is listed, the old rows stay up and so do their
            // folder's details, for the frame or two until both change together.
            if isCurrentFolder, let folder = model.folderItem, folder.url == url || model.isLoading { return folder }
            if !isCurrentFolder, let item = model.listedItem(url) { return item }
        }
        return FileItem(url: url)
    }
}

/// Quick Look thumbnail for files (real previews for images, PDFs, videos…); a light glyph for folders.
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
    /// Dimensions, duration, codecs… read from the file once it's selected.
    @State private var media: MediaInfo?
    /// Read once per item rather than on every redraw (sizes arriving redraw this often).
    @State private var lastOpened: Date?
    /// Registers the folder's size as on screen, so it's kept current while it's shown.
    @State private var sizeWatch = SizeWatch()

    private var sizes: FolderSizeStore { .shared }
    private var favorites: FavoritesStore { .shared }

    var body: some View {
        let preview = FilePreview.kind(for: item)
        VStack(alignment: .leading, spacing: 14) {
            if preview?.isLarge == true {
                FilePreview(item: item, model: model)
            }
            HStack(alignment: .top, spacing: 11) {
                if preview?.isLarge != true {
                    ItemPreview(item: item)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.name)
                        .font(.system(size: 13.5, weight: .semibold))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        TypeChip(item: item)
                        Text(isCurrentFolder ? "this folder" : item.kindDescription.lowercased())
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                    if let summary = media?.summary {
                        Text(summary)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Theme.accent)
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
                .help(FileActions.revealTitle)
            }

            if preview == .archive {
                Rectangle().fill(Theme.border).frame(height: 1)
                FilePreview(item: item, model: model)
            }

            if let media, !media.rows.isEmpty {
                Rectangle().fill(Theme.border).frame(height: 1)
                VStack(spacing: 6) {
                    ForEach(media.rows, id: \.self) { DetailRow(label: $0.label, value: $0.value) }
                }
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
                    .fixedSize(horizontal: false, vertical: true)
                Button("Copy Path") { FileActions.copyPaths([item.url]) }
                    .buttonStyle(SubtleButtonStyle())
            }
        }
        .onChange(of: item.url, initial: true) {
            sizes.show(item.isFolder ? [item.path] : [], by: sizeWatch)
        }
        .onDisappear { sizes.show([], by: sizeWatch) }
        .task(id: item.url) {
            media = nil
            lastOpened = try? item.url.resourceValues(forKeys: [.contentAccessDateKey]).contentAccessDate
            guard !item.isFolder || item.isPackage else { return }
            media = await MediaInfoReader.read(item.url, type: item.contentType, modified: item.modified)
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
                    .buttonStyle(GhostButtonStyle(padding: 3))
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
}

/// Stands for an inspector card with the size store, which follows what's on screen by owner.
private final class SizeWatch {}

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
                .truncationMode(.middle)
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

        let files = items.count - folders.count
        VStack(alignment: .leading, spacing: 4) {
            Text("\(urls.count) selected")
                .font(.system(size: 14, weight: .semibold))
            // As the single-item card's line under the name: what they are, and their size.
            HStack(spacing: 6) {
                Text([folders.isEmpty ? nil : "\(folders.count) \(folders.count == 1 ? "folder" : "folders")",
                      files == 0 ? nil : "\(files) \(files == 1 ? "file" : "files")",
                      Format.bytes(fileBytes + folderBytes)].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                if pending { ProgressView().controlSize(.mini) }
            }
            Button("Copy paths") { FileActions.copyPaths(urls) }
                .buttonStyle(SubtleButtonStyle())
                .padding(.top, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: urls) {
            let urls = urls
            items = await Task.detached(priority: .userInitiated) { urls.compactMap(FileItem.init(url:)) }.value
            FolderSizeStore.shared.request(items.filter(\.isFolder).map(\.path))
        }
    }
}
