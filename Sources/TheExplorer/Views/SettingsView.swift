import SwiftUI

/// Settings (⌘,). General: the default file browser, the terminal to open folders in, where new
/// windows start, and the defaults new tabs begin with. Actions: your shell commands for files.
/// Open With: the apps that open file types from TheExplorer.
struct SettingsView: View {
    @Bindable private var prefs = Prefs.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Segmented(selection: $prefs.settingsTab, options: [(.general, "General"), (.actions, "Actions"), (.openWith, "Open With"), (.cloud, "Cloud")])
                .fixedSize()
                .frame(maxWidth: .infinity)
            switch prefs.settingsTab {
            case .general: general
            case .actions: ActionsSettings()
            case .openWith: OpenWithSettings()
            case .cloud: CloudSettings()
            }
        }
        .toggleStyle(WorkbenchSwitchStyle())
        .controlSize(.small)
        .padding(20)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.background)
        .preferredColorScheme(.dark)
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 18) {
            section("Default file browser") {
                SettingRow("“Show in Finder” opens", hint: "Where other apps’ “Show in Finder” and “Reveal” buttons show files. Applies right away.") {
                    FileViewerPicker(prefs: prefs)
                }
                RowDivider()
                SettingRow("Folders open in", hint: folderOpenerHint) {
                    AppName(bundleID: prefs.folderOpenerID)
                }
            }

            section("Terminal") {
                SettingRow("Open folders in", hint: "Used by Open in Terminal (⌃⌘T) and the right-click menus.") {
                    TerminalPicker(selection: $prefs.terminalID)
                }
            }

            section("Search") {
                SettingRow("Index", hint: "Your home folder, Applications, iCloud Drive and cloud storage, kept current as files change. Library, hidden folders, the insides of apps, folders like node_modules and anything a project’s .gitignore lists are left out.") {
                    SearchIndexStatus()
                }
            }

            section("New windows") {
                SettingRow("Start in", hint: startHint) {
                    StartLocationPicker(prefs: prefs)
                }
            }

            section("Browsing defaults") {
                SettingRow("Sort by", hint: "New tabs start with this order; click a column header to change it per tab.") {
                    HStack(spacing: 6) {
                        ChromeMenu {
                            Picker("Sort by", selection: $prefs.defaultSort.key) {
                                ForEach(Self.sortKeys, id: \.self) { Text(Self.title(for: $0)).tag($0) }
                            }
                            .pickerStyle(.inline)
                        } label: {
                            Text(Self.title(for: prefs.defaultSort.key))
                        }
                        Segmented(selection: $prefs.defaultSort.ascending,
                                  options: [(false, Self.directionTitle(prefs.defaultSort.key, ascending: false)),
                                            (true, Self.directionTitle(prefs.defaultSort.key, ascending: true))])
                            .fixedSize()
                    }
                }
                RowDivider()
                SettingRow("Folders first") { Toggle("", isOn: $prefs.foldersFirst).labelsHidden() }
                RowDivider()
                SettingRow("Show hidden files", hint: "⇧⌘. toggles this in any tab.") {
                    Toggle("", isOn: $prefs.showHidden).labelsHidden()
                }
            }

            section("New") {
                SettingRow("Time range") {
                    ChromeMenu {
                        Picker("Time range", selection: $prefs.newRange) {
                            ForEach(RecentsRange.options(for: .new)) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Text(prefs.newRange.title)
                    }
                }
                RowDivider()
                SettingRow("Hide clutter", hint: "Leaves out Library, hidden folders and dependency folders like node_modules.") {
                    Toggle("", isOn: $prefs.newHidesClutter).labelsHidden()
                }
            }
        }
    }

    private var folderOpenerHint: String {
        if prefs.folderOpenerID.caseInsensitiveCompare(FolderHandler.thisAppID) == .orderedSame {
            return "Folders opened from other apps, the Dock and Spotlight open here."
        }
        return "macOS keeps Finder for folders opened from other apps, the Dock and Spotlight, and doesn’t let other apps take that over. To open a folder here from Finder, right-click it and choose Open With › TheExplorer."
    }

    private var startHint: String {
        switch prefs.startLocation {
        case .lastFolder: "Wherever you were last. Windows open at launch restore their own tabs."
        case .home: "Your home folder."
        case .custom: Format.path(prefs.startFolder)
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionCaption(title: title)
            VStack(spacing: 0) { content() }
                .panel(padding: 0)
        }
    }

    private static let sortKeys: [SortKey] = [.modified, .name, .size, .kind, .created]

    private static func title(for key: SortKey) -> String {
        switch key {
        case .modified, .date: "Changed"
        case .name: "Name"
        case .size: "Size"
        case .kind: "Type"
        case .created: "Created"
        }
    }

    private static func directionTitle(_ key: SortKey, ascending: Bool) -> String {
        switch key {
        case .modified, .created, .date: ascending ? "Oldest first" : "Newest first"
        case .size: ascending ? "Smallest first" : "Largest first"
        case .name, .kind: ascending ? "A to Z" : "Z to A"
        }
    }
}

/// How big the search index is, with a way to rebuild it.
private struct SearchIndexStatus: View {
    private let status = IndexStatus.shared

    var body: some View {
        HStack(spacing: 8) {
            Text(status.isReady ? "\(status.itemCount.formatted()) items" : "Building…")
                .font(Theme.mono)
                .foregroundStyle(Theme.textSecondary)
            Button("Rebuild") { FileIndex.shared.rebuildNow() }
                .buttonStyle(SubtleButtonStyle())
        }
        .fixedSize()
    }
}

private struct RowDivider: View {
    var body: some View {
        Rectangle().fill(Theme.border).frame(height: 1).padding(.leading, 12)
    }
}

/// A label (and optional hint) on the left, its control on the right.
private struct SettingRow<Control: View>: View {
    let title: String
    let hint: String?
    let control: Control

    init(_ title: String, hint: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.hint = hint
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.text)
                if let hint {
                    Text(hint)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

/// Installed terminals with their icons, plus any other app you pick.
private struct TerminalPicker: View {
    @Binding var selection: String

    var body: some View {
        let terminals = Terminal.available(including: selection)
        ChromeMenu {
            ForEach(terminals) { terminal in
                Button {
                    selection = terminal.bundleID
                } label: {
                    if let icon = terminal.icon {
                        Label { Text(terminal.name) } icon: { Image(nsImage: icon) }
                    } else {
                        Text(terminal.name)
                    }
                }
            }
            Divider()
            Button("Other App…", action: chooseOther)
        } label: {
            HStack(spacing: 6) {
                if let icon = Terminal(bundleID: selection).icon {
                    Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                }
                Text(Terminal(bundleID: selection).name)
            }
        }
    }

    private func chooseOther() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Use App"
        guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else { return }
        selection = id
    }
}

/// Chooses where other apps' "Show in Finder" goes: TheExplorer or Finder.
private struct FileViewerPicker: View {
    @Bindable var prefs: Prefs
    @State private var error: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            ChromeMenu {
                Button { choose(FolderHandler.thisAppID) } label: { AppName.label(for: FolderHandler.thisAppID) }
                Button { choose(FolderHandler.finderID) } label: { AppName.label(for: FolderHandler.finderID) }
            } label: {
                AppName(bundleID: prefs.fileViewerID, isMenu: true)
            }
            if let error {
                Text(error)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.warning)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 220, alignment: .trailing)
            }
        }
        .onAppear { prefs.refreshFileBrowser() }
    }

    private func choose(_ bundleID: String) {
        error = nil
        do {
            try FolderHandler.setViewer(bundleID)
        } catch {
            self.error = error.localizedDescription
        }
        prefs.refreshFileBrowser()
        // Older macOS versions also let the folder opener follow; macOS 26 refuses quietly.
        let app = bundleID == FolderHandler.finderID ? FolderHandler.finderURL : Bundle.main.bundleURL
        Task {
            await FolderHandler.requestFolderOpener(app)
            prefs.refreshFileBrowser()
        }
    }
}

/// An app's icon and name, from its bundle identifier.
private struct AppName: View {
    let bundleID: String
    var isMenu = false

    var body: some View {
        let url = Self.url(for: bundleID)
        HStack(spacing: 6) {
            if let url {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 16, height: 16)
            }
            if isMenu {
                Text(Self.name(bundleID))
            } else {
                Text(Self.name(bundleID))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    static func label(for bundleID: String) -> some View {
        Label {
            Text(name(bundleID))
        } icon: {
            if let url = url(for: bundleID) { Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)) }
        }
    }

    static func url(for bundleID: String) -> URL? {
        if bundleID.caseInsensitiveCompare(FolderHandler.thisAppID) == .orderedSame { return Bundle.main.bundleURL }
        if bundleID.caseInsensitiveCompare(FolderHandler.finderID) == .orderedSame { return FolderHandler.finderURL }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    static func name(_ bundleID: String) -> String {
        guard let url = url(for: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

private struct StartLocationPicker: View {
    @Bindable var prefs: Prefs

    var body: some View {
        ChromeMenu {
            Button("Last Folder") { prefs.startLocation = .lastFolder }
            Button("Home") { prefs.startLocation = .home }
            Divider()
            Button("Choose Folder…", action: choose)
        } label: {
            Text(title)
        }
    }

    private var title: String {
        switch prefs.startLocation {
        case .lastFolder: "Last Folder"
        case .home: "Home"
        case .custom: FileManager.default.displayName(atPath: prefs.startFolder)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: prefs.startFolder)
        panel.prompt = "Start Here"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        prefs.startFolder = url.path
        prefs.startLocation = .custom
    }
}
