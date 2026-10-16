import SwiftUI

/// Recents (documents you've opened, like Finder) and New (what appeared recently). Newest
/// first and grouped by day; clicking a column header sorts the loaded items instead.
struct RecentsView: View {
    @Bindable var model: BrowserModel
    @Bindable var recents: RecentsModel
    /// nil keeps the grouped, newest-first order.
    @State private var sort: SortSpec?
    @Environment(\.openTab) private var openTab

    private static let newestFirst = SortSpec(key: .date, ascending: false)

    var body: some View {
        let rows = sortedRows

        VStack(spacing: 0) {
            PaneHeader {
                if recents.mode == .new {
                    Segmented(selection: $recents.dateKind, options: RecentsDateKind.allCases.map { ($0, $0.rawValue) })
                        .fixedSize()
                        .help("Created: when it was made. Modified: last content change. Added: when it arrived in its folder (downloads, copies, moves).")
                }
                ChromeMenu {
                    Picker("Within", selection: $recents.range) {
                        ForEach(RecentsRange.options(for: recents.mode)) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Text(recents.range.title)
                }
                if recents.mode == .new {
                    Segmented(selection: $recents.kindFilter, options: [(.all, "All"), (.folders, "Dirs"), (.files, "Files")])
                        .fixedSize()
                    Toggle(isOn: $recents.hideNoise) {
                        Text("Hide clutter").font(.system(size: 11.5))
                    }
                    .toggleStyle(.checkbox)
                    .help("Hides items inside Library, hidden folders, app bundles and dependency folders like node_modules and .git.")
                } else {
                    Text("Documents you've opened, newest first")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(countDescription(shown: rows.count))
                    .font(Theme.mono)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .layoutPriority(-1)
            }

            FileListView(
                rows: rows,
                selection: $recents.selection,
                sort: sort ?? Self.newestFirst,
                onSort: { key in
                    let next = (sort ?? Self.newestFirst).toggled(to: key)
                    sort = next == Self.newestFirst ? nil : next
                },
                dateTitle: recents.dateTitle,
                dateSortKey: .date,
                showLocation: true,
                empty: recents.isGathering ? nil : emptyState,
                focusRequest: model.listFocusRequest,
                onOpen: { urls, newTab in
                    let items = rows.filter { urls.contains($0.id) }.map(\.item)
                    if newTab {
                        items.filter(\.isFolder).forEach { openTab($0.url) }
                    } else if items.count == 1, let item = items.first {
                        model.open(item)
                    } else {
                        FileOpener.open(items.map(\.url))
                    }
                },
                onQuickLook: { model.quickLook($0, in: $1) },
                onReachEnd: { recents.loadMore() },
                footer: AnyView(footer),
                rowMenu: { FileContextMenu(urls: $0, model: model) },
                backgroundMenu: { EmptyView() }
            )
        }
        .onAppear { recents.start() }
        .onDisappear { recents.stop() }
    }

    /// Grouped newest-first as delivered, or re-sorted (without groups) by the chosen column.
    private var sortedRows: [ListRow] {
        guard let sort else { return recents.rows }
        let sizes = FolderSizeStore.shared
        let flat = recents.rows.map { row in
            var row = row
            row.group = nil
            return row
        }
        return RowSorter.sorted(flat, by: sort) { sizes.size(for: $0)?.bytes }
    }

    /// Below the last row: more loading, or the end of the range with a way to go further back.
    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 8) {
            if recents.hasMore {
                ProgressView().controlSize(.mini)
                Text("Loading older items…")
            } else if let wider = recents.range.wider(for: recents.mode) {
                Text("That's everything from the \(recents.range.title.lowercased()).")
                Button("Show \(wider.title.lowercased())") { recents.range = wider }
                    .buttonStyle(SubtleButtonStyle())
            } else {
                Text("That's everything.")
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Theme.textTertiary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }

    private var emptyState: EmptyState {
        switch recents.mode {
        case .opened:
            EmptyState(symbol: "clock", title: "Nothing opened yet",
                       hint: "Documents you open show up here, newest first.")
        case .new:
            EmptyState(symbol: "sparkles", title: "Nothing new here",
                       hint: "Nothing in your home folder matches these filters. Try a longer time range.")
        }
    }

    private func countDescription(shown: Int) -> String {
        guard let total = recents.totalCount else {
            return "\(shown.formatted())\(recents.hasMore ? "+" : "") items"
        }
        if total > shown { return "\(shown.formatted()) of \(total.formatted())" }
        return "\(shown.formatted()) \(shown == 1 ? "item" : "items")"
    }
}

