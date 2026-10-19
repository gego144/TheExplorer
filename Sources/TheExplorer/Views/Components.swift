import SwiftUI

/// The right-click menu shared by every list of files.
struct FileContextMenu: View {
    let urls: Set<URL>
    let model: BrowserModel
    @Environment(\.openTab) private var openTab
    @Environment(\.splitWorkspace) private var split
    @Environment(\.listedItems) private var listed

    private var favorites: FavoritesStore { .shared }

    /// From the list when it's there: a selection can be thousands of items.
    private func item(_ url: URL) -> FileItem? { listed?.item(url) ?? FileItem(url: url) }

    var body: some View {
        if !urls.isEmpty {
            let single = urls.count == 1 ? urls.first : nil
            Button("Open") { open() }
            if urls.allSatisfy(\.isFileURL) {
                OpenWithMenu(urls: urls)
            }
            let folders = urls.filter { item($0)?.isFolder == true }
            if !folders.isEmpty {
                Button(folders.count == 1 ? "Open in New Tab" : "Open \(folders.count) Folders in New Tabs") {
                    folders.sorted { $0.path < $1.path }.forEach(openTab)
                }
            }
            if let single, let item = item(single) {
                if item.isPackage {
                    Button("Show Package Contents") { model.navigate(to: single) }
                }
                if model.isSearching || model.destination != .folder || single.deletingLastPathComponent().standardizedFileURL != model.currentURL {
                    Button("Show in Enclosing Folder") { model.reveal(single) }
                }
            }
            Button("Quick Look") { model.quickLook(urls) }
            ActionsMenu(urls: urls)
            Divider()
            // Sorted when chosen, not while the menu is built: selections can be thousands.
            if urls.allSatisfy(\.isFileURL) {
                Button("Cut") { FileClipboard.shared.cut(sortedURLs) }
            }
            Button("Copy") { FileClipboard.shared.copy(sortedURLs) }
            if urls.allSatisfy(\.isFileURL) {
                Button("Duplicate") { model.duplicate(urls) }
            }
            PasteItems(model: model, folder: single.flatMap { item($0)?.isFolder == true ? $0 : nil })
            if let split, let other = split.pane(oppositeTo: model), split.dropFolder(of: other) != nil {
                Divider()
                Button("Copy to Other Pane") { split.sendToOtherPane(urls, from: model, mode: .copy) }
                if urls.allSatisfy(\.isFileURL) {
                    Button("Move to Other Pane") { split.sendToOtherPane(urls, from: model, mode: .move) }
                }
            }
            Divider()
            if let single {
                Button(favorites.contains(single) ? "Unpin" : "Pin to Sidebar") {
                    favorites.toggle(single)
                }
            } else {
                Button("Pin to Sidebar") { urls.forEach { favorites.add($0) } }
            }
            Button(urls.count == 1 ? "Copy Path" : "Copy Paths") { FileActions.copyPaths(urls) }
            Button(FileActions.revealTitle) { FileActions.revealInFinder(urls) }
            if let single {
                let isFolder = item(single)?.isFolder == true
                Button(isFolder ? FileActions.openInTerminalTitle : "Open Enclosing Folder in \(Prefs.shared.terminal.name)") {
                    FileActions.openInTerminal(isFolder ? single : single.deletingLastPathComponent())
                }
            }
            if let single, let item = item(single), model.destination == .folder, !model.isSearching {
                Button("Rename…") { model.renaming = item }
            }
            Divider()
            Button("Move to Trash", role: .destructive) { model.trash(urls) }
        }
    }

    private var sortedURLs: [URL] {
        urls.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func open() {
        if urls.count == 1, let url = urls.first, item(url)?.isFolder == true {
            model.navigate(to: url)
        } else {
            FileOpener.open(urls.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending })
        }
    }
}

/// Paste into the folder being shown, and into a right-clicked folder.
struct PasteItems: View {
    let model: BrowserModel
    /// A folder that was right-clicked, offered as somewhere to paste too.
    var folder: URL?

    var body: some View {
        let count = FileClipboard.shared.urls.count
        let noun = count > 1 ? " \(count) Items" : ""
        if model.pasteTarget != nil {
            Button("Paste\(noun)") { model.paste() }
                .disabled(count == 0)
        }
        if let folder {
            Button("Paste\(noun) into “\(folder.lastPathComponent)”") { model.paste(into: folder) }
                .disabled(count == 0)
        }
    }
}

/// Bar at the top of a pane (search, recents, storage) holding its controls.
struct PaneHeader<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 10) { content }
            .font(.system(size: 12))
            .padding(.horizontal, 12)
            .frame(height: 40)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}

/// A one-line notice with an optional action.
struct Banner: View {
    let symbol: String
    let tint: Color
    let text: String
    var actionTitle: String?
    var action: (() -> Void)?
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.text)
                .lineLimit(3)
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(SubtleButtonStyle())
            }
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(GhostButtonStyle(padding: 4))
                .help("Dismiss")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(tint.opacity(0.08))
        .overlay(alignment: .bottom) { Rectangle().fill(tint.opacity(0.25)).frame(height: 1) }
    }
}

struct ErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        let needsAccess = message.contains("Full Disk Access")
        Banner(symbol: "exclamationmark.triangle.fill", tint: Theme.danger, text: message,
               actionTitle: needsAccess ? "Open Settings" : nil,
               action: needsAccess ? { StorageModel.openFullDiskAccessSettings() } : nil,
               onDismiss: onDismiss)
    }
}

/// Monochrome on/off switch: a light track with a dark knob when on, a dim track when off.
struct WorkbenchSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Hovering { hovering in
            Button {
                configuration.isOn.toggle()
            } label: {
                Capsule()
                    .fill(configuration.isOn ? Theme.accent : (hovering ? Theme.borderHover : Theme.fieldBorder))
                    .frame(width: 30, height: 17)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle()
                            .fill(configuration.isOn ? Theme.background : (hovering ? Theme.text : Theme.textSecondary))
                            .frame(width: 13, height: 13)
                            .padding(2)
                    }
                    .opacity(hovering && configuration.isOn ? 0.88 : 1)
                    .animation(.easeOut(duration: 0.12), value: configuration.isOn)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .clickable()
        }
    }
}


