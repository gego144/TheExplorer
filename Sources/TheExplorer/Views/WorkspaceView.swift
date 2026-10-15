import QuickLook
import SwiftUI

extension EnvironmentValues {
    /// Opens a folder in a new tab of the current window.
    @Entry var openTab: (URL) -> Void = { _ in }
}

/// A whole window: tab strip, command bar, sidebar, content, inspector and status bar.
struct WorkspaceView: View {
    @Bindable var workspace: Workspace
    private var prefs: Prefs { .shared }

    var body: some View {
        let model = workspace.selected
        VStack(spacing: 0) {
            TabStrip(workspace: workspace)
            CommandBar(model: model)
                .zIndex(1) // path suggestions drop down over the content
            HStack(spacing: 0) {
                if prefs.showSidebar {
                    SidebarView(model: model)
                        .frame(width: 192)
                        .overlay(alignment: .trailing) { Rectangle().fill(Theme.border).frame(width: 1) }
                }
                content(model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if prefs.showInspector && InspectorView.hasContent(model) {
                    InspectorView(model: model)
                        .frame(width: 236)
                        .padding([.vertical, .trailing], 10)
                }
            }
            StatusBar(model: model)
        }
        .background(Theme.background)
        .foregroundStyle(Theme.text)
        .ignoresSafeArea(.container, edges: .top)
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .environment(\.openTab) { url in workspace.newTab(url) }
        .navigationTitle(model.title)
        .quickLookPreview(Binding(get: { model.previewURL }, set: { model.previewURL = $0 }))
        .alert("Rename", isPresented: Binding(get: { model.renaming != nil }, set: { if !$0 { model.renaming = nil } }),
               presenting: model.renaming) { item in
            NamePrompt(initialName: item.name, confirmTitle: "Rename") { model.rename(item, to: $0) }
        }
        .alert(model.creating?.title ?? "", isPresented: Binding(get: { model.creating != nil }, set: { if !$0 { model.creating = nil } }),
               presenting: model.creating) { kind in
            NamePrompt(initialName: model.suggestedName(for: kind), confirmTitle: "Create") { model.create(kind, named: $0) }
        } message: { _ in
            Text("In “\(FileManager.default.displayName(atPath: model.currentURL.path))”")
        }
        .onChange(of: searchKey(model), initial: true) { runSearch(model) }
        .focusedSceneValue(\.workspace, workspace)
    }

    @ViewBuilder
    private func content(_ model: BrowserModel) -> some View {
        if model.isSearching {
            SearchResultsView(model: model)
        } else {
            switch model.destination {
            case .folder: FolderView(model: model)
            case .recents: RecentsView(model: model, recents: model.recents)
            case .newFiles: RecentsView(model: model, recents: model.newFiles)
            case .storage: StorageView(model: model)
            }
        }
    }

    private func searchKey(_ model: BrowserModel) -> String {
        "\(ObjectIdentifier(model).hashValue)|\(model.searchText)|\(model.searchScope)|\(model.currentURL.path)|\(model.showHidden)"
    }

    private func runSearch(_ model: BrowserModel) {
        if model.isSearching {
            model.search.run(text: model.searchText, scope: model.searchScope, folder: model.currentURL, includeHidden: model.showHidden)
        } else {
            model.search.clear()
        }
    }
}

struct WorkspaceFocusKey: FocusedValueKey {
    typealias Value = Workspace
}

extension FocusedValues {
    var workspace: Workspace? {
        get { self[WorkspaceFocusKey.self] }
        set { self[WorkspaceFocusKey.self] = newValue }
    }
}

struct NamePrompt: View {
    let confirmTitle: String
    let onConfirm: (String) -> Void
    @State private var name: String

    init(initialName: String, confirmTitle: String, onConfirm: @escaping (String) -> Void) {
        self.confirmTitle = confirmTitle
        self.onConfirm = onConfirm
        _name = State(initialValue: initialName)
    }

    var body: some View {
        TextField("Name", text: $name)
        Button(confirmTitle) { onConfirm(name) }
            .keyboardShortcut(.defaultAction)
        Button("Cancel", role: .cancel) {}
    }
}

// MARK: - Tab strip

/// Browser-style tabs in the title bar. Drop files on a tab to move them into its folder;
/// hover a drag over a tab to switch to it.
struct TabStrip: View {
    let workspace: Workspace

    /// Tabs live in the top 32pt (the title bar), centred on the traffic lights' line. The strip must
    /// reach below the title bar: SwiftUI hides views that sit entirely inside it.
    static let titleBarHeight: CGFloat = 32
    static let height: CGFloat = 36
    static let tabHeight: CGFloat = 24

    var body: some View {
        HStack(spacing: 3) {
            // Room for the window's traffic lights.
            Color.clear.frame(width: 72, height: 1)
            ForEach(Array(workspace.tabs.enumerated()), id: \.element.id) { index, tab in
                TabItem(tab: tab, index: index, workspace: workspace)
            }
            Button {
                workspace.newTab()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 24, height: Self.tabHeight)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("New tab (⌘T)")
            Spacer(minLength: 0)
        }
        .frame(height: Self.titleBarHeight)
        .frame(height: Self.height, alignment: .top)
        .background {
            // Empty space in the strip drags the window and double-click zooms it, like a title bar.
            Color.clear
                .contentShape(.rect)
                .onTapGesture(count: 2) { NSApp.keyWindow?.zoom(nil) }
                .gesture(WindowDragGesture())
        }
    }
}

private struct TabItem: View {
    let tab: BrowserModel
    let index: Int
    let workspace: Workspace
    @State private var hovering = false
    @State private var dropTargeted = false
    @State private var springLoad: Task<Void, Never>?

    private var isSelected: Bool { workspace.selected === tab }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(isSelected || dropTargeted ? Theme.accent : Theme.textTertiary)
            Text(tab.isSearching ? "“\(tab.searchText)”" : tab.title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Theme.text : Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 150, alignment: .leading)
            if workspace.tabs.count > 1 {
                Button {
                    workspace.close(tab)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 16, height: 16)
                        .background(hovering ? Theme.raised : .clear, in: .rect(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .opacity(hovering || isSelected ? 1 : 0)
                .help("Close tab (⌘W)")
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, workspace.tabs.count > 1 ? 4 : 10)
        .frame(height: TabStrip.tabHeight)
        .fixedSize(horizontal: true, vertical: false)
        .background(isSelected ? Theme.raised : (hovering ? Theme.hover : .clear), in: .rect(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(dropTargeted ? Theme.accent : (isSelected ? Theme.fieldBorder : .clear),
                              style: StrokeStyle(lineWidth: 1, dash: dropTargeted ? [4, 3] : []))
        }
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture { workspace.select(index) }
        .help(Format.path(tab.currentURL.path))
        .dropDestination(for: URL.self) { urls, _ in
            tab.receiveDrop(urls, into: tab.currentURL)
        } isTargeted: { targeted in
            dropTargeted = targeted
            springLoad?.cancel()
            if targeted && !isSelected {
                // Hovering a drag over a tab switches to it, so you can drop into a subfolder there.
                springLoad = Task {
                    try? await Task.sleep(for: .milliseconds(650))
                    if !Task.isCancelled { workspace.select(tab) }
                }
            }
        }
        .contextMenu {
            Button("Duplicate Tab") { workspace.newTab(tab.currentURL) }
            Divider()
            Button("Copy Path") { FileActions.copyPaths([tab.currentURL]) }
            Button("Open in Terminal") { FileActions.openInTerminal(tab.currentURL) }
            Divider()
            Button("Close Tab") { workspace.close(tab) }
                .disabled(workspace.tabs.count == 1)
            Button("Close Other Tabs") { workspace.closeOthers(than: tab) }
                .disabled(workspace.tabs.count == 1)
        }
    }

    private var icon: String {
        if tab.isSearching { return "magnifyingglass" }
        switch tab.destination {
        case .folder: return "diamond.fill"
        case .recents: return "clock.fill"
        case .newFiles: return "sparkles"
        case .storage: return "chart.pie.fill"
        }
    }
}

// MARK: - Command bar

struct CommandBar: View {
    @Bindable var model: BrowserModel
    private var prefs: Prefs { .shared }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 3) {
                IconButton(systemImage: "chevron.left", help: "Back (⌘[)") { model.goBack() }
                    .disabled(model.backStack.isEmpty)
                IconButton(systemImage: "chevron.right", help: "Forward (⌘])") { model.goForward() }
                    .disabled(model.forwardStack.isEmpty)
                IconButton(systemImage: "arrow.up", help: "Enclosing folder (⌘↑)") { model.goUp() }
                    .disabled(!model.canGoUp)
            }
            Omnibox(model: model)
            if model.destination == .folder && !model.isSearching {
                Segmented(selection: $model.kindFilter, options: [(.all, "All"), (.folders, "Dirs"), (.files, "Files")])
                    .fixedSize()
            }
            Menu {
                Toggle("Folders First", isOn: $model.foldersFirst)
                Toggle("Show Hidden Files", isOn: $model.showHidden)
                Divider()
                Button("New Folder…") { model.creating = .folder }
                    .disabled(!model.canCreateItems)
                Button("New File…") { model.creating = .file }
                    .disabled(!model.canCreateItems)
                Divider()
                Button("Recalculate Folder Sizes") { model.recalculateSizes() }
                Button("Open in Terminal") { FileActions.openInTerminal(model.currentURL) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 26, height: 26)
                    .background(Theme.raised, in: .rect(cornerRadius: 6))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("View options")
            IconButton(systemImage: "sidebar.left", help: "Sidebar (⌥⌘S)", isOn: prefs.showSidebar) {
                prefs.showSidebar.toggle()
            }
            IconButton(systemImage: "sidebar.right", help: "Inspector (⌘I)", isOn: prefs.showInspector) {
                prefs.showInspector.toggle()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}

// MARK: - Omnibox

/// One field for both: shows the path as clickable chips; click (or ⌘K/⌘F) to search, or type
/// a path starting with / or ~ to jump there, with folder completion.
struct Omnibox: View {
    @Bindable var model: BrowserModel
    @FocusState private var focused: Bool
    @State private var query = ""
    @State private var highlighted: Int?
    @State private var invalid = false
    @State private var suggestions: [URL] = []
    /// Set when editing begins, so the field exists before it's asked to take focus.
    @State private var editing = false

    private var isPathMode: Bool { query.hasPrefix("/") || query.hasPrefix("~") }
    private var showsField: Bool { editing || focused || !query.isEmpty }

    var body: some View {
        HStack(spacing: 6) {
            if showsField {
                Image(systemName: isPathMode ? "arrow.turn.down.right" : "magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isPathMode ? Theme.accent : Theme.textSecondary)
                TextField("", text: $query, prompt: Text("Search, or type a path like ~/Dev").foregroundStyle(Theme.textTertiary))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, design: isPathMode ? .monospaced : .default))
                    .focused($focused)
                    .onSubmit(submit)
                    .onExitCommand(perform: cancel)
                    .onKeyPress(.downArrow) { moveHighlight(1) }
                    .onKeyPress(.upArrow) { moveHighlight(-1) }
                    .onKeyPress(.tab) { complete() }
                if !isPathMode && !query.isEmpty {
                    scopeChips
                }
                if !query.isEmpty {
                    Button(action: cancel) {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Breadcrumbs(model: model)
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    Text("search or go to path")
                    Text("⌘K")
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 4)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.fieldBorder))
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize()
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(Theme.field, in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(invalid ? Theme.danger : (focused ? Theme.accent.opacity(0.7) : Theme.fieldBorder)))
        .contentShape(.rect)
        .onTapGesture { if !showsField { begin("") } }
        .overlay(alignment: .topLeading) {
            if focused && isPathMode && !suggestions.isEmpty {
                SuggestionList(suggestions: suggestions, highlighted: highlighted) { go(to: $0) }
                    .offset(y: 34)
            }
        }
        .onChange(of: query) {
            invalid = false
            highlighted = nil
            model.searchText = isPathMode ? "" : query
        }
        .task(id: isPathMode ? query : "") {
            // Listed off the main thread: typing a path into a huge folder must stay instant.
            let query = isPathMode ? query : ""
            suggestions = query.isEmpty ? [] : await Task.detached(priority: .userInitiated) { Self.suggestions(for: query) }.value
        }
        .onChange(of: model.searchText) {
            // Keep the field in step when the search is started or ended from elsewhere.
            guard !focused else { return }
            if model.searchText.isEmpty {
                if !isPathMode { query = "" }
            } else if query != model.searchText {
                query = model.searchText
            }
        }
        .onChange(of: focused) {
            guard !focused else { return }
            editing = false
            // An unfinished path is a draft; drop it when you leave the field.
            if isPathMode { query = "" }
        }
        .onChange(of: model.currentURL) { if !focused && isPathMode { query = "" } }
        .onChange(of: model.destination) { if !focused && isPathMode { query = "" } }
        .onChange(of: model.omniboxRequest) {
            if let request = model.omniboxRequest { begin(request.text) }
        }
        .onChange(of: ObjectIdentifier(model)) {
            query = model.searchText
            editing = false
            focused = false
        }
    }

    private var scopeChips: some View {
        HStack(spacing: 2) {
            ForEach([(SearchScope.folder, "Here"), (.mac, "Everywhere")], id: \.0) { scope, title in
                Button {
                    model.searchScope = scope
                } label: {
                    Text(title)
                        .font(.system(size: 10.5, weight: .medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .foregroundStyle(model.searchScope == scope ? Theme.accent : Theme.textSecondary)
                        .background(model.searchScope == scope ? Theme.accentSoft : Theme.raised, in: .capsule)
                }
                .buttonStyle(.plain)
            }
        }
        .fixedSize()
    }

    // MARK: Actions

    private func begin(_ text: String) {
        query = text
        editing = true
        // Focus once the field is on screen; focusing a view that doesn't exist yet is ignored.
        DispatchQueue.main.async { focused = true }
        // If focus didn't take (e.g. the window isn't key), don't leave an empty field behind.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if !focused && query.isEmpty { editing = false }
        }
    }

    private func cancel() {
        query = ""
        model.searchText = ""
        editing = false
        focused = false
        model.listFocusRequest += 1
    }

    private func submit() {
        if isPathMode {
            if let highlighted, suggestions.indices.contains(highlighted) {
                go(to: suggestions[highlighted])
            } else if model.goTo(path: query) {
                finish()
            } else {
                invalid = true
            }
        } else if !query.isEmpty {
            // Search stays on; jump into the results.
            focused = false
            model.listFocusRequest += 1
        }
    }

    private func go(to url: URL) {
        model.navigate(to: url)
        finish()
    }

    private func finish() {
        query = ""
        focused = false
        model.listFocusRequest += 1
    }

    private func moveHighlight(_ delta: Int) -> KeyPress.Result {
        guard isPathMode, !suggestions.isEmpty else { return .ignored }
        let next = (highlighted ?? (delta > 0 ? -1 : suggestions.count)) + delta
        highlighted = min(max(0, next), suggestions.count - 1)
        return .handled
    }

    /// Tab fills in the highlighted (or only/first) folder suggestion.
    private func complete() -> KeyPress.Result {
        guard isPathMode, let target = highlighted.map({ suggestions[$0] }) ?? suggestions.first else { return .ignored }
        query = Format.path(target.path) + "/"
        return .handled
    }

    /// Folders matching what's typed: the contents of a folder ending in "/", otherwise siblings
    /// whose names start with the last component.
    nonisolated private static func suggestions(for query: String) -> [URL] {
        let expanded = (query as NSString).expandingTildeInPath
        let endsWithSlash = query.hasSuffix("/")
        let parent = endsWithSlash ? expanded : (expanded as NSString).deletingLastPathComponent
        let prefix = endsWithSlash ? "" : (expanded as NSString).lastPathComponent.lowercased()
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: parent.isEmpty ? "/" : parent), includingPropertiesForKeys: keys) else { return [] }
        return children
            .filter { url in
                let name = url.lastPathComponent
                guard (prefix.hasPrefix(".") || !name.hasPrefix(".")) && (prefix.isEmpty || name.lowercased().hasPrefix(prefix)) else { return false }
                let values = try? url.resourceValues(forKeys: Set(keys))
                return values?.isDirectory == true && values?.isPackage != true
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .prefix(8)
            .map { $0 }
    }
}

private struct SuggestionList: View {
    let suggestions: [URL]
    let highlighted: Int?
    let onPick: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(suggestions.enumerated()), id: \.element) { index, url in
                Button {
                    onPick(url)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .heavy))
                            .foregroundStyle(Theme.accent)
                        Text(url.lastPathComponent)
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Text(Format.path(url.deletingLastPathComponent().path))
                            .font(Theme.monoSmall)
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(index == highlighted ? Theme.accentSoft : .clear, in: .rect(cornerRadius: 6))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            Text("↑↓ choose · ⇥ complete · ↩ go")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 10)
                .padding(.top, 4)
        }
        .padding(6)
        .frame(width: 420, alignment: .leading)
        .background(Theme.surface, in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.fieldBorder))
        .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
    }
}

/// The current location as chips: "~ / Dev / jestr". Click to go there, drop to move items in.
private struct Breadcrumbs: View {
    let model: BrowserModel
    @Environment(\.openTab) private var openTab

    private var trail: [URL] {
        switch model.destination {
        case .recents, .newFiles, .storage: return []
        case .folder:
            var urls: [URL] = []
            var url = model.currentURL
            let home = URL.home.standardizedFileURL.path
            while true {
                urls.insert(url, at: 0)
                if url.isRoot || url.path == home { break }
                url = url.deletingLastPathComponent().standardizedFileURL
            }
            return urls
        }
    }

    var body: some View {
        if model.destination != .folder {
            Chip(title: model.title, isCurrent: true)
        } else {
            let trail = trail
            // Full path if it fits; otherwise keep the root and the last folders, folding the middle into "…".
            ViewThatFits(in: .horizontal) {
                crumbs(trail, keepLast: trail.count)
                ForEach([3, 2, 1].filter { $0 < trail.count - 1 }, id: \.self) { keep in
                    crumbs(trail, keepLast: keep)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(-1)
        }
    }

    private func crumbs(_ trail: [URL], keepLast: Int) -> some View {
        let hidden = keepLast < trail.count - 1 ? Array(trail[1..<(trail.count - keepLast)]) : []
        let visible = hidden.isEmpty ? trail : [trail[0]] + trail.suffix(keepLast)
        return HStack(spacing: 4) {
            ForEach(Array(visible.enumerated()), id: \.element) { index, url in
                if index > 0 {
                    Text("/").foregroundStyle(Theme.textTertiary)
                }
                if index == 1 && !hidden.isEmpty {
                    Menu {
                        ForEach(hidden, id: \.self) { folder in
                            Button(folder.lastPathComponent) { model.navigate(to: folder) }
                        }
                    } label: {
                        Chip(title: "…", isCurrent: false)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(hidden.map(\.lastPathComponent).joined(separator: " / "))
                    Text("/").foregroundStyle(Theme.textTertiary)
                }
                BreadcrumbChip(url: url, isCurrent: index == visible.count - 1, model: model, openTab: openTab)
            }
        }
        .fixedSize()
    }
}

private struct BreadcrumbChip: View {
    let url: URL
    let isCurrent: Bool
    let model: BrowserModel
    let openTab: (URL) -> Void
    @State private var targeted = false

    var body: some View {
        Button {
            model.navigate(to: url)
        } label: {
            Chip(title: title, isCurrent: isCurrent, highlighted: targeted)
        }
        .buttonStyle(.plain)
        .dropDestination(for: URL.self) { urls, _ in model.receiveDrop(urls, into: url) } isTargeted: { targeted = $0 }
        .contextMenu {
            Button("Open in New Tab") { openTab(url) }
            Button("Open in Terminal") { FileActions.openInTerminal(url) }
            Button("Copy Path") { FileActions.copyPaths([url]) }
            Button("Reveal in Finder") { FileActions.revealInFinder([url]) }
            Button(FavoritesStore.shared.contains(url) ? "Unpin" : "Pin to Sidebar") { FavoritesStore.shared.toggle(url) }
        }
        .help(Format.path(url.path))
    }

    private var title: String {
        if url.path == URL.home.standardizedFileURL.path { return "~" }
        if url.isRoot { return FileManager.default.displayName(atPath: "/") }
        return url.lastPathComponent
    }
}

private struct Chip: View {
    let title: String
    let isCurrent: Bool
    var highlighted = false

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .foregroundStyle(isCurrent || highlighted ? Theme.accent : Theme.textSecondary)
            .background(isCurrent || highlighted ? Theme.accentSoft : Theme.raised, in: .rect(cornerRadius: 5))
    }
}

// MARK: - Status bar

struct StatusBar: View {
    let model: BrowserModel

    var body: some View {
        HStack(spacing: 10) {
            Text(summary)
                .font(Theme.mono)
                .foregroundStyle(Theme.textSecondary)
            if let status = model.transferStatus {
                ProgressView().controlSize(.mini)
                Text(status).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(Theme.accent)
            } else if model.isLoading || (model.isSearching && model.search.isRunning) {
                ProgressView().controlSize(.mini)
            }
            Spacer()
            if let volume = model.volume {
                Text(volume.name).foregroundStyle(Theme.textSecondary)
                HeatBar(fraction: Double(volume.used) / Double(max(volume.total, 1)), height: 4, color: Theme.accent)
                    .frame(width: 110)
                Text("\(Format.bytes(volume.available)) free")
                    .font(Theme.mono)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(Theme.background)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private var summary: String {
        if model.isSearching {
            let count = model.search.visibleHits.count
            return "\(count.formatted()) \(count == 1 ? "result" : "results")"
        }
        switch model.destination {
        case .recents, .newFiles, .storage:
            return model.title.lowercased()
        case .folder:
            let folders = model.folderCount
            var text = "\(folders.formatted()) dirs · \((model.rows.count - folders).formatted()) files"
            if model.hiddenCount > 0 { text += " · \(model.hiddenCount.formatted()) hidden" }
            if !model.selection.isEmpty {
                let sizes = FolderSizeStore.shared
                let selected = model.rows.filter { model.selection.contains($0.id) }
                let bytes = selected.compactMap { $0.size ?? sizes.size(for: $0.item.path)?.bytes }.reduce(0, +)
                text += " · \(selected.count.formatted()) selected" + (bytes > 0 ? " (\(Format.bytes(bytes)))" : "")
            }
            return text
        }
    }
}
