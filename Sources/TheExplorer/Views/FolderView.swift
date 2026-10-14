import SwiftUI

struct FolderView: View {
    @Bindable var model: BrowserModel
    @Environment(\.openWindow) private var openWindow
    @SceneStorage("folderColumns") private var columnCustomization: TableColumnCustomization<FileRow>

    var body: some View {
        let rows = model.rows
        let maxSize = rows.compactMap(\.displaySize).max() ?? 0
        let sizes = FolderSizeStore.shared

        VStack(spacing: 0) {
            PathBar(model: model)
            if let error = model.loadError {
                ErrorBanner(message: error) { model.dismissError() }
            }
            Table(of: FileRow.self, selection: $model.selection, sortOrder: $model.sortOrder, columnCustomization: $columnCustomization) {
                TableColumn("Name", value: \.name, comparator: .localizedStandard) { row in
                    FileNameLabel(item: row.item)
                }
                .width(min: 180, ideal: 340)
                .customizationID("name")
                .disabledCustomizationBehavior(.visibility)

                TableColumn("Size", value: \.sortSize) { row in
                    SizeLabel(
                        bytes: row.displaySize,
                        isCalculating: row.item.isFolder && sizes.isCalculating(row.item.path),
                        isPartial: row.folderSize.map { !$0.complete } ?? false,
                        maxBytes: maxSize
                    )
                }
                .width(min: 90, ideal: 120)
                .customizationID("size")

                TableColumn("Kind", value: \.kind) { row in
                    KindLabel(item: row.item)
                }
                .width(min: 80, ideal: 140)
                .customizationID("kind")

                TableColumn("Date Modified", value: \.modified) { row in
                    Text(Format.date(row.item.modified)).foregroundStyle(.secondary)
                }
                .width(min: 110, ideal: 170)
                .customizationID("modified")

                TableColumn("Date Created", value: \.created) { row in
                    Text(Format.date(row.item.created)).foregroundStyle(.secondary)
                }
                .width(min: 110, ideal: 170)
                .customizationID("created")

                TableColumn("Items", value: \.fileCount) { row in
                    if row.item.isFolder, let files = row.folderSize?.files {
                        Text("\(files.formatted()) files").foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .width(min: 70, ideal: 90)
                .customizationID("items")
                .defaultVisibility(.hidden)
            } rows: {
                ForEach(rows) { row in
                    TableRow(row).draggable(row.item.url)
                }
            }
            .contextMenu(forSelectionType: URL.self) { urls in
                FileContextMenu(urls: urls, model: model)
            } primaryAction: { urls in
                let folders = model.items.filter { urls.contains($0.url) && $0.isFolder }
                if NSEvent.modifierFlags.contains(.command), !folders.isEmpty {
                    folders.forEach { Tabs.open($0.url, with: openWindow) }
                } else {
                    model.open(urls: urls)
                }
            }
            .onKeyPress(.space) {
                model.quickLook()
                return .handled
            }
            .overlay {
                if rows.isEmpty && !model.isLoading && model.loadError == nil {
                    ContentUnavailableView(
                        model.items.isEmpty ? "Empty Folder" : "Nothing to Show",
                        systemImage: "folder",
                        description: Text(model.items.isEmpty ? "This folder has no items." : "Hidden files or the current filter are hiding everything here.")
                    )
                }
            }
            StatusBar(model: model, rows: rows)
        }
    }
}

/// Clickable breadcrumb of the current location. ⌘L (or the pencil) turns it into a path field.
struct PathBar: View {
    @Bindable var model: BrowserModel
    @State private var draft = ""
    @State private var invalid = false
    @FocusState private var fieldFocused: Bool
    private static let endMarker = "path-end"

    private var trail: [URL] {
        var urls: [URL] = []
        var url = model.currentURL
        while true {
            urls.insert(url, at: 0)
            if url.isRoot { break }
            url = url.deletingLastPathComponent().standardizedFileURL
        }
        return urls
    }

    var body: some View {
        HStack(spacing: 6) {
            if model.isEditingPath {
                Image(systemName: "arrow.right.circle").foregroundStyle(.secondary)
                TextField("Go to path (e.g. ~/Downloads)", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.callout.monospaced())
                    .focused($fieldFocused)
                    .onSubmit(submit)
                    .onExitCommand { model.isEditingPath = false }
                    .foregroundStyle(invalid ? .red : .primary)
                    .onChange(of: draft) { invalid = false }
                    .onAppear {
                        draft = Format.path(model.currentURL.path)
                        fieldFocused = true
                    }
                Button("Cancel") { model.isEditingPath = false }
                    .buttonStyle(.borderless)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 2) {
                            ForEach(Array(trail.enumerated()), id: \.element) { index, url in
                                if index > 0 {
                                    Image(systemName: "chevron.compact.right")
                                        .foregroundStyle(.tertiary)
                                }
                                PathSegment(url: url, isCurrent: index == trail.count - 1) {
                                    model.navigate(to: url, select: index + 1 < trail.count ? trail[index + 1] : nil)
                                }
                            }
                            Color.clear.frame(width: 8, height: 1).id(Self.endMarker)
                        }
                        .padding(.vertical, 1)
                    }
                    .onAppear { proxy.scrollTo(Self.endMarker, anchor: .trailing) }
                    .onChange(of: model.currentURL) { proxy.scrollTo(Self.endMarker, anchor: .trailing) }
                }
                // Take exactly the leftover width so long paths scroll instead of sliding under the buttons.
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(-1)
                Button {
                    model.isEditingPath = true
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help("Type a path (⌘L)")
                Button {
                    FileActions.copyPaths([model.currentURL])
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy this folder's path")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func submit() {
        if model.goTo(path: draft) {
            model.isEditingPath = false
        } else {
            invalid = true
        }
    }
}

private struct PathSegment: View {
    let url: URL
    let isCurrent: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(nsImage: Icons.icon(forPath: url.path))
                    .resizable()
                    .frame(width: 14, height: 14)
                Text(FileManager.default.displayName(atPath: url.path))
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .lineLimit(1)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Copy Path") { FileActions.copyPaths([url]) }
            Button("Reveal in Finder") { FileActions.revealInFinder([url]) }
            Button(FavoritesStore.shared.contains(url) ? "Remove from Favorites" : "Add to Favorites") {
                FavoritesStore.shared.toggle(url)
            }
        }
    }
}

private struct StatusBar: View {
    let model: BrowserModel
    let rows: [FileRow]

    var body: some View {
        let folders = rows.filter(\.item.isFolder).count
        let files = rows.count - folders
        let selected = rows.filter { model.selection.contains($0.id) }
        let selectedBytes = selected.compactMap(\.displaySize).reduce(0, +)
        let hiddenCount = model.showHidden ? 0 : model.items.filter(\.isHidden).count

        HStack(spacing: 10) {
            Text("\(folders.formatted()) \(folders == 1 ? "folder" : "folders"), \(files.formatted()) \(files == 1 ? "file" : "files")")
            if hiddenCount > 0 {
                Text("· \(hiddenCount.formatted()) hidden").foregroundStyle(.tertiary)
            }
            if !selected.isEmpty {
                Text("· \(selected.count.formatted()) selected" + (selectedBytes > 0 ? " (\(Format.bytes(selectedBytes)))" : ""))
            }
            Spacer()
            if model.isLoading {
                ProgressView().controlSize(.small)
            }
            if let available = availableSpace {
                Text("\(Format.bytes(available)) available")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var availableSpace: Int64? {
        let values = try? model.currentURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
