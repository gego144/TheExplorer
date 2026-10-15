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
@MainActor
enum DebugSnapshots {
    private static var hasRun = false

    static func runIfRequested(workspace: Workspace) async {
        let env = ProcessInfo.processInfo.environment
        guard !hasRun, let dir = env["EXPLORER_SNAPSHOT_DIR"], let scenes = env["EXPLORER_SCENES"] else { return }
        hasRun = true
        // Scripted runs usually launch hidden (open -g -j); keep App Nap from throttling them.
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated], reason: "Debug scenes")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? await Task.sleep(for: .seconds(1.5))

        for (index, scene) in scenes.split(separator: ";").enumerated() {
            let model = workspace.selected
            let parts = scene.split(separator: ":", maxSplits: 1).map(String.init)
            let argument = parts.count > 1 ? (parts[1] as NSString).expandingTildeInPath : ""
            var wait = 2.5
            switch parts[0] {
            case "folder": model.navigate(to: URL(fileURLWithPath: argument))
            case "select": model.selection = [URL(fileURLWithPath: argument).standardizedFileURL]
            case "recents": model.show(.recents)
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
                // drop:<source>><destination folder>, the same path a real drop takes.
                let ends = argument.components(separatedBy: ">").map { ($0 as NSString).expandingTildeInPath }
                model.receiveDrop([URL(fileURLWithPath: ends[0])], into: URL(fileURLWithPath: ends[1]))
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
            default: break
            }
            try? await Task.sleep(for: .seconds(wait))
            let shown = workspace.selected
            let names = shown.rows.map { "\($0.name)@\(RelativeTime.short($0.item.modified))" }.joined(separator: ",")
            let selected = shown.selection.map(\.lastPathComponent).sorted().joined(separator: ",")
            log("\(scene) -> tabs=\(workspace.tabs.count) url=\(shown.currentURL.path) items=[\(names)] selected=[\(selected)] error=\(shown.loadError ?? "none") windows=\(NSApp.windows.filter { $0.isVisible && $0.canBecomeMain }.map(\.title))")
            if env["EXPLORER_NO_CAPTURE"] == nil { capture(to: "\(dir)/\(index)-\(parts[0]).png") }
        }
        if env["EXPLORER_SNAPSHOT_QUIT"] != nil { NSApp.terminate(nil) }
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data(("[snapshot] " + message + "\n").utf8))
    }

    private typealias WindowImageFn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    /// Uses the window server so glass, toolbars and tables render as they appear on screen.
    /// CGWindowListCreateImage is obsoleted in the macOS 15 SDK, so it's looked up at runtime;
    /// capturing your own windows needs no Screen Recording permission.
    private static func capture(to path: String) {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return }
        let create = unsafeBitCast(symbol, to: WindowImageFn.self)
        // kCGWindowListOptionIncludingWindow = 8, kCGWindowImageBoundsIgnoreFraming = 1
        guard let image = create(.null, 8, UInt32(window.windowNumber), 1)?.takeRetainedValue() else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
#endif
