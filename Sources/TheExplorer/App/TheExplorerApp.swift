import SwiftUI

@main
struct TheExplorerApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        // Each window is a browser; windows group into native tabs (⌘T).
        WindowGroup(for: TabSeed.self) { $seed in
            BrowserWindow(seed: $seed)
        }
        .defaultSize(width: 1280, height: 800)
        .commands { ExplorerCommands() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { Tabs.saveSession() }
    }
}

private struct BrowserWindow: View {
    @Binding var seed: TabSeed?
    @Environment(\.openWindow) private var openWindow
    @State private var model: BrowserModel
    /// Opened without a value (app launch or ⌘N) rather than as a tab or by system restoration.
    @State private var startedFresh: Bool

    init(seed: Binding<TabSeed?>) {
        _seed = seed
        _model = State(initialValue: BrowserModel(url: seed.wrappedValue?.url))
        _startedFresh = State(initialValue: seed.wrappedValue == nil)
    }

    var body: some View {
        ContentView(model: model)
            .frame(minWidth: 760, minHeight: 440)
            .background(WindowAccessor { window in
                Tabs.configure(window, seedID: seed?.id, startedFresh: startedFresh, model: model, openWindow: openWindow)
            })
            .onAppear {
                model.start()
                if seed == nil { seed = TabSeed(path: model.currentURL.path) }
            }
            .onChange(of: model.currentURL) {
                // Keep the restorable value current so this tab reopens here next launch.
                seed?.path = model.currentURL.path
            }
            #if DEBUG
            .task { await DebugSnapshots.runIfRequested(model: model, openWindow: openWindow) }
            #endif
    }
}

struct ExplorerCommands: Commands {
    @FocusedValue(\.browser) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Tab") {
                Tabs.open(model?.currentURL ?? .home, with: openWindow)
            }
            .keyboardShortcut("t")
            Button("Open in New Tab") {
                guard let model else { return }
                for url in model.activeSelection where FileItem(url: url)?.isFolder == true {
                    Tabs.open(url, with: openWindow)
                }
            }
            .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            .disabled(!(model?.activeSelection.contains { FileItem(url: $0)?.isFolder == true } ?? false))
            Divider()
            Button("New Folder…") { model?.creating = .folder }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!(model?.canCreateItems ?? false))
            Button("New File…") { model?.creating = .file }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(!(model?.canCreateItems ?? false))
            Button("Open in Terminal") { model.map { FileActions.openInTerminal($0.currentURL) } }
                .keyboardShortcut("t", modifiers: [.command, .control])
                .disabled(model?.destination != .folder)
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Copy Path") { model.map { FileActions.copyPaths(pathTargets($0)) } }
                .keyboardShortcut("c", modifiers: [.command, .option])
            Button("Find") { model?.searchFocusRequest += 1 }
                .keyboardShortcut("f")
        }

        CommandMenu("Item") {
            Button("Open") { model?.openSelection() }
                .keyboardShortcut(.downArrow)
                .disabled(model?.activeSelection.isEmpty ?? true)
            Button("Quick Look") { model?.quickLook() }
                .keyboardShortcut("y")
            Button("Show in Enclosing Folder") {
                if let model, let url = model.activeSelection.first { model.reveal(url) }
            }
            .keyboardShortcut("r")
            .disabled(model?.activeSelection.count != 1)
            Button("Reveal in Finder") { model.map { FileActions.revealInFinder(pathTargets($0)) } }
                .keyboardShortcut("r", modifiers: [.command, .option])
            Divider()
            Button("Add to / Remove from Favorites") {
                guard let model else { return }
                let targets = pathTargets(model)
                let store = FavoritesStore.shared
                if targets.allSatisfy(store.contains) {
                    targets.forEach(store.remove)
                } else {
                    targets.forEach { store.add($0) }
                }
            }
            .keyboardShortcut("d")
            Button("Rename…") {
                guard let model, let url = model.selection.first, let item = FileItem(url: url) else { return }
                model.renaming = item
            }
            .keyboardShortcut(.return, modifiers: [.command, .shift])
            .disabled(model?.destination != .folder || model?.isSearching == true || model?.selection.count != 1)
            Divider()
            Button("Move to Trash") {
                // ⌘⌫ while typing in a text field should edit the text, never trash files.
                if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
                    editor.deleteToBeginningOfLine(nil)
                    return
                }
                guard let model else { return }
                if model.destination == .storage && !model.isSearching {
                    let storage = StorageModel.shared
                    storage.pendingTrash = storage.focus?.children.first { $0.id == storage.selection && $0.kind != .otherFiles }
                } else {
                    model.trash(model.activeSelection)
                }
            }
            .keyboardShortcut(.delete)
            .disabled(model?.activeSelection.isEmpty ?? true)
        }

        CommandGroup(after: .sidebar) {
            Button("Show Inspector") { model?.showInspector.toggle() }
                .keyboardShortcut("i")
            Button(model?.showHidden == true ? "Hide Hidden Files" : "Show Hidden Files") { model?.showHidden.toggle() }
                .keyboardShortcut(".", modifiers: [.command, .shift])
            Button("Folders First") { model?.foldersFirst.toggle() }
            Divider()
            Button("Refresh") { model?.reload(keepSelection: true) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Recalculate Folder Sizes") { model?.recalculateSizes() }
            Divider()
        }

        CommandMenu("Go") {
            Button("Back") { model?.goBack() }
                .keyboardShortcut("[")
                .disabled(model?.backStack.isEmpty ?? true)
            Button("Forward") { model?.goForward() }
                .keyboardShortcut("]")
                .disabled(model?.forwardStack.isEmpty ?? true)
            Button("Enclosing Folder") {
                guard let model else { return }
                if model.destination == .storage && !model.isSearching {
                    StorageModel.shared.focusParent()
                } else {
                    model.goUp()
                }
            }
            .keyboardShortcut(.upArrow)
            Divider()
            Button("Recents") { model?.show(.recents) }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Button("Storage") { model?.show(.storage) }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            Divider()
            Button("Home") { model?.navigate(to: .home) }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Desktop") { go(.desktopDirectory) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Button("Documents") { go(.documentDirectory) }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Downloads") { go(.downloadsDirectory) }
                .keyboardShortcut("l", modifiers: [.command, .option])
            Button("Applications") { model?.navigate(to: URL(fileURLWithPath: "/Applications")) }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            Divider()
            Button("Go to Path…") {
                model?.show(.folder)
                model?.isEditingPath = true
            }
            .keyboardShortcut("l")
            Button("Go to Folder…") {
                model?.show(.folder)
                model?.isEditingPath = true
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
        }
    }

    private func go(_ directory: FileManager.SearchPathDirectory) {
        if let url = FileManager.default.urls(for: directory, in: .userDomainMask).first {
            model?.navigate(to: url)
        }
    }

    /// The selection, or the current folder when nothing is selected.
    private func pathTargets(_ model: BrowserModel) -> [URL] {
        let selection = model.activeSelection
        if !selection.isEmpty { return Array(selection) }
        return model.destination == .folder ? [model.currentURL] : []
    }
}
