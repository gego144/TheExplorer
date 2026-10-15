import SwiftUI

@main
struct TheExplorerApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        // Each window holds its own tabs (drawn by the app, not macOS window tabs).
        WindowGroup(for: WindowState.self) { $state in
            WorkspaceWindow(state: $state)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 800)
        .commands { ExplorerCommands() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // The app draws its own tabs; turn off macOS window tabbing and its menu items.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Safety net: if macOS thought it restored windows but none came back (e.g. state saved by
        // an older build), open a fresh one instead of sitting there with no window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) else { return }
            Self.openNewWindow()
        }
    }

    /// The app saves and restores its own tabs (see Session), so skip macOS's window restoration;
    /// stale restoration data can otherwise stop SwiftUI from opening the first window.
    func application(_ app: NSApplication, shouldRestoreSecureApplicationState coder: NSCoder) -> Bool {
        false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { Session.save() }
    }

    /// Triggers File › New Window, the only way to open a SwiftUI window from outside a view.
    private static func openNewWindow() {
        let items = NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items) ?? []
        guard let item = items.first(where: { $0.keyEquivalent == "n" && $0.keyEquivalentModifierMask == .command }),
              let action = item.action else { return }
        NSApp.sendAction(action, to: item.target, from: item)
    }
}

private struct WorkspaceWindow: View {
    @Binding var state: WindowState?
    @State private var workspace: Workspace
    /// Other saved windows to reopen; only the first window of a launch gets these.
    @State private var pendingWindows: [WindowState]
    @Environment(\.openWindow) private var openWindow

    init(state: Binding<WindowState?>) {
        _state = state
        if let existing = state.wrappedValue {
            Session.markRestored()
            _workspace = State(initialValue: Workspace(state: existing))
            _pendingWindows = State(initialValue: [])
        } else {
            let saved = Session.takeSavedWindows()
            _workspace = State(initialValue: Workspace(state: saved.first))
            _pendingWindows = State(initialValue: Array(saved.dropFirst()))
        }
    }

    var body: some View {
        WorkspaceView(workspace: workspace)
            .frame(minWidth: 820, minHeight: 460)
            .onAppear {
                workspace.start()
                pendingWindows.forEach { openWindow(value: $0) }
                pendingWindows = []
                state = workspace.state
            }
            .onChange(of: workspace.state.paths) { state = workspace.state }
            .onChange(of: workspace.state.selected) { state = workspace.state }
            #if DEBUG
            .task { await DebugSnapshots.runIfRequested(workspace: workspace) }
            #endif
    }
}

struct ExplorerCommands: Commands {
    @FocusedValue(\.workspace) private var workspace

    private var model: BrowserModel? { workspace?.selected }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Tab") { workspace?.newTab() }
                .keyboardShortcut("t")
            Button("Open in New Tab") {
                guard let workspace, let model else { return }
                for url in model.activeSelection.sorted(by: { $0.path < $1.path }) where FileItem(url: url)?.isFolder == true {
                    workspace.newTab(url, select: false)
                }
            }
            .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            .disabled(!(model?.activeSelection.contains { FileItem(url: $0)?.isFolder == true } ?? false))
            Button("Close Tab") {
                guard let workspace else { return }
                if !workspace.close(workspace.selected) { NSApp.keyWindow?.performClose(nil) }
            }
            .keyboardShortcut("w")
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
            Button("Search") { model?.omniboxRequest = OmniboxRequest(text: "") }
                .keyboardShortcut("f")
            Button("Command Bar") { model?.omniboxRequest = OmniboxRequest(text: "") }
                .keyboardShortcut("k")
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
            Button("Pin / Unpin") {
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
            Button(Prefs.shared.showSidebar ? "Hide Sidebar" : "Show Sidebar") { Prefs.shared.showSidebar.toggle() }
                .keyboardShortcut("s", modifiers: [.command, .option])
            Button(Prefs.shared.showInspector ? "Hide Inspector" : "Show Inspector") { Prefs.shared.showInspector.toggle() }
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
            Button("Go to Path…") { goToPath() }
                .keyboardShortcut("l")
            Button("Go to Folder…") { goToPath() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
        }

        CommandGroup(before: .windowArrangement) {
            Button("Next Tab") { workspace?.selectNext() }
                .keyboardShortcut(.tab, modifiers: .control)
            Button("Previous Tab") { workspace?.selectPrevious() }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
            ForEach(1..<10) { number in
                Button(number == 9 ? "Last Tab" : "Tab \(number)") {
                    guard let workspace else { return }
                    workspace.select(number == 9 ? workspace.tabs.count - 1 : number - 1)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(number)")))
            }
            Divider()
        }
    }

    private func go(_ directory: FileManager.SearchPathDirectory) {
        if let url = FileManager.default.urls(for: directory, in: .userDomainMask).first {
            model?.navigate(to: url)
        }
    }

    /// Opens the command bar pre-filled with the current folder's path, ready to edit.
    private func goToPath() {
        guard let model else { return }
        if model.destination != .folder { model.show(.folder) }
        model.omniboxRequest = OmniboxRequest(text: Format.path(model.currentURL.path) + "/")
    }

    /// The selection, or the current folder when nothing is selected.
    private func pathTargets(_ model: BrowserModel) -> [URL] {
        let selection = model.activeSelection
        if !selection.isEmpty { return Array(selection) }
        return model.destination == .folder ? [model.currentURL] : []
    }
}
