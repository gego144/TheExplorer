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
        // Folders opened from outside go to AppDelegate, which puts them in a tab; otherwise
        // SwiftUI would open a new window for each one.
        .handlesExternalEvents(matching: [])
        .commands { ExplorerCommands() }

        Settings {
            SettingsView()
                .id(Prefs.shared.themeRevision)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // The app draws its own tabs; turn off macOS window tabbing and its menu items.
        NSWindow.allowsAutomaticWindowTabbing = false
        // "Show in Finder" from other apps, once TheExplorer is the file viewer (NSFileViewer).
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(reveal(_:withReplyEvent:)),
            forEventClass: AEEventClass(kAEMiscStandards), andEventID: AEEventID(kAEMakeObjectsVisible)
        )
    }

    /// The reveal event: shows each item selected in its folder.
    @objc private func reveal(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let direct = event.paramDescriptor(forKeyword: keyDirectObject) else { return }
        let items = direct.numberOfItems > 0 ? (1...direct.numberOfItems).compactMap { direct.atIndex($0) } : [direct]
        let urls = items.compactMap { item in
            item.coerce(toDescriptorType: typeFileURL).flatMap { URL(dataRepresentation: $0.data, relativeTo: nil) }
        }
        guard !urls.isEmpty else { return }
        show(urls, revealing: true)
    }

    private func show(_ urls: [URL], revealing: Bool) {
        MainActor.assumeIsolated {
            guard !Session.open(urls, revealing: revealing) else { return }
            // No window yet: the next one to appear picks them up. At launch that's the first
            // window; otherwise open one.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) else { return }
                Self.openNewWindow()
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Search's own index: built in the background, then kept current.
        FileIndex.shared.start()
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

    /// Folders from Finder's Open With, `open -a`, or anywhere once TheExplorer is the default
    /// file browser.
    func application(_ application: NSApplication, open urls: [URL]) {
        show(urls, revealing: false)
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { Session.save() }
        FileIndex.shared.saveIfNeeded()
        FolderVisits.shared.saveIfNeeded()
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
    @Environment(\.controlActiveState) private var controlActiveState

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
            // A new theme redraws the whole window with its colors.
            .id(Prefs.shared.themeRevision)
            .frame(minWidth: 820, minHeight: 460)
            .onAppear {
                workspace.start()
                pendingWindows.forEach { openWindow(value: $0) }
                pendingWindows = []
                Session.activated(workspace)
                Session.showPending(in: workspace)
                state = workspace.state
            }
            .onChange(of: controlActiveState) { _, active in
                if active == .key { Session.activated(workspace) }
            }
            .onChange(of: workspace.state.paths) { state = workspace.state }
            .onChange(of: workspace.state.selected) { state = workspace.state }
            #if DEBUG
            .task { await DebugSnapshots.runIfRequested(workspace: workspace) }
            #endif
    }
}

struct ExplorerCommands: Commands {
    @FocusedValue(\.workspace) private var focusedWorkspace
    /// The focused window's workspace. Scripted debug runs stay in the background, where no
    /// window counts as focused, so they fall back to the first window.
    private var workspace: Workspace? { focusedWorkspace ?? Session.scriptedWorkspace }

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
            Button(workspace?.isSplit == true ? "Close Pane" : "Close Tab") {
                guard let workspace else { return }
                if !workspace.closeActivePane() { NSApp.keyWindow?.performClose(nil) }
            }
            .keyboardShortcut("w")
            Divider()
            Button("New Folder…") { model?.creating = .folder }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!(model?.canCreateItems ?? false))
            Button("New File…") { model?.creating = .file }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(!(model?.canCreateItems ?? false))
            Button(FileActions.openInTerminalTitle) { model.map { FileActions.openInTerminal($0.currentURL) } }
                .keyboardShortcut("t", modifiers: [.command, .control])
                .disabled(model?.destination != .folder)
        }

        CommandGroup(replacing: .undoRedo) {
            HistoryCommands(workspace: workspace)
        }

        CommandGroup(replacing: .pasteboard) {
            ClipboardCommands(workspace: workspace)
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
            Button(FileActions.revealTitle) { model.map { FileActions.revealInFinder(pathTargets($0)) } }
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
            Button("Rename…") { model?.beginRename() }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled(!(model?.canRename ?? false))
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
            Divider()
            // Not disabled ahead of time (the menu bar isn't rebuilt when panes change); they
            // beep when there's no other pane to send to.
            Button("Copy to Other Pane") { sendToOtherPane(.copy) }
                .keyboardShortcut(Self.functionKey(NSF5FunctionKey), modifiers: [])
            Button("Move to Other Pane") { sendToOtherPane(.move) }
                .keyboardShortcut(Self.functionKey(NSF6FunctionKey), modifiers: [])
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
            Button(workspace?.isSplit == true ? "Close Split" : "Split Pane") { workspace?.toggleSplit() }
                .keyboardShortcut("/")
            Button("Switch Pane") { paneAction { $0.switchPane() } }
            Button("Swap Panes") { paneAction { $0.swapPanes() } }
            Button("Show Same Folder in Other Pane") { paneAction { $0.showSameFolderInOtherPane() } }
            Divider()
            Button("Refresh") {
                switch model?.destination {
                case .s3: model?.s3.reload(keepSelection: true)
                case .drive: model?.drive.reload(keepSelection: true)
                default: model?.reload(keepSelection: true)
                }
            }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Recalculate Folder Sizes") { model?.recalculateSizes() }
            Divider()
        }

        CommandMenu("Actions") {
            ActionCommands(workspace: workspace)
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
            Button("New") { model?.show(.newFiles) }
                .keyboardShortcut("e", modifiers: [.command, .shift])
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
            RecentFoldersMenu(model: model)
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

    /// Runs on the split tab showing now, or beeps when it isn't split.
    private func paneAction(_ action: (Workspace) -> Void) {
        guard let workspace = workspace ?? Session.scriptedWorkspace, workspace.isSplit else {
            NSSound.beep()
            return
        }
        action(workspace)
    }

    private func sendToOtherPane(_ mode: FileTransfer.Mode) {
        // F5 while typing in a text field does nothing to files.
        if NSApp.keyWindow?.firstResponder is NSTextView { return }
        guard let workspace = workspace ?? Session.scriptedWorkspace, workspace.sendToOtherPane(mode: mode) else {
            NSSound.beep()
            return
        }
    }

    static func functionKey(_ key: Int) -> KeyEquivalent {
        KeyEquivalent(Unicode.Scalar(UInt16(key)).map(Character.init) ?? " ")
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

/// Undo and Redo for file changes, from one history shared by every tab and window. While
/// you're typing in a text field they undo the typing instead.
private struct HistoryCommands: View {
    let workspace: Workspace?
    var body: some View {
        let history = FileHistory.shared
        Button(history.undoTitle) { perform(undo: true) }
            .keyboardShortcut("z")
        Button(history.redoTitle) { perform(undo: false) }
            .keyboardShortcut("z", modifiers: [.command, .shift])
    }

    private func perform(undo: Bool) {
        if NSApp.keyWindow?.firstResponder is NSTextView {
            NSApp.sendAction(Selector(undo ? "undo:" : "redo:"), to: nil, from: nil)
            return
        }
        // The tab that's showing now, not when the menu was built.
        let model = (workspace ?? Session.scriptedWorkspace)?.selected
        Task {
            let history = FileHistory.shared
            guard let outcome = await (undo ? history.undo() : history.redo()) else {
                NSSound.beep()
                return
            }
            model?.historyApplied(outcome, undo: undo)
        }
    }
}

/// Cut, Copy, Paste and Select All: for files in the list, or for text while you're typing.
private struct ClipboardCommands: View {
    let workspace: Workspace?

    var body: some View {
        Button("Cut") { perform("cut:") { model in
            let urls = sorted(model.activeSelection)
            guard !urls.isEmpty else { return false }
            FileClipboard.shared.cut(urls)
            return true
        } }
        .keyboardShortcut("x")
        Button("Copy") { perform("copy:") { model in
            let urls = sorted(model.activeSelection)
            guard !urls.isEmpty else { return false }
            FileClipboard.shared.copy(urls)
            return true
        } }
        .keyboardShortcut("c")
        Button("Paste") { perform("paste:") { $0.paste() } }
            .keyboardShortcut("v")
        Button("Paste and Move Here") { perform(nil) { $0.paste(move: true) } }
            .keyboardShortcut("v", modifiers: [.command, .option])
        Button("Duplicate") { perform(nil) { model in
            let urls = model.activeSelection.filter(\.isFileURL)
            guard !urls.isEmpty else { return false }
            model.duplicate(urls)
            return true
        } }
        Button("Select All") { perform("selectAll:") { model in
            model.selectAll()
            return true
        } }
        .keyboardShortcut("a")
    }

    /// Text editing gets `textAction`; otherwise `fileAction` runs on the tab showing now
    /// (menu bar items aren't rebuilt when it changes), with a beep if it couldn't.
    private func perform(_ textAction: String?, _ fileAction: (BrowserModel) -> Bool) {
        if NSApp.keyWindow?.firstResponder is NSTextView {
            if let textAction { NSApp.sendAction(Selector(textAction), to: nil, from: nil) }
            return
        }
        guard let model = (workspace ?? Session.scriptedWorkspace)?.selected, fileAction(model) else {
            NSSound.beep()
            return
        }
    }

    private func sorted(_ urls: Set<URL>) -> [URL] {
        urls.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}

/// The Actions menu: every action, with ⌃⌥1–9 for the first nine. Menu bar items aren't
/// rebuilt when the selection changes, so each one reads the selection when chosen (and beeps
/// if the action doesn't apply to it) rather than being enabled ahead of time.
private struct ActionCommands: View {
    let workspace: Workspace?
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let actions = ActionsStore.shared.actions
        ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
            let button = Button(action.name) { run(action) }
            if index < 9 {
                button.keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.control, .option])
            } else {
                button
            }
        }
        if !actions.isEmpty { Divider() }
        Button(actions.isEmpty ? "Add an Action…" : "Edit Actions…") {
            Prefs.shared.settingsTab = .actions
            openSettings()
        }
    }

    private func run(_ action: FileAction) {
        // The tab that's showing now, not when the menu was built.
        let model = (workspace ?? Session.scriptedWorkspace)?.selected
        let selection = model?.activeSelection ?? []
        let ordered = selection.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        if ActionRunner.shared.run(action, on: ordered) == nil { NSSound.beep() }
    }
}

/// Go › Recent Folders: the folders you visit most, like ⌘K lists before you type.
private struct RecentFoldersMenu: View {
    let model: BrowserModel?

    var body: some View {
        let folders = FolderVisits.shared.top(10)
        Menu("Recent Folders") {
            ForEach(folders, id: \.self) { url in
                Button(Format.path(url.path)) { model?.navigate(to: url) }
            }
            if !folders.isEmpty {
                Divider()
                Button("Clear Menu") { FolderVisits.shared.clear() }
            }
        }
        .disabled(folders.isEmpty || model == nil)
    }
}
