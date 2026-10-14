#if DEBUG
import AppKit
import SwiftUI

/// Debug-only scripted screenshots of the app's own window. Launch through LaunchServices
/// (running the binary directly can leave the app without a window):
///
///     CONFIG=debug ./scripts/build-app.sh
///     open -n --env EXPLORER_SNAPSHOT_DIR=/tmp/shots --env EXPLORER_SNAPSHOT_QUIT=1 \
///         --env "EXPLORER_SCENES=folder:~/Dev;recents;search:swift;searchmac:swift;storage:~/Dev" \
///         build/TheExplorer.app
@MainActor
enum DebugSnapshots {
    private static var hasRun = false

    static func runIfRequested(model: BrowserModel, openWindow: OpenWindowAction) async {
        let env = ProcessInfo.processInfo.environment
        guard !hasRun, let dir = env["EXPLORER_SNAPSHOT_DIR"], let scenes = env["EXPLORER_SCENES"] else { return }
        hasRun = true
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? await Task.sleep(for: .seconds(1.5))

        for (index, scene) in scenes.split(separator: ";").enumerated() {
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
            case "newtab": Tabs.open(URL(fileURLWithPath: argument), with: openWindow)
            case "plus": NSApp.sendAction(#selector(NSResponder.newWindowForTab(_:)), to: nil, from: nil)
            case "scope": model.searchScope = argument == "mac" ? .mac : .folder
            case "wait": wait = Double(argument) ?? 2
            default: break
            }
            try? await Task.sleep(for: .seconds(wait))
            log("\(scene) -> dest=\(model.destination) url=\(model.currentURL.path) items=\(model.items.count) windows=\(NSApp.windows.filter(\.isVisible).count)")
            capture(to: "\(dir)/\(index)-\(parts[0]).png")
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
