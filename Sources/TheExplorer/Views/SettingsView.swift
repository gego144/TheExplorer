import SwiftUI

/// Settings (⌘,). General: the color theme, the default file browser, the terminal to open folders in, where new
/// windows start, and the defaults new tabs begin with. Actions: your shell commands for files.
/// Open With: the apps that open file types from TheExplorer. Shortcuts: the menus' keys, changeable.
struct SettingsView: View {
    @Bindable private var prefs = Prefs.shared

    var body: some View {
        VStack(spacing: 0) {
            // The tabs stay put; what's under them scrolls once it's taller than the screen allows.
            Segmented(selection: $prefs.settingsTab, options: [(.general, "General"), (.actions, "Actions"), (.openWith, "Open With"),
                                                               (.cloud, "Cloud"), (.shortcuts, "Shortcuts")])
                .fixedSize()
                .frame(maxWidth: .infinity)
                .padding(.top, 14)
                .padding(.bottom, 14)
            Rectangle().fill(Theme.border).frame(height: 1)
            FittedScroll(maxHeight: Self.maxContentHeight) {
                Group {
                    switch prefs.settingsTab {
                    case .general: general
                    case .actions: ActionsSettings()
                    case .openWith: OpenWithSettings()
                    case .cloud: CloudSettings()
                    case .shortcuts: ShortcutsSettings()
                    }
                }
                .padding(20)
            }
        }
        .toggleStyle(WorkbenchSwitchStyle())
        .controlSize(.small)
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.background)
        .preferredColorScheme(Theme.colorScheme)
    }

    /// " (⌃⌘T)": a command's keys as they are now (they can be changed), or `fallback` without any.
    private static func keys(_ command: ShortcutCommand, or fallback: String = "") -> String {
        Shortcuts.shared.shortcut(command).map { " (\($0.display))" } ?? fallback
    }

    /// As tall as the screen comfortably allows, under the title bar and tabs.
    private static var maxContentHeight: CGFloat {
        min(660, max(360, (NSScreen.main?.visibleFrame.height ?? 800) - 160))
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 18) {
            section("Appearance") {
                ThemePicker(prefs: prefs)
            }

            section("Default file browser") {
                SettingRow("“Show in Finder” opens", hint: "Where other apps’ “Show in Finder” buttons take you.") {
                    FileViewerPicker(prefs: prefs)
                }
                RowDivider()
                SettingRow("Folders open in", hint: folderOpenerHint) {
                    AppName(bundleID: prefs.folderOpenerID)
                }
                RowDivider()
                SettingRow("Catch Finder windows", hint: takeoverHint) {
                    Toggle("", isOn: Binding(get: { prefs.takeOverFinder }, set: { on in
                        prefs.takeOverFinder = on
                        if on { FinderTakeover.shared.requestPermission() }
                    }))
                    .labelsHidden()
                }
            }

            section("Terminal") {
                SettingRow("Open folders in", hint: "For Open in Terminal\(Self.keys(.openInTerminal)) and the right-click menu.") {
                    TerminalPicker(selection: $prefs.terminalID)
                }
            }

            section("Search") {
                SettingRow("Index", hint: "Your home folder, Applications and cloud drives, kept current. Library, hidden and dependency folders are left out.") {
                    SearchIndexStatus()
                }
            }

            section("New windows") {
                SettingRow("Start in", hint: startHint) {
                    StartLocationPicker(prefs: prefs)
                }
            }

            section("Browsing defaults") {
                SettingRow("Sort by", hint: "For new tabs. A column header changes one tab.") {
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
                SettingRow("Show hidden files", hint: "Switch it in any tab with\(Self.keys(.toggleHidden, or: " View › Show Hidden Files")).") {
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
                SettingRow("Hide clutter", hint: "Leaves out Library, hidden and dependency folders.") {
                    Toggle("", isOn: $prefs.newHidesClutter).labelsHidden()
                }
            }
        }
    }

    private var folderOpenerHint: String {
        if prefs.folderOpenerID.caseInsensitiveCompare(FolderHandler.thisAppID) == .orderedSame {
            return "Folders from other apps, the Dock and Spotlight open here."
        }
        return "macOS keeps folders from the Dock and Spotlight in Finder."
    }

    private var takeoverHint: String {
        if prefs.takeOverFinder && FinderTakeover.shared.isDenied {
            return "Allow it in System Settings › Privacy & Security › Automation."
        }
        return "When macOS opens a folder in Finder anyway, it moves here."
    }

    private var startHint: String {
        switch prefs.startLocation {
        case .lastFolder: "Wherever you were last."
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
        case .modified, .date: "Modified"
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

/// A scroll view as tall as what's in it, up to `maxHeight`: short tabs stay short, long ones scroll.
private struct FittedScroll<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder let content: Content
    @State private var height: CGFloat = 0

    var body: some View {
        ScrollView {
            content
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: ContentHeight.self, value: geometry.size.height)
                })
                .thinScrollers()
        }
        .scrollIndicators(.automatic)
        .frame(height: min(max(height, 1), maxHeight))
        .onPreferenceChange(ContentHeight.self) { height = $0 }
    }
}

private struct ContentHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
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
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text)
                if let hint {
                    Text(hint)
                        .font(.system(size: 11.5))
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

// MARK: - Theme

/// A tile for each theme, drawn as a little window in its colors.
private struct ThemePicker: View {
    @Bindable var prefs: Prefs

    var body: some View {
        HStack(spacing: 8) {
            ForEach(ThemeChoice.allCases) { choice in
                Button { prefs.theme = choice } label: {
                    ThemeTileLabel(choice: choice, isSelected: prefs.theme == choice)
                }
                .buttonStyle(ThemeTileStyle(isSelected: prefs.theme == choice))
                .help(choice == .system ? "Dark or Light, following macOS" : choice.title)
                #if DEBUG
                .debugRowFrame(named: "theme-\(choice.rawValue)")
                #endif
            }
        }
        .padding(12)
    }
}

private struct ThemeTileLabel: View {
    static let size = CGSize(width: 76, height: 50)
    let choice: ThemeChoice
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if choice == .system {
                    // Dark on the left, light on the right.
                    MiniWindow(palette: .dark)
                        .overlay {
                            MiniWindow(palette: .light)
                                .mask(alignment: .trailing) { Rectangle().frame(width: ThemeTileLabel.size.width / 2) }
                        }
                } else {
                    MiniWindow(palette: choice.palette(systemIsDark: true))
                }
            }
            .frame(width: Self.size.width, height: Self.size.height)
            .clipShape(.rect(cornerRadius: 6))
            Text(choice.title)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Theme.text : Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ThemeTileStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        Hovering { hovering in
            configuration.label
                .padding(4)
                .background(configuration.isPressed ? Theme.pressedFill : (hovering ? Theme.hoverFill : .clear),
                            in: .rect(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(isSelected ? Theme.accent : (hovering ? Theme.borderHover : .clear),
                                                                        lineWidth: isSelected ? 1.5 : 1))
                .contentShape(.rect)
                .clickable(!isSelected)
        }
    }
}

/// A sketch of the window in a palette: sidebar, rows with one selected, and the inspector card.
private struct MiniWindow: View {
    let palette: ThemePalette

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(0..<4, id: \.self) { index in
                    Capsule().fill(index == 1 ? palette.text.opacity(0.8) : palette.textTertiary.opacity(0.7)).frame(width: 10, height: 2.5)
                }
            }
            .padding(5)
            .frame(width: 20, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(palette.background)
            Rectangle().fill(palette.border).frame(width: 0.5)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(0..<5, id: \.self) { index in
                    HStack(spacing: 3) {
                        Capsule().fill(index == 2 ? palette.text : palette.textSecondary.opacity(0.8)).frame(width: 14, height: 2.5)
                        Spacer(minLength: 0)
                        Capsule().fill([palette.warning, palette.blue, palette.purple, palette.hot, palette.green][index]).frame(width: 6, height: 2.5)
                    }
                    .padding(.horizontal, 3)
                    .frame(height: 6)
                    .background(index == 2 ? palette.accentSoft : .clear, in: .rect(cornerRadius: 1.5))
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(palette.background)
            RoundedRectangle(cornerRadius: 3)
                .fill(palette.surface)
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(palette.border, lineWidth: 0.5))
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 3) {
                        RoundedRectangle(cornerRadius: 1.5).fill(palette.raised).frame(width: 8, height: 8)
                        Capsule().fill(palette.accent).frame(width: 11, height: 2.5)
                        Capsule().fill(palette.textTertiary).frame(width: 8, height: 2)
                    }
                    .padding(3)
                }
                .frame(width: 20)
                .padding(3)
                .background(palette.background)
        }
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(palette.border))
    }
}
