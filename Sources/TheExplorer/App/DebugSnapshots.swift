#if DEBUG
import AppKit
import SwiftUI

/// Debug-only scripted scenes with screenshots of the app's own window. Launch through
/// LaunchServices in the background so it never takes focus (running the binary directly can
/// leave the app without a window). Add EXPLORER_NO_CAPTURE=1 and `-j` to run fully hidden.
///
///     CONFIG=debug ./scripts/build-app.sh
///     open -g -n --env EXPLORER_SNAPSHOT_DIR=/tmp/shots --env EXPLORER_SNAPSHOT_QUIT=1 \
///         --env "EXPLORER_SCENES=folder:~/Dev;recents;search:swift;searchmac:swift;storage:~/Dev" \
///         build/debug/TheExplorer.app
/// Debug-only demo mode for README screenshots (EXPLORER_DEMO=1): only the startup disk in the
/// sidebar, pins from EXPLORER_DEMO_PINS (paths separated by ";", never saved), and windows
/// placed on a Retina screen when there is one, so captures are sharp.
@MainActor
enum DemoMode {
    static var isOn: Bool { ProcessInfo.processInfo.environment["EXPLORER_DEMO"] != nil }

    static var pins: [String]? {
        guard isOn, let value = ProcessInfo.processInfo.environment["EXPLORER_DEMO_PINS"] else { return nil }
        return value.split(separator: ";").map { NSString(string: String($0)).expandingTildeInPath }
    }

    /// Moves a window onto a 2x screen, behind everything else (it's never brought forward).
    static func place(_ window: NSWindow?) {
        guard isOn, let window, let screen = NSScreen.screens.first(where: { $0.backingScaleFactor >= 2 }) else { return }
        let frame = screen.visibleFrame
        window.setFrameOrigin(NSPoint(x: frame.minX + 20, y: frame.maxY - window.frame.height - 20))
    }
}

@MainActor
enum DebugSnapshots {
    private static var hasRun = false
    private static var settingsWindow: NSWindow?
    private static var eventLogMonitor: Any?

    static func runIfRequested(workspace: Workspace) async {
        let env = ProcessInfo.processInfo.environment
        guard !hasRun, let dir = env["EXPLORER_SNAPSHOT_DIR"], let scenes = env["EXPLORER_SCENES"] else { return }
        hasRun = true
        // Scripted runs usually launch hidden (open -g -j); keep App Nap from throttling them.
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated], reason: "Debug scenes")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        HangWatchdog.start()
        DemoMode.place(InputDriver.window)
        try? await Task.sleep(for: .seconds(1.5))

        for (index, scene) in scenes.split(separator: ";").enumerated() {
            let model = workspace.selected
            let parts = scene.split(separator: ":", maxSplits: 1).map(String.init)
            let argument = parts.count > 1 ? (parts[1] as NSString).expandingTildeInPath : ""
            var wait = 2.5
            switch parts[0] {
            case "folder": model.navigate(to: URL(fileURLWithPath: argument))
            case "select":
                // The listed rows themselves (listings say /private/tmp where you'd type /tmp),
                // falling back to the paths as given.
                let wanted = Set(argument.split(separator: ",").map { URL(fileURLWithPath: String($0)).standardizedFileURL.path })
                let rows = model.rows.filter { wanted.contains($0.id.standardizedFileURL.path) }.map(\.id)
                model.selection = rows.isEmpty ? Set(wanted.map { URL(fileURLWithPath: $0) }) : Set(rows)
            case "recents": model.show(.recents)
            case "new": model.show(.newFiles)
            case "expand": model.toggleExpanded(URL(fileURLWithPath: argument, isDirectory: true).standardizedFileURL)
            case "more": (model.destination == .newFiles ? model.newFiles : model.recents).loadMore()
            case "range":
                let recents = model.destination == .newFiles ? model.newFiles : model.recents
                if let days = Int(argument), let range = RecentsRange(rawValue: days) { recents.range = range }
            case "search":
                model.searchText = argument
            case "searchmac":
                model.searchScope = .mac
                model.searchText = argument
            case "storage":
                model.show(.storage)
                if !argument.isEmpty {
                    StorageModel.shared.target = .custom(URL(fileURLWithPath: argument).standardizedFileURL)
                    StorageModel.shared.scan()
                    while StorageModel.shared.isScanning { try? await Task.sleep(for: .milliseconds(200)) }
                }
            case "newtab": workspace.newTab(URL(fileURLWithPath: argument))
            case "tab": workspace.select((Int(argument) ?? 1) - 1)
            case "omnibox": model.omniboxRequest = OmniboxRequest(text: parts.count > 1 ? parts[1] : "")
            case "drop":
                // drop:<sources, comma-separated>><destination folder>, the same path a real drop
                // takes. "s3:bucket/key" names an S3 item in the first connection.
                let ends = (parts.count > 1 ? parts[1] : "").components(separatedBy: ">")
                model.receiveDrop(ends[0].split(separator: ",").map { Self.debugURL(String($0)) }, into: Self.debugURL(ends[1]))
            case "s3":
                // s3: shows the first connection; s3:bucket/prefix/ a folder in it.
                // The raw argument: tilde expansion would drop the trailing "/" that marks a folder.
                if let url = S3Location(url: Self.debugURL("s3:" + (parts.count > 1 ? parts[1] : ""))) { model.showS3(url) }
            case "promise":
                // promise:bucket/key>/dest/folder does what a drop on Finder does with an S3 item:
                // logs what the drag carries, then asks for the file in that folder.
                let ends = argument.components(separatedBy: ">")
                guard ends.count == 2, let promise = S3FilePromise(Self.debugURL("s3:" + ends[0])) else {
                    log("promise: not an S3 item")
                    break
                }
                let pasteboard = NSPasteboard(name: NSPasteboard.Name("TheExplorer.debug.drag.\(ProcessInfo.processInfo.processIdentifier)"))
                pasteboard.clearContents()
                pasteboard.writeObjects([promise])
                let carried = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
                log("promise types=\(pasteboard.types?.map(\.rawValue) ?? []) url=\(carried.map(\.absoluteString))")
                let delegate = promise.delegate
                let name = delegate?.filePromiseProvider(promise, fileNameForType: promise.fileType) ?? "?"
                let destination = URL(fileURLWithPath: ends[1]).appendingPathComponent(name)
                let result: Error?? = await withCheckedContinuation { continuation in
                    delegate?.filePromiseProvider(promise, writePromiseTo: destination) { continuation.resume(returning: .some($0)) }
                }
                log("promise name=\(name) type=\(promise.fileType) error=\(String(describing: result ?? nil))")
            case "split": workspace.toggleSplit()
            case "pane":
                // pane:1 or pane:2 makes that side of a split tab active.
                if let second = workspace.secondPane(of: workspace.currentTab) { workspace.activate(argument == "2" ? second : workspace.currentTab) }
            case "back": model.goBack()
            case "bigpreview":
                if argument.isEmpty { model.expandedPreview = nil } else { model.showExpandedPreview(URL(fileURLWithPath: argument)) }
            case "eventlog":
                // Logs mouse events the app receives (for real-mouse tests).
                eventLogMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { event in
                    if event.type != .leftMouseDragged || Int.random(in: 0..<8) == 0 {
                        log("event \(event.type.rawValue) at \(event.locationInWindow) window=\(event.window?.title ?? "nil")")
                    }
                    return event
                }
            case "place":
                // place:x,y puts the window's top-left there, in screen coordinates (top-left origin).
                let xy = argument.split(separator: ",").compactMap { Double($0) }
                if xy.count == 2, let window = InputDriver.window, let primary = NSScreen.screens.first {
                    window.setFrameTopLeftPoint(NSPoint(x: xy[0], y: primary.frame.height - xy[1]))
                }
            case "activate":
                // For tests with the real mouse (only when you've agreed to them): bring the window forward.
                NSApp.activate()
                InputDriver.window?.makeKeyAndOrderFront(nil)
            case "watchframes":
                // Logs every visible row's center in screen coordinates (top-left origin, as
                // CGEvent uses) twice a second, for an outside tool driving the real mouse.
                let until = Date().addingTimeInterval(Double(argument) ?? 30)
                while Date() < until {
                    if let window = InputDriver.window, let primary = NSScreen.screens.first {
                        let rows = RowGeometry.frames.map { url, frame -> String in
                            let x = window.frame.minX + frame.midX
                            let y = primary.frame.height - (window.frame.maxY - frame.midY)
                            return "\(url.lastPathComponent)=\(Int(x)),\(Int(y))"
                        }
                        log("frames " + rows.sorted().joined(separator: ";") + " selected=" + workspace.selected.selection.map(\.lastPathComponent).sorted().joined(separator: ","))
                    }
                    try? await Task.sleep(for: .milliseconds(500))
                }
            case "droptypes":
                // Views in the window that accept drags, and which view a point hits.
                func visit(_ view: NSView, depth: Int) {
                    if !view.registeredDraggedTypes.isEmpty {
                        log("droptypes \(String(repeating: " ", count: depth))\(view.className) frame=\(view.frame) types=\(view.registeredDraggedTypes.count)")
                    }
                    view.subviews.forEach { visit($0, depth: depth + 1) }
                }
                if let content = InputDriver.window?.contentView {
                    visit(content, depth: 0)
                    let hit = content.hitTest(NSPoint(x: 500, y: content.bounds.height - 200))
                    log("droptypes hit at (500,200): \(hit.map { $0.className } ?? "nil")")
                }
            case "transfers":
                for transfer in S3Transfers.shared.transfers {
                    log("transfer \(transfer.kind) \(transfer.title): \(transfer.state) \(transfer.doneItems)/\(transfer.totalItems) items \(transfer.doneBytes)/\(transfer.totalBytes) bytes")
                }
            case "probe":
                // Which protected locations can this build read? (Full Disk Access diagnostics)
                let home = URL.home.path
                for path in ["\(home)/Library/Application Support/com.apple.TCC", "\(home)/Library/Mail",
                             "\(home)/Library/Messages", "\(home)/Library/Safari", "\(home)/Library/Containers/com.apple.Notes",
                             "/Library/Application Support/com.apple.TCC"] {
                    let result: String
                    do { result = "ok (\(try FileManager.default.contentsOfDirectory(atPath: path).count) items)" }
                    catch { result = "DENIED: \((error as NSError).localizedDescription)" }
                    log("probe \(path): \(result)")
                }
                log("probe hasFullDiskAccess=\(StorageModel.checkFullDiskAccess()) bundle=\(Bundle.main.bundlePath)")
            case "create": model.creating = argument == "file" ? .file : .folder
            case "resize":
                let size = argument.split(separator: "x").compactMap { Double($0) }
                if size.count == 2, let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) {
                    window.setContentSize(NSSize(width: size[0], height: size[1]))
                }
            case "sort":
                if let key = SortKey(rawValue: argument) { model.sort = SortSpec(key: key, ascending: key == .name) }
            case "scope": model.searchScope = argument == "mac" ? .mac : .folder
            case "wait": wait = Double(argument) ?? 2
            case "terminal":
                Prefs.shared.terminalID = argument
                log("terminal -> \(FileActions.openInTerminalTitle) installed=\(Prefs.shared.terminal.isInstalled) app=\(Prefs.shared.terminal.appURL?.path ?? "none")")
            // Real input, delivered to this window only (see InputDriver).
            case "reveal":
                // The event other apps' "Show in Finder" sends to the file viewer, sent to ourselves.
                let event = NSAppleEventDescriptor(
                    eventClass: AEEventClass(kAEMiscStandards), eventID: AEEventID(kAEMakeObjectsVisible),
                    targetDescriptor: .currentProcess(), returnID: AEReturnID(kAutoGenerateReturnID),
                    transactionID: AETransactionID(kAnyTransactionID)
                )
                let list = NSAppleEventDescriptor.list()
                for path in argument.split(separator: ",") {
                    list.insert(NSAppleEventDescriptor(fileURL: URL(fileURLWithPath: String(path))), at: 0)
                }
                event.setParam(list, forKeyword: keyDirectObject)
                _ = try? event.sendEvent(options: [.noReply], timeout: 5)
            case "viewer":
                // Sets the file viewer (pass the current one to exercise the write without changing anything).
                do {
                    try FolderHandler.setViewer(argument)
                    Prefs.shared.refreshFileBrowser()
                    log("viewer set -> viewer=\(Prefs.shared.fileViewerID) opener=\(Prefs.shared.folderOpenerID) revealTitle=\(FileActions.revealTitle)")
                } catch {
                    log("viewer failed: \(error.localizedDescription)")
                }
            case "runs":
                // Logs every action run: state, progress and the end of its output.
                for run in ActionRunner.shared.runs {
                    let tail = run.output.split(separator: "\n").suffix(2).joined(separator: " ⏎ ")
                    log("run \(run.name): \(run.state) \(run.completed)/\(run.total) items=\(run.items.map(\.lastPathComponent)) output=\(tail.prefix(240))")
                }
            case "menu":
                // Logs a menu bar menu's items: title, enabled, shortcut.
                let menu = NSApp.mainMenu?.items.first { $0.title == argument }?.submenu
                // As when it opens, so SwiftUI brings its items up to date.
                if let menu {
                    menu.delegate?.menuNeedsUpdate?(menu)
                    menu.delegate?.menuWillOpen?(menu)
                    menu.update()
                    menu.delegate?.menuDidClose?(menu)
                }
                for item in menu?.items ?? [] where !item.isSeparatorItem {
                    log("menu \(argument) › \(item.title) enabled=\(item.isEnabled) key=\(item.keyEquivalent) mods=\(item.keyEquivalentModifierMask.rawValue)")
                }
            case "trash":
                // What Move to Trash, Rename… and New Folder… do once confirmed.
                model.trash([URL(fileURLWithPath: argument)])
            case "rename":
                let ends = argument.components(separatedBy: ">")
                if let item = FileItem(url: URL(fileURLWithPath: ends[0])) { model.rename(item, to: ends[1]) }
            case "mkdir": model.create(.folder, named: argument)
            case "openrule":
                // openrule:png,jpg>com.apple.Preview adds a default-app rule (in memory for scripted runs).
                let rule = argument.split(separator: ">", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                OpenWithRules.shared.add(extensions: FileAction.parseExtensions(rule[0]), appID: rule.count > 1 ? rule[1] : "")
            case "indexbench":
                // indexbench:q1,q2 logs the index's size and build time, then each query's time and best hits.
                await FileIndex.shared.waitUntilReady()
                let storage = FileIndex.shared.snapshot()
                log("index items=\(storage.liveCount) entries=\(storage.count) names=\(storage.names.count / 1024)KB \(FileIndex.shared.origin)")
                let boosts = FolderVisits.shared.searchBoosts()
                log("visit boosts=\(boosts.count)")
                for query in argument.split(separator: ",").map(String.init) {
                    var times: [Double] = []
                    var hits: [IndexHit] = []
                    for _ in 0..<5 {
                        let began = CACurrentMediaTime()
                        hits = FileIndex.search(query, in: storage, boosts: boosts, limit: SearchModel.indexResults)
                        times.append((CACurrentMediaTime() - began) * 1000)
                    }
                    log("query \"\(query)\" \(String(format: "%.1fms (best %.1fms)", times[0], times.min()!)) hits=\(hits.count): " + hits.prefix(8).map { Format.path($0.path) + "[\($0.score)]" }.joined(separator: " | "))
                }
            case "menuprobe":
                // menuprobe:<menu-style>:<dx>,<dy> clicks a ChromeMenu at that offset from its top-left
                // corner and logs whether its menu opened (then closes it).
                let fields = argument.components(separatedBy: ":")
                let offset = fields.count > 1 ? fields[1].split(separator: ",").compactMap { Double($0) } : [2, 2]
                if let (_, frame) = RowGeometry.frame(named: fields[0]), offset.count == 2 {
                    var opened = false
                    let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
                        opened = true
                        let menu = note.object as? NSMenu
                        RunLoop.main.perform(inModes: [.eventTracking, .common]) { menu?.cancelTracking() }
                    }
                    await InputDriver.click(at: CGPoint(x: frame.minX + offset[0], y: frame.minY + offset[1]))
                    try? await Task.sleep(for: .milliseconds(300))
                    NotificationCenter.default.removeObserver(observer)
                    log("menuprobe \(fields[0]) frame=\(frame) at +\(offset) opened=\(opened)")
                } else {
                    log("menuprobe: no menu named \(fields[0])")
                }
            case "rclick":
                // rclick:<row name>[:Submenu] right-clicks a row and logs its context menu (or that
                // submenu, with what's inside it), then closes it.
                let fields = argument.components(separatedBy: ":")
                if let (url, frame) = RowGeometry.frame(named: fields[0]) {
                    let depth = CGFloat(RowGeometry.depths[url] ?? 0)
                    let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
                        guard let menu = note.object as? NSMenu else { return }
                        let shown = fields.count > 1 ? menu.items.first { $0.title == fields[1] }?.submenu : menu
                        MainActor.assumeIsolated { Self.logMenu(shown ?? menu, depth: 0) }
                        RunLoop.main.perform(inModes: [.eventTracking, .common]) { menu.cancelTracking() }
                    }
                    await InputDriver.rightClick(at: CGPoint(x: frame.minX + 80 + depth * 16, y: frame.midY))
                    try? await Task.sleep(for: .milliseconds(300))
                    NotificationCenter.default.removeObserver(observer)
                } else {
                    log("\(scene): no row on screen with that name")
                }
            case "menuitem":
                // menuitem:Edit>Undo fires the first item in that menu whose title starts so.
                let names = argument.components(separatedBy: ">")
                if let menu = NSApp.mainMenu?.items.first(where: { $0.title == names[0] })?.submenu,
                   let index = menu.items.firstIndex(where: { $0.title.hasPrefix(names[1]) }) {
                    menu.performActionForItem(at: index)
                }
            case "stop":
                // Stops the newest running action, as its Stop button does.
                if let run = ActionRunner.shared.runs.first(where: { $0.state == .running }) { ActionRunner.shared.cancel(run.id) }
            case "settings", "actionruns", "actioneditor", "connectioneditor", "transferlist":
                // A window ordered in behind, so capture() picks it up. settings:actions opens that tab.
                if parts[0] == "settings" {
                    Prefs.shared.settingsTab = switch argument {
                    case "actions": .actions
                    case "cloud": .cloud
                    case "openwith": .openWith
                    default: .general
                    }
                }
                let root: AnyView = switch parts[0] {
                case "actionruns": AnyView(ActionRunsView(onClear: {}))
                case "actioneditor": AnyView(ActionEditor(action: FileAction.templates[0]) {})
                case "connectioneditor": AnyView(ConnectionEditor(draft: S3Store.shared.connections.first.map { ConnectionDraft($0) } ?? .keys()) {})
                case "transferlist": AnyView(TransfersView(onClear: {}))
                default: AnyView(SettingsView())
                }
                let window = NSWindow(contentViewController: NSHostingController(rootView: root))
                window.title = "Settings"
                window.orderFront(nil)
                DemoMode.place(window)
                settingsWindow = window
                if parts[0] == "actioneditor" {
                    // Typing scenes after this go to the command editor.
                    try? await Task.sleep(for: .milliseconds(300))
                    InputDriver.targetWindow = window
                    if let editor = Self.textViews(in: window.contentView).first(where: { $0.isRichText == false && $0.isEditable && $0.font?.isFixedPitch == true }) {
                        window.makeFirstResponder(editor)
                        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
                    }
                }
            case "editortext":
                let text = Self.textViews(in: settingsWindow?.contentView).first { $0.font?.isFixedPitch == true }?.string ?? "none"
                log("editor text: \(text.debugDescription)")
            case "key": InputDriver.press(parts[1])
            case "type": await InputDriver.type(parts.count > 1 ? parts[1] : "")
            case "drag":
                // drag:<row name> presses on a row and drags a little (multi-item drags only log).
                if let (url, frame) = RowGeometry.frame(named: parts.count > 1 ? parts[1] : "") {
                    let depth = CGFloat(RowGeometry.depths[url] ?? 0)
                    await InputDriver.pressAndDrag(at: CGPoint(x: frame.minX + 80 + depth * 16, y: frame.midY))
                } else {
                    log("\(scene): no row on screen with that name")
                }
            case "click", "dblclick", "cmdclick", "chevron":
                // click:<row name>; chevron clicks the folder arrow instead of the name.
                if let (url, frame) = RowGeometry.frame(named: parts.count > 1 ? parts[1] : "") {
                    let depth = CGFloat(RowGeometry.depths[url] ?? 0)
                    let x = parts[0] == "chevron" ? frame.minX + 15 + depth * 16 : frame.minX + 80 + depth * 16
                    await InputDriver.click(at: CGPoint(x: x, y: frame.midY), count: parts[0] == "dblclick" ? 2 : 1,
                                            flags: parts[0] == "cmdclick" ? .command : [])
                } else {
                    log("\(scene): no row on screen with that name")
                }
            case "dragrow":
                // dragrow:<row name>:<dx>: presses in the middle of a named element and drags
                // it sideways (the split divider is "split-divider").
                let pieces = (parts.count > 1 ? parts[1] : "").split(separator: ":").map(String.init)
                if let name = pieces.first, let (_, frame) = RowGeometry.frame(named: name), let dx = pieces.dropFirst().first.flatMap(Double.init) {
                    await InputDriver.drag(from: CGPoint(x: frame.midX, y: frame.midY), by: dx)
                    log("\(scene): divider at \(RowGeometry.frame(named: name).map { Int($0.1.midX) } ?? -1)")
                } else {
                    log("\(scene): no row on screen with that name")
                }
            case "clickat":
                // clickat:<x>,<y>[,<clicks>]: a click at a point in the window, in points from the
                // top left; a third number makes it a double (or triple) click.
                let numbers = argument.split(separator: ",").compactMap { Double($0) }
                if numbers.count >= 2 {
                    await InputDriver.click(at: CGPoint(x: numbers[0], y: numbers[1]), count: numbers.count > 2 ? Int(numbers[2]) : 1)
                }
            case "scroll":
                let report = await InputDriver.scroll(points: Double(argument).map { CGFloat($0) })
                log("\(scene) scroll: \(report)")
                wait = 0.5
            default: break
            }
            let began = Date()
            HangWatchdog.reset()
            var firstContent: TimeInterval?
            while Date().timeIntervalSince(began) < wait {
                if firstContent == nil, hasContent(workspace.selected) { firstContent = Date().timeIntervalSince(began) }
                try? await Task.sleep(for: .milliseconds(20))
            }
            let shown = workspace.selected
            log("\(scene) timing: first content \(firstContent.map { String(format: "%.2fs", $0) } ?? "never"), worst main-thread stall \(HangWatchdog.worst)ms, stalls>100ms \(HangWatchdog.stalls) · recents=\(shown.recents.rows.count) new=\(shown.newFiles.rows.count) total=\(shown.newFiles.totalCount.map(String.init) ?? "nil") more=\(shown.newFiles.hasMore) gathering=\(shown.newFiles.isGathering) hits=\(shown.search.hits.count)")
            let names = shown.rows.prefix(40).map { "\($0.item.name)@\(RelativeTime.short($0.item.modified))" }.joined(separator: ",")
            let selected = shown.selection.map(\.lastPathComponent).sorted().joined(separator: ",")
            log("\(scene) -> tabs=\(workspace.tabs.count) panes=\(workspace.secondPane(of: workspace.currentTab).map { "\(workspace.currentTab.currentURL.lastPathComponent)|\($0.currentURL.lastPathComponent) active=\(workspace.selected === $0 ? 2 : 1)" } ?? "1") view=\(shown.destination) search=\"\(shown.searchText)\" expanded=\(shown.expanded.map(\.lastPathComponent).sorted()) firstResponder=\(InputDriver.window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil") key=\(InputDriver.window?.isKeyWindow ?? false) active=\(NSApp.isActive) url=\(shown.currentURL.path) items=[\(names)] selected=[\(selected)] error=\(shown.loadError ?? "none") preview=\(shown.previewURL?.lastPathComponent ?? "nil")/\(shown.previewItems.count) big=\(shown.expandedPreview?.lastPathComponent ?? "nil") s3=\(shown.destination == .s3 ? (shown.s3.location?.uri ?? "?") + " rows=\(shown.s3.rows.map(\.item.name))" + (shown.s3.error.map { " error=\($0)" } ?? "") : "-") windows=\(NSApp.windows.filter { $0.isVisible && $0.canBecomeMain }.map(\.title)) git=\(gitSummary(shown)) undoMenu=\(undoMenuTitles()) history=\(FileHistory.shared.undoStack.map(\.name))/\(FileHistory.shared.redoStack.map(\.name))")
            if env["EXPLORER_NO_CAPTURE"] == nil { capture(to: "\(dir)/\(index)-\(parts[0]).png") }
        }
        if env["EXPLORER_SNAPSHOT_QUIT"] != nil { NSApp.terminate(nil) }
    }

    /// "main/2 a.txt:changed(modified),…": the branch, change count and each row's mark.
    private static func gitSummary(_ model: BrowserModel) -> String {
        guard let snapshot = model.git?.snapshot else { return "none" }
        let marks = model.rows.compactMap { row in
            snapshot.mark(for: row.id.standardizedFileURL.path).map { "\(row.item.name):\($0)" }
        }
        return "\(snapshot.branch ?? "?")/\(snapshot.changeCount) " + marks.joined(separator: ",")
    }

    /// What the Edit menu's ⌘Z and ⇧⌘Z items say right now.
    private static func undoMenuTitles() -> [String] {
        NSApp.mainMenu?.items.flatMap { $0.submenu?.items ?? [] }
            .filter { $0.keyEquivalent.lowercased() == "z" }
            .map { "\($0.title) enabled=\($0.isEnabled) action=\($0.action.map(NSStringFromSelector) ?? "nil")" } ?? []
    }

    private static func hasContent(_ model: BrowserModel) -> Bool {
        if model.isSearching { return !model.search.hits.isEmpty }
        switch model.destination {
        case .recents: return !model.recents.rows.isEmpty
        case .newFiles: return !model.newFiles.rows.isEmpty
        case .folder: return !model.items.isEmpty
        case .storage: return StorageModel.shared.focus != nil
        case .s3: return !model.s3.rows.isEmpty || model.s3.error != nil
        }
    }

    /// A file path, or "s3:bucket/key" for an item in the first S3 connection.
    private static func debugURL(_ text: String) -> URL {
        if text.hasPrefix("s3:"), let connection = S3Store.shared.connections.first {
            let path = text.dropFirst(3)
            guard let slash = path.firstIndex(of: "/") else {
                return path.isEmpty ? connection.root.url : S3Location.url(connectionID: connection.id, bucket: String(path), key: "")
            }
            return S3Location.url(connectionID: connection.id, bucket: String(path[..<slash]), key: String(path[path.index(after: slash)...]))
        }
        return URL(fileURLWithPath: (text as NSString).expandingTildeInPath)
    }

    private static func textViews(in view: NSView?) -> [NSTextView] {
        guard let view else { return [] }
        return (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(textViews)
    }

    private static func logMenu(_ menu: NSMenu, depth: Int) {
        menu.delegate?.menuNeedsUpdate?(menu)
        menu.update()
        for item in menu.items {
            let mark = item.state == .on ? "✓ " : ""
            log(String(repeating: "  ", count: depth) + (item.isSeparatorItem ? "—" : "\(mark)\(item.title)\(item.image == nil ? "" : " [icon]")"))
            if let submenu = item.submenu, depth < 2 { logMenu(submenu, depth: depth + 1) }
        }
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data(("[snapshot] " + message + "\n").utf8))
    }

    private typealias WindowImageFn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    /// Uses the window server so glass, toolbars and tables render as they appear on screen.
    /// CGWindowListCreateImage is obsoleted in the macOS 15 SDK, so it's looked up at runtime;
    /// capturing your own windows needs no Screen Recording permission.
    private static func capture(to path: String) {
        // The frontmost of the app's windows (e.g. Settings once it's open).
        guard let window = NSApp.orderedWindows.first(where: { $0.isVisible && $0.contentView != nil }),
              let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return }
        let create = unsafeBitCast(symbol, to: WindowImageFn.self)
        // kCGWindowListOptionIncludingWindow = 8, kCGWindowImageBoundsIgnoreFraming = 1
        guard let image = create(.null, 8, UInt32(window.windowNumber), 1)?.takeRetainedValue() else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

/// Measures how long the main thread takes to answer a ping; anything over ~100ms is a visible
/// stutter, and over a second is a beach ball.
enum HangWatchdog {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var worstMs = 0
    nonisolated(unsafe) private static var stallCount = 0
    nonisolated(unsafe) private static var started = false

    static var worst: Int { lock.withLock { worstMs } }
    static var stalls: Int { lock.withLock { stallCount } }

    static func reset() {
        lock.withLock { worstMs = 0; stallCount = 0 }
    }

    static func start() {
        guard lock.withLock({ let was = started; started = true; return !was }) else { return }
        Thread.detachNewThread {
            while true {
                let sent = Date()
                let answered = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { answered.signal() }
                answered.wait()
                let ms = Int(Date().timeIntervalSince(sent) * 1000)
                lock.withLock {
                    worstMs = max(worstMs, ms)
                    if ms > 100 { stallCount += 1 }
                }
                if ms > 250 { FileHandle.standardError.write(Data("[hang] main thread blocked \(ms)ms\n".utf8)) }
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
    }
}
#endif
