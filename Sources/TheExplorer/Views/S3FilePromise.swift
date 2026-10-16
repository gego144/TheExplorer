import AppKit
import UniformTypeIdentifiers

/// An S3 object or folder on a drag, as a file promise: Finder, the Desktop and other apps
/// accept it, tell us where they want it, and it's downloaded straight there (with progress
/// and Stop in the status bar, like any download). The `x-s3` URL rides along too, so drops
/// inside TheExplorer keep working as before.
final class S3FilePromise: NSFilePromiseProvider {
    let s3URL: URL

    /// Promises waiting to be kept. A drop's pasteboard lets go of its writers once the drag
    /// ends, which can be before the download is done.
    @MainActor private static var pending: Set<S3FilePromise> = []
    private let keeper = Keeper()

    init?(_ url: URL) {
        guard let location = S3Location(url: url), location.bucket != nil else { return nil }
        s3URL = url
        super.init()
        let isFolder = location.prefix.isEmpty || location.prefix.hasSuffix("/")
        fileType = isFolder ? UTType.folder.identifier : (UTType(filenameExtension: url.pathExtension) ?? .data).identifier
        keeper.name = location.itemName
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
        if type == .URL { return (s3URL as NSURL).pasteboardPropertyList(forType: .URL) }
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
            guard let url, let promise = provider as? S3FilePromise else {
                completionHandler(CocoaError(.fileWriteUnknown))
                return
            }
            // Called on the main queue (see operationQueue(for:)).
            MainActor.assumeIsolated {
                S3FilePromise.pending.insert(promise)
                // Downloaded into the folder it was dropped in, under a new name if one's taken.
                S3Transfers.shared.download([url], into: destination.deletingLastPathComponent()) { _ in
                    S3FilePromise.pending.remove(promise)
                    completionHandler(nil)
                } failed: { error in
                    S3FilePromise.pending.remove(promise)
                    completionHandler(error)
                }
            }
        }
    }
}
