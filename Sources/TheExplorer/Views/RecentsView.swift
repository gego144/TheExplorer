import SwiftUI

struct RecentsView: View {
    @Bindable var model: BrowserModel

    var body: some View {
        @Bindable var recents = model.recents

        VStack(spacing: 0) {
            PaneHeader {
                Picker("Date", selection: $recents.dateKind) {
                    ForEach(RecentsDateKind.allCases) { Text("By Date \($0.rawValue)").tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .help("Created: when the item was made. Modified: last content change. Added: when it arrived in its folder (downloads, copies, moves).")

                Picker("Within", selection: $recents.range) {
                    ForEach(RecentsRange.allCases) { Text("Last \($0.label)").tag($0) }
                }
                .labelsHidden()
                .fixedSize()

                Picker("Show", selection: $recents.kindFilter) {
                    Text("Files & Folders").tag(KindFilter.all)
                    Text("Folders Only").tag(KindFilter.folders)
                    Text("Files Only").tag(KindFilter.files)
                }
                .labelsHidden()
                .fixedSize()

                Toggle("Hide clutter", isOn: $recents.hideNoise)
                    .toggleStyle(.checkbox)
                    .help("Hides items inside Library, hidden folders, app bundles and dependency folders like node_modules and .git.")

                Spacer(minLength: 0)
                if recents.isGathering {
                    ProgressView().controlSize(.small)
                }
                Text(countDescription(recents))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .layoutPriority(-1)
            }

            List(selection: $recents.selection) {
                ForEach(recents.sections) { section in
                    Section {
                        ForEach(section.items) { recent in
                            RecentRow(recent: recent, dateKind: recents.dateKind)
                                .tag(recent.id)
                                .draggable(recent.item.url)
                        }
                    } header: {
                        Text(section.title)
                    }
                }
            }
            .listStyle(.inset)
            .alternatingRowBackgrounds()
            .contextMenu(forSelectionType: URL.self) { urls in
                FileContextMenu(urls: urls, model: model)
            } primaryAction: { urls in
                if urls.count == 1, let url = urls.first, let item = FileItem(url: url) {
                    model.open(item)
                } else {
                    urls.forEach { NSWorkspace.shared.open($0) }
                }
            }
            .onKeyPress(.space) {
                model.quickLook(recents.selection)
                return .handled
            }
            .overlay {
                if recents.sections.isEmpty && !recents.isGathering {
                    ContentUnavailableView("Nothing New", systemImage: "clock",
                                           description: Text("No items in your home folder match these filters."))
                }
            }
        }
        .onAppear { recents.start() }
        .onDisappear { recents.stop() }
    }

    private func countDescription(_ recents: RecentsModel) -> String {
        let shown = recents.sections.reduce(0) { $0 + $1.items.count }
        if recents.totalCount > shown {
            return "\(shown.formatted()) newest of \(recents.totalCount.formatted())"
        }
        return "\(shown.formatted()) \(shown == 1 ? "item" : "items")"
    }
}

private struct RecentRow: View {
    let recent: RecentItem
    let dateKind: RecentsDateKind

    var body: some View {
        let item = recent.item
        HStack(spacing: 10) {
            Image(nsImage: Icons.icon(for: item))
                .resizable()
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .fontWeight(item.isFolder ? .semibold : .regular)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if item.isFolder {
                        Text("FOLDER")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.tint)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.tint.opacity(0.15), in: .capsule)
                    }
                }
                Text(Format.path(item.url.deletingLastPathComponent().path))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 12)
            if let size = item.fileSize, !item.isFolder {
                Text(Format.bytes(size))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            VStack(alignment: .trailing, spacing: 2) {
                Text(Format.relative(recent.date))
                    .font(.callout)
                Text("\(dateKind.rawValue) \(recent.date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 150, alignment: .trailing)
        }
        .padding(.vertical, 3)
    }
}
