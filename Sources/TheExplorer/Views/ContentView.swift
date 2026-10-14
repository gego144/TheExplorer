import QuickLook
import SwiftUI

struct ContentView: View {
    @Bindable var model: BrowserModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            detail
                .inspector(isPresented: $model.showInspector) {
                    InspectorView(model: model)
                }
        }
        .navigationTitle(model.isSearching ? "Search" : model.title)
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: searchPrompt)
        .searchScopes($model.searchScope) {
            Text("This Folder").tag(SearchScope.folder)
            Text("Entire Mac").tag(SearchScope.mac)
        }
        .searchFocused($searchFocused)
        .onChange(of: model.searchFocusRequest) { searchFocused = true }
        .onChange(of: searchKey, initial: true) { runSearch() }
        .quickLookPreview($model.previewURL)
        .alert("Rename", isPresented: Binding(get: { model.renaming != nil }, set: { if !$0 { model.renaming = nil } }),
               presenting: model.renaming) { item in
            NamePrompt(initialName: item.name, confirmTitle: "Rename") { model.rename(item, to: $0) }
        }
        .alert(model.creating?.title ?? "", isPresented: Binding(get: { model.creating != nil }, set: { if !$0 { model.creating = nil } }),
               presenting: model.creating) { kind in
            NamePrompt(initialName: model.suggestedName(for: kind), confirmTitle: "Create") { model.create(kind, named: $0) }
        } message: { kind in
            Text("In “\(FileManager.default.displayName(atPath: model.currentURL.path))”")
        }
        .focusedSceneValue(\.browser, model)
    }

    @ViewBuilder private var detail: some View {
        if model.isSearching {
            SearchResultsView(model: model)
        } else {
            switch model.destination {
            case .folder: FolderView(model: model)
            case .recents: RecentsView(model: model)
            case .storage: StorageView(model: model)
            }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                model.goBack()
            } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .disabled(model.backStack.isEmpty)
            .help("Back (⌘[)")

            Button {
                model.goForward()
            } label: {
                Label("Forward", systemImage: "chevron.right")
            }
            .disabled(model.forwardStack.isEmpty)
            .help("Forward (⌘])")

            Button {
                model.goUp()
            } label: {
                Label("Enclosing Folder", systemImage: "arrow.up")
            }
            .disabled(!model.canGoUp)
            .help("Up to enclosing folder (⌘↑)")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if model.destination == .folder && !model.isSearching {
                Picker("Show", selection: $model.kindFilter) {
                    ForEach(KindFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("Show folders, files, or both")

                Menu {
                    Toggle("Folders First", isOn: $model.foldersFirst)
                    Toggle("Show Hidden Files", isOn: $model.showHidden)
                    Divider()
                    Button("New Folder…") { model.creating = .folder }
                    Button("New File…") { model.creating = .file }
                    Button("Recalculate Folder Sizes") { model.recalculateSizes() }
                    Button("Open in Terminal") { FileActions.openInTerminal(model.currentURL) }
                } label: {
                    Label("View Options", systemImage: "ellipsis.circle")
                }
            }

            Button {
                model.showInspector.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help("Show or hide details (⌘I)")
        }
    }

    private var subtitle: String {
        if model.isSearching { return "" }
        switch model.destination {
        case .folder: return Format.path(model.currentURL.deletingLastPathComponent().path)
        case .recents: return "Newest in your home folder"
        case .storage: return "What's using your disk"
        }
    }

    private var searchPrompt: String {
        model.searchScope == .mac ? "Search your Mac" : "Search \(FileManager.default.displayName(atPath: model.currentURL.path))"
    }

    private var searchKey: String {
        "\(model.searchText)|\(model.searchScope)|\(model.currentURL.path)|\(model.showHidden)"
    }

    private func runSearch() {
        if model.isSearching {
            model.search.run(text: model.searchText, scope: model.searchScope, folder: model.currentURL, includeHidden: model.showHidden)
        } else {
            model.search.clear()
        }
    }
}

private struct NamePrompt: View {
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

struct BrowserFocusKey: FocusedValueKey {
    typealias Value = BrowserModel
}

extension FocusedValues {
    var browser: BrowserModel? {
        get { self[BrowserFocusKey.self] }
        set { self[BrowserFocusKey.self] = newValue }
    }
}
