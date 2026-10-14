import SwiftUI

private struct HitRow: Identifiable {
    let hit: SearchHit
    let folderSize: FolderSize?

    var id: URL { hit.id }
    var item: FileItem { hit.item }
    var name: String { item.name }
    var location: String { item.url.deletingLastPathComponent().path }
    var kind: String { item.kindDescription }
    var size: Int64? { item.isFolder ? folderSize?.bytes : item.fileSize }
    var sortSize: Int64 { size ?? -1 }
    var modified: Date { item.modified ?? .distantPast }
}

struct SearchResultsView: View {
    @Bindable var model: BrowserModel
    @State private var sortOrder: [KeyPathComparator<HitRow>] = []

    private var search: SearchModel { model.search }

    var body: some View {
        @Bindable var search = model.search
        let sizes = FolderSizeStore.shared
        var rows = search.visibleHits.map { HitRow(hit: $0, folderSize: $0.item.isFolder ? sizes.size(for: $0.item.path) : nil) }
        // With no column sort chosen, keep relevance order.
        if !sortOrder.isEmpty { rows.sort(using: sortOrder) }

        return VStack(spacing: 0) {
            PaneHeader {
                Image(systemName: model.searchScope == .mac ? "macbook" : "folder")
                    .foregroundStyle(.secondary)
                Text(scopeDescription)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if search.isRunning {
                    ProgressView().controlSize(.small)
                    if model.searchScope == .folder && search.scannedCount > 0 {
                        Text("\(search.scannedCount.formatted()) checked")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                Text(countDescription(rows.count))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Picker("Show", selection: $search.kindFilter) {
                    ForEach(KindFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            Table(of: HitRow.self, selection: $search.selection, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.name, comparator: .localizedStandard) { row in
                    FileNameLabel(item: row.item)
                }
                .width(min: 180, ideal: 280)
                TableColumn("Location", value: \.location, comparator: .localizedStandard) { row in
                    Text(Format.path(row.location))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(row.location)
                }
                .width(min: 140, ideal: 280)
                TableColumn("Size", value: \.sortSize) { row in
                    SizeLabel(bytes: row.size)
                }
                .width(min: 70, ideal: 90)
                TableColumn("Kind", value: \.kind) { row in
                    KindLabel(item: row.item)
                }
                .width(min: 80, ideal: 130)
                TableColumn("Date Modified", value: \.modified) { row in
                    Text(Format.date(row.item.modified)).foregroundStyle(.secondary)
                }
                .width(min: 110, ideal: 160)
            } rows: {
                ForEach(rows) { row in
                    TableRow(row).draggable(row.item.url)
                }
            }
            .contextMenu(forSelectionType: URL.self) { urls in
                FileContextMenu(urls: urls, model: model)
            } primaryAction: { urls in
                guard let url = urls.first, let row = rows.first(where: { $0.id == url }) else { return }
                if urls.count == 1 {
                    model.open(row.item)
                } else {
                    urls.forEach { NSWorkspace.shared.open($0) }
                }
            }
            .onKeyPress(.space) {
                model.quickLook(search.selection)
                return .handled
            }
            .overlay {
                if rows.isEmpty && !search.isRunning {
                    ContentUnavailableView.search(text: model.searchText)
                }
            }
            .onChange(of: search.selection) {
                // Measure folders as you click them so their size shows up in the inspector.
                let folders = rows.filter { search.selection.contains($0.id) && $0.item.isFolder }.map(\.item.path)
                FolderSizeStore.shared.request(folders)
            }

            if model.searchScope == .mac {
                Text("Entire Mac uses the Spotlight index, so hidden, system and excluded folders aren't searched. Use This Folder for an exhaustive search.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(.bar)
            }
        }
    }

    private var scopeDescription: String {
        switch model.searchScope {
        case .mac: "Searching your entire Mac"
        case .folder: "Searching in “\(FileManager.default.displayName(atPath: model.currentURL.path))” and its subfolders"
        }
    }

    private func countDescription(_ count: Int) -> String {
        let base = "\(count.formatted()) \(count == 1 ? "result" : "results")"
        return search.truncated ? base + " (showing best matches)" : base
    }
}
