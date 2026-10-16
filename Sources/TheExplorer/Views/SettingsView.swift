import SwiftUI

/// Settings (⌘,): the default file browser, the terminal to open folders in, where new windows
/// start, and the defaults new tabs begin with.
struct SettingsView: View {
    @Bindable private var prefs = Prefs.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            section("Default file browser") {
                SettingRow("Open folders with", hint: "Folders opened from other apps, the Dock, Spotlight or “open .” in Terminal, and other apps’ “Show in Finder”. Finder keeps the desktop.") {
                    FolderHandlerPicker()
                }
            }

            section("Terminal") {
                SettingRow("Open folders in", hint: "Used by Open in Terminal (⌃⌘T) and the right-click menus.") {
                    TerminalPicker(selection: $prefs.terminalID)
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
                        Menu {
                            Picker("Sort by", selection: $prefs.defaultSort.key) {
                                ForEach(Self.sortKeys, id: \.self) { Text(Self.title(for: $0)).tag($0) }
                            }
                            .pickerStyle(.inline)
                        } label: {
                            MenuLabel(title: Self.title(for: prefs.defaultSort.key))
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .menuIndicator(.hidden)
                        .fixedSize()
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
                    Menu {
                        Picker("Time range", selection: $prefs.newRange) {
                            ForEach(RecentsRange.options(for: .new)) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        MenuLabel(title: prefs.newRange.title)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                RowDivider()
                SettingRow("Hide clutter", hint: "Leaves out Library, hidden folders and dependency folders like node_modules.") {
                    Toggle("", isOn: $prefs.newHidesClutter).labelsHidden()
                }
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
        Menu {
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
                MenuLabel(title: Terminal(bundleID: selection).name)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
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

/// Switches the file browser macOS uses between TheExplorer and Finder.
private struct FolderHandlerPicker: View {
    @State private var chosen = FolderHandler.finderID
    @State private var needsRelogin = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Menu {
                Button { choose(FolderHandler.thisAppID) } label: { appLabel(Bundle.main.bundleURL) }
                Button { choose(FolderHandler.finderID) } label: { appLabel(FolderHandler.finderURL) }
            } label: {
                let app = chosenURL
                HStack(spacing: 6) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 16, height: 16)
                    MenuLabel(title: Self.name(app))
                }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            if needsRelogin {
                Text("Takes effect after you log out and back in.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.warning)
            }
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private var chosenURL: URL {
        chosen == FolderHandler.finderID
            ? FolderHandler.finderURL
            : NSWorkspace.shared.urlForApplication(withBundleIdentifier: chosen) ?? Bundle.main.bundleURL
    }

    private func appLabel(_ url: URL) -> some View {
        Label { Text(Self.name(url)) } icon: { Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)) }
    }

    private static func name(_ url: URL) -> String {
        FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    private func refresh() {
        chosen = FolderHandler.chosenID
        needsRelogin = FolderHandler.needsRelogin
    }

    private func choose(_ bundleID: String) {
        FolderHandler.choose(bundleID)
        refresh()
    }
}

private struct StartLocationPicker: View {
    @Bindable var prefs: Prefs

    var body: some View {
        Menu {
            Button("Last Folder") { prefs.startLocation = .lastFolder }
            Button("Home") { prefs.startLocation = .home }
            Divider()
            Button("Choose Folder…", action: choose)
        } label: {
            MenuLabel(title: title)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
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
