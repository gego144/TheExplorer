import SwiftUI

/// Icon + name, with folders made unmistakable: medium weight and a trailing chevron.
struct FileNameLabel: View {
    let item: FileItem
    var iconSize: CGFloat = 16
    var showChevron = true

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: Icons.icon(for: item))
                .resizable()
                .frame(width: iconSize, height: iconSize)
                .overlay(alignment: .bottomLeading) {
                    if item.isSymlink {
                        Image(systemName: "arrow.turn.up.right")
                            .font(.system(size: iconSize * 0.4, weight: .bold))
                            .padding(1)
                            .background(.background, in: .rect(cornerRadius: 2))
                    }
                }
            Text(item.name)
                .fontWeight(item.isFolder ? .medium : .regular)
                .lineLimit(1)
                .truncationMode(.middle)
            if item.isFolder && showChevron {
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .opacity(item.isHidden ? 0.55 : 1)
    }
}

/// "Folder" gets an accent-tinted badge; files show their type.
struct KindLabel: View {
    let item: FileItem

    var body: some View {
        if item.isFolder {
            Label("Folder", systemImage: "folder.fill")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.tint)
                .font(.callout)
        } else {
            Text(item.kindDescription)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

/// Size text with a small proportional bar so the heavy hitters jump out.
struct SizeLabel: View {
    let bytes: Int64?
    var isCalculating = false
    var isPartial = false
    /// Largest size among siblings; drives the bar length. 0 hides the bar.
    var maxBytes: Int64 = 0

    var body: some View {
        HStack(spacing: 6) {
            if maxBytes > 0 {
                SizeBar(fraction: bytes.map { Double($0) / Double(maxBytes) } ?? 0)
                    .frame(width: 36, height: 5)
            }
            Spacer(minLength: 0)
            if let bytes {
                Text((isPartial ? "≥ " : "") + Format.bytes(bytes))
                    .monospacedDigit()
                    .help(isPartial ? "Some subfolders couldn't be read, so this is a minimum." : "")
            } else if isCalculating {
                ProgressView().controlSize(.mini)
            } else {
                Text("—").foregroundStyle(.tertiary)
            }
        }
    }
}

struct SizeBar: View {
    let fraction: Double
    var tint: Color = .accentColor

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(tint.gradient)
                    .frame(width: max(fraction > 0 ? 2 : 0, proxy.size.width * min(1, fraction)))
            }
        }
    }
}

/// The right-click menu shared by every list of files.
struct FileContextMenu: View {
    let urls: Set<URL>
    let model: BrowserModel
    var onTrash: ((Set<URL>) -> Void)?
    @Environment(\.openWindow) private var openWindow

    private var favorites: FavoritesStore { .shared }

    var body: some View {
        if !urls.isEmpty {
            let single = urls.count == 1 ? urls.first : nil
            Button("Open") { open() }
            let folders = urls.filter { FileItem(url: $0)?.isFolder == true }
            if !folders.isEmpty {
                Button(folders.count == 1 ? "Open in New Tab" : "Open \(folders.count) Folders in New Tabs") {
                    folders.sorted { $0.path < $1.path }.forEach { Tabs.open($0, with: openWindow) }
                }
            }
            if let single, let item = FileItem(url: single) {
                if item.isPackage {
                    Button("Show Package Contents") { model.navigate(to: single) }
                }
                if model.isSearching || model.destination != .folder || single.deletingLastPathComponent().standardizedFileURL != model.currentURL {
                    Button("Show in Enclosing Folder") { model.reveal(single) }
                }
            }
            Button("Quick Look") { model.quickLook(urls) }
            Divider()
            if let single {
                Button(favorites.contains(single) ? "Remove from Favorites" : "Add to Favorites") {
                    favorites.toggle(single)
                }
            } else {
                Button("Add to Favorites") { urls.forEach { favorites.add($0) } }
            }
            Button(urls.count == 1 ? "Copy Path" : "Copy Paths") { FileActions.copyPaths(urls) }
            Button("Reveal in Finder") { FileActions.revealInFinder(urls) }
            if let single, (try? single.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                Button("Open in Terminal") { FileActions.openInTerminal(single) }
            }
            if let single, let item = FileItem(url: single), model.destination == .folder, !model.isSearching {
                Button("Rename…") { model.renaming = item }
            }
            Divider()
            Button("Move to Trash", role: .destructive) {
                if let onTrash { onTrash(urls) } else { model.trash(urls) }
            }
        }
    }

    private func open() {
        for url in urls {
            if let item = FileItem(url: url) {
                if item.isFolder && urls.count == 1 {
                    model.navigate(to: url)
                } else {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}

/// Small horizontal rule-style header used above content panes.
struct PaneHeader<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 12) { content }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
    }
}

struct ErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(message).font(.callout).lineLimit(3)
            Spacer()
            if message.contains("Full Disk Access") {
                Button("Open Settings") { StorageModel.openFullDiskAccessSettings() }
            }
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.yellow.opacity(0.12))
    }
}
