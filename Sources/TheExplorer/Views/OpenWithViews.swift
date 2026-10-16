import SwiftUI

/// Right-click › Open With: the app opening uses now, every other app that can open the
/// selection, and any app you pick. For files of one type, "Always Open With" makes the choice
/// your default for that type in TheExplorer.
struct OpenWithMenu: View {
    let urls: Set<URL>

    var body: some View {
        let files = urls.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        let apps = FileOpener.apps(for: files)
        let defaults = Set(files.compactMap(FileOpener.defaultApp))
        let current = defaults.count == 1 ? defaults.first : nil
        let extensions = Set(files.map { $0.pathExtension.lowercased() })
        let ext = extensions.count == 1 && extensions.first?.isEmpty == false ? extensions.first : nil

        Menu("Open With") {
            if let current {
                Button { FileOpener.open(files, with: current) } label: { AppLabel(app: current, suffix: " (default)") }
                Divider()
            }
            ForEach(apps.filter { $0 != current }, id: \.self) { app in
                Button { FileOpener.open(files, with: app) } label: { AppLabel(app: app) }
            }
            if apps.contains(where: { $0 != current }) { Divider() }
            Button("Other…") {
                if let app = FileOpener.chooseApp() { FileOpener.open(files, with: app) }
            }
            if let ext {
                Divider()
                AlwaysOpenWithMenu(ext: ext, apps: apps, files: files)
            }
        }
    }
}

/// Sets the default app for one extension, and opens the selection with it.
private struct AlwaysOpenWithMenu: View {
    let ext: String
    let apps: [URL]
    let files: [URL]
    private var rules: OpenWithRules { .shared }

    var body: some View {
        let chosen = rules.appID(forExtension: ext)
        Menu("Always Open .\(ext) Files With") {
            ForEach(apps, id: \.self) { app in
                let id = FileOpener.bundleID(app)
                Toggle(isOn: Binding(get: { id != nil && id == chosen }, set: { _ in choose(app) })) {
                    AppLabel(app: app)
                }
            }
            Divider()
            Button("Other…") {
                if let app = FileOpener.chooseApp() { choose(app) }
            }
            if chosen != nil {
                Divider()
                Button("Use the macOS Default") { rules.clear(ext) }
            }
        }
    }

    private func choose(_ app: URL) {
        guard let id = FileOpener.bundleID(app) else { return }
        rules.setApp(id, forExtension: ext)
        FileOpener.open(files, with: app)
    }
}

private struct AppLabel: View {
    let app: URL
    var suffix = ""

    var body: some View {
        Label {
            Text(FileOpener.name(app) + suffix)
        } icon: {
            Image(nsImage: FileOpener.icon(app))
        }
    }
}

// MARK: - Settings

/// Settings › Open With: which app opens which file types from TheExplorer.
struct OpenWithSettings: View {
    private var rules: OpenWithRules { .shared }
    /// A rule just added from the menu, so its types field can take focus.
    @State private var added: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionCaption(title: "Default apps")
                Spacer()
                ChromeMenu(style: .button) {
                    Button("Blank Rule") { added = rules.add().id }
                    Divider()
                    ForEach(OpenWithRules.presets, id: \.name) { preset in
                        Button(preset.name) { added = rules.add(extensions: preset.extensions).id }
                    }
                } label: {
                    Label("Add Rule", systemImage: "plus")
                        .font(.system(size: 11.5, weight: .semibold))
                }
            }
            VStack(spacing: 0) {
                if rules.rules.isEmpty {
                    VStack(spacing: 6) {
                        Text("Files open in their macOS default app")
                            .font(.system(size: 12.5, weight: .medium))
                        Text("Add a rule to open types like png or mp4 in an app you choose, or right-click a file › Open With › Always Open With.")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity)
                } else {
                    ForEach(Array(rules.rules.enumerated()), id: \.element.id) { index, rule in
                        if index > 0 { Rectangle().fill(Theme.border).frame(height: 1).padding(.leading, 12) }
                        OpenRuleRow(rule: rule, focusOnAppear: rule.id == added)
                    }
                }
            }
            .panel(padding: 0)
            Text("Rules apply when you open files from TheExplorer (double-click, Return or ⌘↓). Other apps, and Finder, keep using the macOS defaults. Separate types with commas.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct OpenRuleRow: View {
    let rule: OpenRule
    let focusOnAppear: Bool
    @State private var text: String
    @FocusState private var focused: Bool
    @State private var hovering = HoverPreview.on
    private var rules: OpenWithRules { .shared }

    init(rule: OpenRule, focusOnAppear: Bool) {
        self.rule = rule
        self.focusOnAppear = focusOnAppear
        _text = State(initialValue: rule.extensions.joined(separator: ", "))
    }

    var body: some View {
        let duplicates = rules.duplicates(in: rule)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                TextField("", text: $text, prompt: Text("png, jpg, webp").foregroundStyle(Theme.textTertiary))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .focused($focused)
                    .formField()
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                RuleAppPicker(rule: rule)
                    .frame(width: 170, alignment: .leading)
                Button {
                    rules.remove(rule)
                } label: {
                    Image(systemName: "trash").font(.system(size: 10, weight: .semibold)).frame(width: 16, height: 16)
                }
                .buttonStyle(GhostButtonStyle(padding: 2, tint: Theme.textSecondary, destructive: true))
                .help("Remove")
                .opacity(hovering ? 1 : 0.5)
            }
            if !duplicates.isEmpty {
                Text("\(duplicates.joined(separator: ", ")) \(duplicates.count == 1 ? "is" : "are") already in a rule above, which wins.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.warning)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(hovering ? Theme.hoverFill.opacity(0.6) : .clear)
        .hoverTracking { hovering = $0 }
        .animation(Theme.hoverAnimation, value: hovering)
        .onChange(of: text) {
            var updated = rule
            updated.extensions = FileAction.parseExtensions(text)
            rules.update(updated)
        }
        .onAppear { if focusOnAppear && rule.extensions.isEmpty { focused = true } }
    }
}

/// Apps that can open the rule's first type, plus any app you pick.
private struct RuleAppPicker: View {
    let rule: OpenRule

    var body: some View {
        let app = FileOpener.appURL(for: rule.appID)
        ChromeMenu {
            let apps = rule.extensions.first.map(FileOpener.apps(forExtension:)) ?? []
            ForEach(apps, id: \.self) { candidate in
                Button { choose(candidate) } label: { AppLabel(app: candidate) }
            }
            if !apps.isEmpty { Divider() }
            Button("Other App…") {
                if let picked = FileOpener.chooseApp() { choose(picked) }
            }
        } label: {
            HStack(spacing: 6) {
                if let app {
                    Image(nsImage: FileOpener.icon(app)).resizable().frame(width: 16, height: 16)
                    Text(FileOpener.name(app)).lineLimit(1)
                } else {
                    Text(rule.appID.isEmpty ? "Choose App" : "Missing App")
                        .foregroundStyle(rule.appID.isEmpty ? Theme.textSecondary : Theme.warning)
                }
            }
        }
    }

    private func choose(_ app: URL) {
        guard let id = FileOpener.bundleID(app) else { return }
        var updated = rule
        updated.appID = id
        OpenWithRules.shared.update(updated)
    }
}
