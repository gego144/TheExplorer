import SwiftUI

struct RecentsView: View {
    @Bindable var model: BrowserModel
    @Environment(\.openTab) private var openTab

    var body: some View {
        @Bindable var recents = model.recents
        let rows = recents.sections.flatMap { section in
            section.items.map { recent in
                ListRow(
                    item: recent.item,
                    size: recent.item.isFolder ? nil : recent.item.fileSize,
                    date: recent.date,
                    location: recent.item.url.deletingLastPathComponent().path,
                    group: section.title
                )
            }
        }

        VStack(spacing: 0) {
            PaneHeader {
                Segmented(selection: $recents.dateKind, options: RecentsDateKind.allCases.map { ($0, $0.rawValue) })
                    .fixedSize()
                    .help("Created: when it was made. Modified: last content change. Added: when it arrived in its folder (downloads, copies, moves).")
                Menu {
                    Picker("Within", selection: $recents.range) {
                        ForEach(RecentsRange.allCases) { Text("Last \($0.label)").tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    MenuLabel(title: "Last \(recents.range.label)")
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                Segmented(selection: $recents.kindFilter, options: [(.all, "All"), (.folders, "Dirs"), (.files, "Files")])
                    .fixedSize()
                Toggle(isOn: $recents.hideNoise) {
                    Text("Hide clutter").font(.system(size: 11.5))
                }
                .toggleStyle(.checkbox)
                .help("Hides items inside Library, hidden folders, app bundles and dependency folders like node_modules and .git.")
                Spacer(minLength: 0)
                Text(countDescription(recents, shown: rows.count))
                    .font(Theme.mono)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .layoutPriority(-1)
            }

            FileListView(
                rows: rows,
                selection: $recents.selection,
                dateTitle: recents.dateKind.rawValue,
                showLocation: true,
                empty: recents.isGathering ? nil : EmptyState(
                    symbol: "clock", title: "Nothing new here",
                    hint: "Nothing in your home folder matches these filters. Try a longer time range."),
                focusRequest: model.listFocusRequest,
                onOpen: { urls, newTab in
                    let items = rows.filter { urls.contains($0.id) }.map(\.item)
                    if newTab {
                        items.filter(\.isFolder).forEach { openTab($0.url) }
                    } else if items.count == 1, let item = items.first {
                        model.open(item)
                    } else {
                        items.forEach { NSWorkspace.shared.open($0.url) }
                    }
                },
                onQuickLook: { model.quickLook($0) },
                rowMenu: { FileContextMenu(urls: $0, model: model) },
                backgroundMenu: { EmptyView() }
            )
        }
        .onAppear { recents.start() }
        .onDisappear { recents.stop() }
    }

    private func countDescription(_ recents: RecentsModel, shown: Int) -> String {
        if recents.totalCount > shown {
            return "\(shown.formatted()) newest of \(recents.totalCount.formatted())"
        }
        return "\(shown.formatted()) items"
    }
}

/// Menu button label in the Workbench style.
struct MenuLabel: View {
    let title: String

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold))
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Theme.field, in: .rect(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.fieldBorder))
    }
}
