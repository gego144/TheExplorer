import SwiftUI

/// The right-click menu shared by every list of files.
struct FileContextMenu: View {
    let urls: Set<URL>
    let model: BrowserModel
    @Environment(\.openTab) private var openTab

    private var favorites: FavoritesStore { .shared }

    var body: some View {
        if !urls.isEmpty {
            let single = urls.count == 1 ? urls.first : nil
            Button("Open") { open() }
            let folders = urls.filter { FileItem(url: $0)?.isFolder == true }
            if !folders.isEmpty {
                Button(folders.count == 1 ? "Open in New Tab" : "Open \(folders.count) Folders in New Tabs") {
                    folders.sorted { $0.path < $1.path }.forEach(openTab)
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
            ActionsMenu(urls: urls)
            Divider()
            let sorted = urls.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            if urls.allSatisfy(\.isFileURL) {
                Button("Cut") { FileClipboard.shared.cut(sorted) }
            }
            Button("Copy") { FileClipboard.shared.copy(sorted) }
            if urls.allSatisfy(\.isFileURL) {
                Button("Duplicate") { model.duplicate(urls) }
            }
            PasteItems(model: model, folder: single.flatMap { FileItem(url: $0)?.isFolder == true ? $0 : nil })
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
                let isFolder = FileItem(url: single)?.isFolder == true
                Button(isFolder ? FileActions.openInTerminalTitle : "Open Enclosing Folder in \(Prefs.shared.terminal.name)") {
                    FileActions.openInTerminal(isFolder ? single : single.deletingLastPathComponent())
                }
            }
            if let single, let item = FileItem(url: single), model.destination == .folder, !model.isSearching {
                Button("Rename…") { model.renaming = item }
            }
            Divider()
            Button("Move to Trash", role: .destructive) { model.trash(urls) }
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
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
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

/// Filled light button for the one primary action in a view.
struct AccentButtonStyle: ButtonStyle {
    var large = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: large ? 13 : 11.5, weight: .semibold))
            .foregroundStyle(Theme.background)
            .padding(.horizontal, large ? 16 : 11)
            .padding(.vertical, large ? 7 : 4)
            .background(Theme.accent.opacity(configuration.isPressed ? 0.75 : 1), in: .rect(cornerRadius: 7))
    }
}

/// Monochrome on/off switch: a light track with a dark knob when on, a dim track when off.
struct WorkbenchSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            Capsule()
                .fill(configuration.isOn ? Theme.accent : Theme.fieldBorder)
                .frame(width: 30, height: 17)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle()
                        .fill(configuration.isOn ? Theme.background : Theme.textSecondary)
                        .frame(width: 13, height: 13)
                        .padding(2)
                }
                .animation(.easeOut(duration: 0.12), value: configuration.isOn)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
    }
}

/// Quiet raised button for secondary actions.
struct SubtleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(configuration.isPressed ? Theme.hover : Theme.raised, in: .rect(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.fieldBorder))
    }
}
