import AppKit
import UniformTypeIdentifiers

/// An S3 or Google Drive item on a drag, as a file promise: Finder, the Desktop and other
/// apps accept it, tell us where they want it, and it's downloaded straight there (with
/// progress and Stop in the status bar, like any download). The item's own URL rides along
/// too, so drops inside TheExplorer keep working as before.
final class RemoteFilePromise: NSFilePromiseProvider {
    let remoteURL: URL

    /// Promises waiting to be kept. A drop's pasteboard lets go of its writers once the drag
    /// ends, which can be before the download is done.
    @MainActor private static var pending: Set<RemoteFilePromise> = []
    private let keeper = Keeper()

    @MainActor
    init?(_ url: URL) {
        let isFolder: Bool
        let name: String
        var type: UTType?
        if let location = S3Location(url: url), location.bucket != nil {
            isFolder = location.prefix.isEmpty || location.prefix.hasSuffix("/")
            name = location.itemName
            type = UTType(filenameExtension: url.pathExtension)
        } else if let location = DriveLocation(url: url), !location.isVirtual {
            let file = DriveStore.shared.file(location)
            isFolder = location.isFolder
            // Google Docs arrive as Office files, so they're promised under that name.
            let export = file.flatMap { $0.isGoogleDoc ? DriveExport.formats(for: $0.contentType).first : nil }
            name = export?.fileName(for: Transfers.localName(location.name)) ?? Transfers.localName(location.name)
            type = UTType(filenameExtension: (name as NSString).pathExtension)
        } else {
            return nil
        }
        remoteURL = url
        super.init()
        fileType = isFolder ? UTType.folder.identifier : (type ?? .data).identifier
        keeper.name = name
        keeper.url = url
        delegate = keeper
    }

    /// The icon for the drag image.
    var icon: NSImage {
        NSWorkspace.shared.icon(for: UTType(fileType) ?? .data)
    }

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + [.URL]
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type == .URL { return (remoteURL as NSURL).pasteboardPropertyList(forType: .URL) }
        return super.pasteboardPropertyList(forType: type)
    }

    /// Keeps the promise. Separate from the provider, since a provider can't be its own delegate
    /// without the two keeping each other alive.
    private final class Keeper: NSObject, NSFilePromiseProviderDelegate {
        var name = ""
        var url: URL?

        func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
            name
        }

        func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue { .main }

        func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo destination: URL,
                                 completionHandler: @escaping (Error?) -> Void) {
            guard let url, let promise = provider as? RemoteFilePromise else {
                completionHandler(CocoaError(.fileWriteUnknown))
                return
            }
            // Called on the main queue (see operationQueue(for:)).
            MainActor.assumeIsolated {
                RemoteFilePromise.pending.insert(promise)
                // Downloaded into the folder it was dropped in, under a new name if one's taken.
                RemoteFiles.download([url], into: destination.deletingLastPathComponent()) { _ in
                    RemoteFilePromise.pending.remove(promise)
                    completionHandler(nil)
                } failed: { error in
                    RemoteFilePromise.pending.remove(promise)
                    completionHandler(error)
                }
            }
        }
    }
}
