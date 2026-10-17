import Foundation

/// Items that live in S3 or Google Drive rather than on disk: downloading them, and fetching
/// one to open or preview, whichever service it's from.
@MainActor
enum RemoteFiles {
    nonisolated static func isRemote(_ url: URL) -> Bool {
        url.scheme == S3Location.scheme || url.scheme == DriveLocation.scheme
    }

    /// Downloads items into a local folder. `completion` gets the top-level items that landed
    /// there (once per service, for a mixed list); `failed` hears about errors.
    static func download(_ urls: [URL], into folder: URL, completion: (([URL]) -> Void)? = nil, failed: ((Error) -> Void)? = nil) {
        let s3 = urls.filter { $0.scheme == S3Location.scheme }
        let drive = urls.filter { $0.scheme == DriveLocation.scheme }
        if !s3.isEmpty { Transfers.shared.download(s3, into: folder, completion: completion, failed: failed) }
        if !drive.isEmpty { Transfers.shared.download(drive: drive, into: folder, completion: completion, failed: failed) }
        if s3.isEmpty && drive.isEmpty { failed?(CocoaError(.fileReadNoSuchFile)) }
    }

    /// A local copy of a remote file, downloaded once to a cache, for opening and Quick Look.
    static func fetchForViewing(_ url: URL, then use: @escaping (URL) -> Void) {
        if url.scheme == DriveLocation.scheme {
            Transfers.shared.fetchForViewing(drive: url, then: use)
        } else if url.scheme == S3Location.scheme {
            Transfers.shared.fetchForViewing(url, then: use)
        }
    }
}
