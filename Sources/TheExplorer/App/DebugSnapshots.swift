#if DEBUG
import AppKit
import QuickLookUI
import SwiftUI

/// Debug-only scripted scenes with screenshots of the app's own window. Launch through
/// LaunchServices in the background so it never takes focus (running the binary directly can
/// leave the app without a window). Add EXPLORER_NO_CAPTURE=1 and `-j` to run fully hidden.
///
///     CONFIG=debug ./scripts/build-app.sh
///     open -g -n --env EXPLORER_SNAPSHOT_DIR=/tmp/shots --env EXPLORER_SNAPSHOT_QUIT=1 \
///         --env "EXPLORER_SCENES=folder:~/Dev;recents;search:swift;searchmac:swift;storage:~/Dev" \
///         build.noindex/debug/TheExplorer.app
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
    /// Whether scripted scenes are driving the app (it then runs in the background).
    static var isRunning: Bool { hasRun }
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
            case "find":
                // find: opens Find (⌘F); find:<text> hands it text, as ⌘K's Find line does.
                model.openFind(argument.isEmpty ? nil : argument)
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
                    if let result = StorageModel.shared.result {
                        log("\(scene): \(String(format: "%.2fs", result.duration)), \(Format.bytes(result.root.size)), \(result.root.fileCount) files, \(result.unreadableFolders) unreadable")
                    }
                }
            case "typewatch":
                // typewatch:<text>[|<seconds>] types into whatever has focus at a person's pace
                // (a key every 250ms) and logs every change in how many results the list shows,
                // with what was typed by then, then keeps watching for <seconds> (3). A count that
                // drops and comes back is the list flickering.
                let pieces = (parts.count > 1 ? parts[1] : "").components(separatedBy: "|")
                let settle = pieces.count > 1 ? Double(pieces[1]) ?? 3 : 3
                let start = Date()
                var last = -1
                var typed = ""
                var changes: [String] = []
                // What the list on screen shows (the table updated last).
                func shown() -> Int { FileTableController.debugLast?.rows.count ?? -1 }
                func sample() {
                    let count = shown()
                    guard count != last else { return }
                    last = count
                    changes.append(String(format: "%.2fs \"%@\"=%d", Date().timeIntervalSince(start), typed, count))
                }
                for character in pieces[0] {
                    await InputDriver.type(String(character))
                    typed.append(character)
                    for _ in 0..<25 {
                        sample()
                        try? await Task.sleep(for: .milliseconds(10))
                    }
                }
                let typedAt = Date()
                while Date().timeIntervalSince(typedAt) < settle {
                    sample()
                    try? await Task.sleep(for: .milliseconds(10))
                }
                log("\(parts[0]): \(changes.joined(separator: "  "))")
                if model.destination == .s3 { log("\(parts[0]): s3 names read \(model.s3.searchChecked), still running \(model.s3.isSearchRunning)") }
                wait = 0
            case "rowcounts":
                // rowcounts:<seconds> logs every change in how many rows the list shows.
                if model.destination == .storage { model.show(.recents) }
                let start = Date()
                var last = -1
                var changes: [String] = []
                while Date().timeIntervalSince(start) < (Double(argument) ?? 2) {
                    let list = model.destination == .newFiles ? model.newFiles : model.recents
                    let count = model.destination == .folder ? model.rows.count : list.rows.count
                    if count != last {
                        last = count
                        changes.append(String(format: "%.2fs=%d", Date().timeIntervalSince(start), last))
                    }
                    try? await Task.sleep(for: .milliseconds(10))
                }
                log("\(scene): \(changes.joined(separator: " "))")
                wait = 0
            case "qlstate":
                // qlstate logs whether the Quick Look panel is up, and where in its list.
                if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared() {
                    log("qlstate: visible=\(panel.isVisible) index=\(panel.currentPreviewItemIndex) of \(panel.dataSource?.numberOfPreviewItems(in: panel) ?? -1)")
                } else {
                    log("qlstate: no panel")
                }
                wait = 0
            case "layout":
                // layout:gallery|list shows the current place that way (remembered for the run's
                // own settings only: debug builds have their own).
                model.layout = argument == "gallery" ? .gallery : .list
            case "tilesize":
                Prefs.shared.galleryTileSize = Double(argument) ?? 180
            case "scanstart":
                // scanstart:<path> starts a Storage scan without waiting for it, to see it run.
                model.show(.storage)
                StorageModel.shared.target = .custom(URL(fileURLWithPath: argument).standardizedFileURL)
                StorageModel.shared.scan()
            case "scanstop":
                // scanstop logs whether the app is still busy a moment after Stop.
                StorageModel.shared.cancel()
                let before = InputDriver.processCPU()
                try? await Task.sleep(for: .seconds(1))
                log("scanstop: \(String(format: "%.2f", InputDriver.processCPU() - before))s of CPU in the second after stopping")
                wait = 0
            case "drill":
                // drill:<name> opens a folder in Storage, as double-clicking it does, and logs
                // what's inside once its files are listed.
                let storage = StorageModel.shared
                if let node = (storage.focus ?? storage.result?.root)?.children.first(where: { $0.name == parts[1] }) {
                    storage.drill(into: node)
                    try? await Task.sleep(for: .milliseconds(500))
                    log("\(scene): \(node.children.prefix(8).map { "\($0.name)=\(Format.bytes($0.size))" }) of \(Format.bytes(node.size)), \(node.fileCount) files")
                } else {
                    log("\(scene): no folder named that")
                }
            case "scrollviews":
                // scrollviews logs every scroll view in the window: frame, and content height.
                var found: [String] = []
                func visit(_ view: NSView) {
                    if let scroll = view as? NSScrollView {
                        found.append("\(Int(scroll.frame.width))x\(Int(scroll.frame.height)) content \(Int(scroll.documentView?.frame.height ?? 0)) at y \(Int(scroll.contentView.bounds.origin.y))")
                    }
                    view.subviews.forEach(visit)
                }
                if let content = InputDriver.window?.contentView { visit(content) }
                log("\(scene): \(found)")
                wait = 0
            case "share":
                // share:<id> opens the Share sheet for a Drive item in the first account and logs
                // who has access once it's loaded.
                model.drive.share(Self.debugURL("drive:" + (parts.count > 1 ? parts[1] : "")))
                if let sharing = model.drive.sharing {
                    while sharing.isLoading { try? await Task.sleep(for: .milliseconds(50)) }
                    log("\(scene): \(Self.sharingSummary(sharing))")
                }
            case "shareadd", "sharerole", "shareremove", "shareaccess", "shareclose":
                // shareadd:<a@x,b@y>><role>[>quiet[>message]], sharerole:<email>><role>,
                // shareremove:<email>, shareaccess:restricted|anyone:<role>|domain:<name>:<role>,
                // shareclose: what the Share sheet's controls do, then the result.
                guard let sharing = model.drive.sharing else {
                    log("\(scene): no Share sheet open")
                    break
                }
                let fields = (parts.count > 1 ? parts[1] : "").components(separatedBy: ">")
                let role = { (name: String) in DrivePermission.Role(rawValue: name) ?? .reader }
                let person = { (email: String) in sharing.people.first { $0.email?.caseInsensitiveCompare(email) == .orderedSame } }
                switch parts[0] {
                case "shareadd":
                    _ = await sharing.add(fields[0].components(separatedBy: ","), role: role(fields.count > 1 ? fields[1] : "reader"),
                                          notify: fields.count < 3 || fields[2] != "quiet", message: fields.count > 3 ? fields[3] : "")
                case "sharerole":
                    if let p = person(fields[0]) { await sharing.setRole(role(fields.count > 1 ? fields[1] : "reader"), for: p) }
                case "shareremove":
                    if let p = person(fields[0]) { await sharing.remove(p) }
                case "shareaccess":
                    let pieces = fields[0].components(separatedBy: ":")
                    switch pieces[0] {
                    case "anyone": await sharing.setAccess(.anyone(role(pieces.count > 1 ? pieces[1] : "reader")))
                    case "domain": await sharing.setAccess(.domain(pieces.count > 1 ? pieces[1] : "", role(pieces.count > 2 ? pieces[2] : "reader")))
                    default: await sharing.setAccess(.restricted)
                    }
                default:
                    model.drive.sharing = nil
                }
                log("\(scene): \(Self.sharingSummary(sharing))")
            case "foldersize":
                // foldersize:<path> logs the folder's measured size, if there is one yet.
                let size = FolderSizeStore.shared.size(for: argument)
                log("\(scene): \(size.map { "\($0.bytes) bytes, \($0.files) files" } ?? "none")\(FolderSizeStore.shared.isCalculating(argument) ? ", calculating" : "")")
                wait = 0
            case "idle":
                // idle:<seconds> sits still and logs the CPU the app used meanwhile, all threads.
                let seconds = Double(argument) ?? 10
                let before = InputDriver.processCPU()
                try? await Task.sleep(for: .seconds(seconds))
                log("\(scene): cpu \(Int((InputDriver.processCPU() - before) * 1000))ms over \(Int(seconds))s")
                wait = 0
            case "newtab": workspace.newTab(URL(fileURLWithPath: argument))
            case "tab": workspace.select((Int(argument) ?? 1) - 1)
            case "omnibox": model.omniboxRequest = OmniboxRequest(text: parts.count > 1 ? parts[1] : "")
            case "drop", "dropother":
                // drop:<sources, comma-separated>><destination folder>, the same path a real drop
                // takes. "s3:bucket/key" names an S3 item in the first connection. dropother drops
                // into the split's other pane (the one not active), as a drag across would.
                let ends = (parts.count > 1 ? parts[1] : "").components(separatedBy: ">")
                let target = parts[0] == "dropother" ? workspace.otherPane ?? model : model
                target.receiveDrop(ends[0].split(separator: ",").map { Self.debugURL(String($0)) }, into: Self.debugURL(ends[1]))
            case "s3":
                // s3: shows the first connection; s3:bucket/prefix/ a folder in it.
                // The raw argument: tilde expansion would drop the trailing "/" that marks a folder.
                if let url = S3Location(url: Self.debugURL("s3:" + (parts.count > 1 ? parts[1] : ""))) { model.showS3(url) }
            case "bench":
                // bench[:<rounds>]: clicks and presses through everyday navigation in the folder
                // showing (it needs folders "Alpha" and "Beta" in it; scripts/bench-fixture.sh),
                // timing each with LatencyMeter, and logs a table of response and done times.
                await Bench.run(rounds: Int(argument) ?? 5, workspace: workspace, log: log)
            case "selloop":
                // selloop:<n> moves the selection through the list n times, 60ms apart, so a
                // profiler sees nothing but what a selection change costs.
                let rows = model.rows
                let count = Int(argument) ?? 100
                let before = InputDriver.processCPU()
                let mainBefore = LatencyMeter.mainThreadCPU()
                for index in 0..<count where !rows.isEmpty {
                    model.selection = [rows[index % rows.count].id]
                    try? await Task.sleep(for: .milliseconds(60))
                }
                let perChange = { (seconds: Double) in String(format: "%.1f", seconds * 1000 / Double(max(count, 1))) }
                log("\(scene): \(perChange(LatencyMeter.mainThreadCPU() - mainBefore))ms on the main thread per change, \(perChange(InputDriver.processCPU() - before))ms of CPU in all")
            case "navloop":
                // navloop:<n> goes into the first folder and back up, n times, 80ms apart, and
                // logs the main thread's time per move.
                let home = model.currentURL
                guard let folder = model.rows.first(where: { $0.item.isFolder })?.id else { break }
                let count = Int(argument) ?? 50
                let mainBefore = LatencyMeter.mainThreadCPU()
                for index in 0..<(count * 2) {
                    model.navigate(to: index.isMultiple(of: 2) ? folder : home)
                    try? await Task.sleep(for: .milliseconds(80))
                }
                log("\(scene): \(String(format: "%.1f", (LatencyMeter.mainThreadCPU() - mainBefore) * 1000 / Double(count * 2)))ms on the main thread per move")
            case "tabloop":
                // tabloop:<n> opens a new tab and closes it, n times, 120ms apart, and logs the
                // main thread's time per open and per close.
                let count = Int(argument) ?? 30
                var opening = 0.0
                var closing = 0.0
                for _ in 0..<count {
                    var before = LatencyMeter.mainThreadCPU()
                    workspace.newTab()
                    try? await Task.sleep(for: .milliseconds(120))
                    opening += LatencyMeter.mainThreadCPU() - before
                    before = LatencyMeter.mainThreadCPU()
                    workspace.close(workspace.currentTab)
                    try? await Task.sleep(for: .milliseconds(120))
                    closing += LatencyMeter.mainThreadCPU() - before
                }
                log("\(scene): \(String(format: "%.1f", opening * 1000 / Double(count)))ms per new tab, \(String(format: "%.1f", closing * 1000 / Double(count)))ms per close, on the main thread")
            case "navtime":
                // navtime:<n> goes into the first folder and back up, n times, and logs how long
                // each move took to put the new folder's rows in the list (median and worst).
                let home = model.currentURL.standardizedFileURL
                guard let folder = model.rows.first(where: { $0.item.isFolder })?.id.standardizedFileURL else { break }
                var times: [Double] = []
                for index in 0..<((Int(argument) ?? 20) * 2) {
                    let target = index.isMultiple(of: 2) ? folder : home
                    let start = ProcessInfo.processInfo.systemUptime
                    model.navigate(to: target)
                    while ProcessInfo.processInfo.systemUptime - start < 1 {
                        if let shown = FileTableController.debugReloaded, shown.folder == target.path, shown.at >= start {
                            times.append((shown.at - start) * 1000)
                            break
                        }
                        try? await Task.sleep(for: .microseconds(300))
                    }
                    try? await Task.sleep(for: .milliseconds(80))
                }
                times.sort()
                log("\(scene): rows on screen after \(String(format: "%.1f", times.isEmpty ? -1 : times[times.count / 2]))ms median, \(String(format: "%.1f", times.last ?? -1))ms worst, \(times.count) moves")
            case "uploop":
                // uploop:<n> goes into the first folder and back up (which selects it), n times,
                // and logs the main thread's time per move up.
                guard let folder = model.rows.first(where: { $0.item.isFolder })?.id else { break }
                let count = Int(argument) ?? 30
                var total = 0.0
                for _ in 0..<count {
                    model.navigate(to: folder)
                    try? await Task.sleep(for: .milliseconds(120))
                    let before = LatencyMeter.mainThreadCPU()
                    model.goUp()
                    try? await Task.sleep(for: .milliseconds(120))
                    total += LatencyMeter.mainThreadCPU() - before
                }
                log("\(scene): \(String(format: "%.1f", total * 1000 / Double(count)))ms on the main thread per move up")
            case "kloop":
                // kloop:<n> opens the command bar (⌘K) and closes it (esc), n times, and logs the
                // main thread's time per open and per close.
                let count = Int(argument) ?? 20
                var opening = 0.0, closing = 0.0
                RegionHostingView.layoutTime = [:]
                for _ in 0..<count {
                    var before = LatencyMeter.mainThreadCPU()
                    InputDriver.press("cmd+k")
                    try? await Task.sleep(for: .milliseconds(150))
                    opening += LatencyMeter.mainThreadCPU() - before
                    before = LatencyMeter.mainThreadCPU()
                    InputDriver.press("esc")
                    try? await Task.sleep(for: .milliseconds(150))
                    closing += LatencyMeter.mainThreadCPU() - before
                }
                log("\(scene): \(String(format: "%.1f", opening * 1000 / Double(count)))ms per open, \(String(format: "%.1f", closing * 1000 / Double(count)))ms per close, on the main thread")
                log("\(scene) layout per open+close: " + RegionHostingView.layoutTime.map { "\($0.key.isEmpty ? "?" : $0.key) \(String(format: "%.1f", $0.value * 1000 / Double(count)))ms" }.sorted().joined(separator: ", "))
            case "galloop":
                // galloop:<n> switches between list and gallery n times, 150ms apart, and logs the
                // main thread's time per switch.
                let count = Int(argument) ?? 20
                let before = LatencyMeter.mainThreadCPU()
                for index in 0..<count {
                    model.layout = index.isMultiple(of: 2) ? .gallery : .list
                    try? await Task.sleep(for: .milliseconds(150))
                }
                log("\(scene): \(String(format: "%.1f", (LatencyMeter.mainThreadCPU() - before) * 1000 / Double(count)))ms per switch on the main thread")
            case "switchloop":
                // switchloop:<n> opens a second tab and switches between the two, n times, 120ms
                // apart, and logs the main thread's time per switch.
                let count = Int(argument) ?? 30
                if workspace.tabs.count < 2 { workspace.newTab() }
                try? await Task.sleep(for: .milliseconds(500))
                let before = LatencyMeter.mainThreadCPU()
                for index in 0..<count {
                    workspace.select(index % 2)
                    try? await Task.sleep(for: .milliseconds(120))
                }
                log("\(scene): \(String(format: "%.1f", (LatencyMeter.mainThreadCPU() - before) * 1000 / Double(count)))ms per switch on the main thread")
            case "rowmenu":
                // rowmenu:<row name> builds the right-click menu for that row (or the list's own
                // menu, with no name) without showing it, and logs its items.
                if let controller = FileTableController.debugLast {
                    let line = RowGeometry.frame(named: argument).flatMap { controller.line(of: $0.0) } ?? -1
                    if let menu = controller.menu(forLine: line) {
                        menu.update()
                        func titles(_ menu: NSMenu) -> String {
                            menu.items.map { $0.isSeparatorItem ? "|" : $0.title + ($0.submenu.map { "{" + titles($0) + "}" } ?? "") }.joined(separator: ", ")
                        }
                        log("\(scene) -> \(titles(menu))")
                    }
                }
            case "press":
                // press:<name>: clicks the middle of a named element (a tab is "tab-0", the new
                // tab button "newtab-button", a sidebar place "sidebar-Downloads").
                if let (_, frame) = RowGeometry.frame(named: argument) {
                    await InputDriver.click(at: CGPoint(x: frame.midX, y: frame.midY))
                } else {
                    log("\(scene): nothing on screen with that name")
                }
            case "phonelink":
                // phonelink shows the "From iPhone" setup sheet (which turns receiving on) and
                // logs the link the QR code holds.
                PhoneLink.shared.showSetup()
                try? await Task.sleep(for: .seconds(1.5))
                let link = PhoneLink.shared
                log("\(scene) -> on=\(link.isOn) listening=\(link.isListening) error=\(link.error ?? "none") url=\(link.pageURL.absoluteString) address=\(link.addressURL?.absoluteString ?? "none") received=\(link.receivedCount)")
            case "drive":
                // drive: shows the first account's My Drive; drive:<id>/ a folder in it, and
                // drive:~/, drive:~shared/ and the like its lists.
                // The raw argument: tilde expansion would turn "~/" into the home folder.
                let raw = parts.count > 1 ? parts[1] : DriveLocation.myDriveID + "/"
                if let location = DriveLocation(url: Self.debugURL("drive:" + raw)) {
                    model.showDrive(location)
                }
            case "drivesignin":
                // Signs in against the test server (EXPLORER_DRIVE_ENDPOINT), as Add Account does.
                do {
                    let account = try await DriveStore.shared.signIn()
                    log("drivesignin ok email=\(account.email) accounts=\(DriveStore.shared.accounts.map(\.email))")
                } catch {
                    log("drivesignin error=\(error.localizedDescription)")
                }
            case "promise":
                // promise:bucket/key>/dest/folder does what a drop on Finder does with an S3 item
                // (or promise:drive:<id>>/dest/folder with a Drive file): logs what the drag
                // carries, then asks for the file in that folder.
                let ends = argument.components(separatedBy: ">")
                let source = ends.first.map { $0.hasPrefix("drive:") ? $0 : "s3:" + $0 } ?? ""
                guard ends.count == 2, let promise = RemoteFilePromise(Self.debugURL(source)) else {
                    log("promise: not an S3 or Drive item")
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
            case "theme":
                // theme:<system|dark|graphite|midnight|light> shows a theme for the run, unsaved.
                if let choice = ThemeChoice(rawValue: argument) { Prefs.shared.previewTheme(choice) }
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
            case "unpin":
                // unpin:<path> takes a pin away (to tidy up after real-mouse tests).
                FavoritesStore.shared.remove(URL(fileURLWithPath: argument))
            case "watchframes":
                // Logs every visible row's center in screen coordinates (top-left origin, as
                // CGEvent uses) twice a second, for an outside tool driving the real mouse.
                let until = Date().addingTimeInterval(Double(argument) ?? 30)
                while Date() < until {
                    if let window = InputDriver.window, let primary = NSScreen.screens.first {
                        // Lists drawn by AppKit (the file list, tabs, sidebar) say where their
                        // rows are when asked; the old frames of rows gone since are dropped.
                        RowGeometry.frames = [:]
                        _ = RowGeometry.frame(named: "")
                        let rows = RowGeometry.frames.map { url, frame -> String in
                            let x = window.frame.minX + frame.midX
                            let y = primary.frame.height - (window.frame.maxY - frame.midY)
                            return "\(url.lastPathComponent)=\(Int(x)),\(Int(y))"
                        }
                        log("frames " + rows.sorted().joined(separator: ";") + " selected=" + workspace.selected.selection.map(\.lastPathComponent).sorted().joined(separator: ","))
                        log("state tabs=" + workspace.tabs.map { $0.currentURL.lastPathComponent }.joined(separator: ",")
                            + " current=\(workspace.tabs.firstIndex { $0 === workspace.currentTab } ?? -1)"
                            + " url=\(workspace.selected.currentURL.lastPathComponent)"
                            + " sheet=\(window.attachedSheet != nil) key=\(window.isKeyWindow)"
                            + " window=\(Int(window.frame.minX)),\(Int(primary.frame.height - window.frame.maxY))"
                            + " pins=" + FavoritesStore.shared.favorites.map { ($0.path as NSString).lastPathComponent }.joined(separator: ","))
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
                for transfer in Transfers.shared.transfers {
                    log("transfer \(transfer.kind) \(transfer.title): \(transfer.state) \(transfer.doneItems)/\(transfer.totalItems) items \(transfer.doneBytes)/\(transfer.totalBytes) bytes" + (transfer.folder.map { " in \($0.path) placed=\(transfer.placed.map(\.lastPathComponent))" } ?? ""))
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
                // What Move to Trash, Rename… and New Folder… do once confirmed. "drive:<id>"
                // names a Drive item.
                model.trash([Self.debugURL(parts.count > 1 ? parts[1] : "")])
            case "rename":
                let ends = argument.components(separatedBy: ">")
                if ends[0].hasPrefix("drive:") {
                    let url = Self.debugURL(ends[0])
                    if let row = model.drive.rows.first(where: { DriveLocation(url: $0.id)?.id == DriveLocation(url: url)?.id }) {
                        model.rename(row.item, to: ends[1])
                    }
                } else if let item = FileItem(url: URL(fileURLWithPath: ends[0])) {
                    model.rename(item, to: ends[1])
                }
            case "showdownload":
                // What a finished download's Show button does.
                if let transfer = Transfers.shared.transfers.first(where: { $0.folder != nil && !$0.placed.isEmpty }), let folder = transfer.folder {
                    model.navigate(to: folder, selecting: transfer.placed)
                }
            case "beginrename":
                // What Rename… (⇧⌘↩) does: shows the name prompt for the selected item.
                model.beginRename()
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
            case "settings", "actionruns", "actioneditor", "connectioneditor", "googleclient", "transferlist":
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
                case "googleclient": AnyView(GoogleClientEditor {})
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
            log("\(scene) -> tabs=\(workspace.tabs.count) panes=\(workspace.secondPane(of: workspace.currentTab).map { "\(workspace.currentTab.currentURL.lastPathComponent)|\($0.currentURL.lastPathComponent) active=\(workspace.selected === $0 ? 2 : 1)" } ?? "1") view=\(shown.destination) search=\"\(shown.searchText)\" expanded=\(shown.expanded.map(\.lastPathComponent).sorted()) firstResponder=\(InputDriver.window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil") key=\(InputDriver.window?.isKeyWindow ?? false) active=\(NSApp.isActive) url=\(shown.currentURL.path) items=[\(names)] selected=[\(selected)] error=\(shown.loadError ?? "none") preview=\(shown.previewURL?.lastPathComponent ?? "nil")/\(shown.previewItems.count) big=\(shown.expandedPreview?.lastPathComponent ?? "nil") s3=\(shown.destination == .s3 ? (shown.s3.location?.uri ?? "?") + " rows=\(shown.s3.rows.map(\.item.name))" + (shown.s3.error.map { " error=\($0)" } ?? "") : "-") drive=\(shown.destination == .drive ? "\(shown.drive.trail.map(\.name).joined(separator: " / "))" + (shown.drive.isSearching ? " search=\(shown.drive.query)" : "") + " rows=\(shown.drive.rows.map(\.item.name)) selected=\(shown.drive.rows.filter { shown.drive.selection.contains($0.id) }.map(\.item.name))" + (shown.drive.error.map { " error=\($0)" } ?? "") : "-") windows=\(NSApp.windows.filter { $0.isVisible && $0.canBecomeMain }.map(\.title)) git=\(gitSummary(shown)) undoMenu=\(undoMenuTitles()) history=\(FileHistory.shared.undoStack.map(\.name))/\(FileHistory.shared.redoStack.map(\.name))")
            if env["EXPLORER_NO_CAPTURE"] == nil { capture(to: "\(dir)/\(index)-\(parts[0]).png") }
        }
        if env["EXPLORER_SNAPSHOT_QUIT"] != nil { NSApp.terminate(nil) }
    }

    /// "people=[owner:test@example.com(you), writer:ada@example.com] access=anyone/reader canShare=true error=…"
    private static func sharingSummary(_ sharing: DriveSharing) -> String {
        let people = sharing.people.map { p in
            "\(p.role.rawValue):\(p.email ?? p.title)\(sharing.isYou(p) ? "(you)" : "")\(p.inherited ? "(inherited)" : "")"
        }
        let access: String = switch sharing.access {
        case .restricted: "restricted"
        case .anyone(let role): "anyone/\(role.rawValue)"
        case .domain(let name, let role): "domain:\(name)/\(role.rawValue)"
        }
        return "people=[\(people.joined(separator: ", "))] access=\(access)\(sharing.accessIsInherited ? "(inherited)" : "") canShare=\(sharing.canShare) error=\(sharing.error ?? "none")"
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
        case .drive: return !model.drive.rows.isEmpty || model.drive.error != nil
        }
    }

    /// A file path, "s3:bucket/key" for an item in the first S3 connection, or "drive:<id>"
    /// for one in the first Google account ("drive:<id>/" for a folder).
    private static func debugURL(_ text: String) -> URL {
        if text.hasPrefix("drive:"), let account = DriveStore.shared.accounts.first {
            let path = String(text.dropFirst(6))
            let isFolder = path.hasSuffix("/")
            let id = isFolder ? String(path.dropLast()) : path
            let location = DriveLocation(accountID: account.id, id: id, name: "")
            let name = DriveStore.shared.file(location)?.name ?? (id == DriveLocation.myDriveID ? "My Drive" : id == DriveLocation.homeID ? account.email : id)
            return DriveLocation.url(accountID: account.id, id: id, name: name, isFolder: isFolder)
        }
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
        guard let window = NSApp.orderedWindows.first(where: { $0.isVisible && $0.contentView != nil }) else { return }
        // EXPLORER_CAPTURE_VIEW=1 has the window draw itself instead: the window server gives
        // back blank images while the displays sleep.
        if ProcessInfo.processInfo.environment["EXPLORER_CAPTURE_VIEW"] != nil, let view = window.contentView,
           let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            return
        }
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return }
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
