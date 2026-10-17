import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

extension Notification.Name {
    /// Posted with an S3Location after uploads, deletes or new folders change what's there.
    static let s3Changed = Notification.Name("TheExplorerS3Changed")
}

/// One tab's view of S3: the buckets of a connection, or a folder (prefix) inside a bucket,
/// listed a page at a time.
@MainActor
@Observable
final class S3Browser {
    private(set) var location: S3Location?
    private(set) var rows: [ListRow] = []
    private(set) var isLoading = false
    private(set) var error: String?
    /// More objects than are loaded; scrolling to the end loads the next page.
    private(set) var hasMore = false
    var selection: Set<URL> = []
    var sort = SortSpec(key: .name, ascending: true) { didSet { rebuild() } }

    @ObservationIgnored private var buckets: [S3Bucket] = []
    @ObservationIgnored private var listing = S3Listing()
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: .s3Changed, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let changed = note.object as? S3Location, let location = self.location,
                      changed.connectionID == location.connectionID, changed.bucket == location.bucket,
                      changed.prefix == location.prefix || changed.prefix.hasPrefix(location.prefix) else { return }
                self.reload(keepSelection: true)
            }
        }
    }

    var connection: S3Connection? { location.flatMap { S3Store.shared.connection($0.connectionID) } }
    var client: S3Client? { location.flatMap { S3Store.shared.client(for: $0.connectionID) } }

    /// Folder and file counts for the status bar.
    var counts: (folders: Int, files: Int) {
        let folders = rows.filter(\.item.isFolder).count
        return (folders, rows.count - folders)
    }

    func show(_ location: S3Location) {
        guard location != self.location || error != nil else { return }
        self.location = location
        selection = []
        rows = []
        reload()
    }

    func reload(keepSelection: Bool = false) {
        guard let location, let client else {
            error = "This connection was removed."
            return
        }
        loadTask?.cancel()
        isLoading = true
        error = nil
        let previous = selection
        loadTask = Task {
            do {
                if let bucket = location.bucket {
                    let page = try await client.list(bucket: bucket, prefix: location.prefix)
                    guard !Task.isCancelled, location == self.location else { return }
                    listing = page
                } else {
                    let buckets = try await client.listBuckets()
                    guard !Task.isCancelled, location == self.location else { return }
                    self.buckets = buckets
                    listing = S3Listing()
                }
                rebuild()
                selection = keepSelection ? previous.intersection(rows.map(\.id)) : []
            } catch is CancellationError {
                return
            } catch {
                guard location == self.location else { return }
                rows = []
                self.error = error.localizedDescription
            }
            isLoading = false
        }
    }

    /// Loads the next 1,000 objects.
    func loadMore() {
        guard hasMore, !isLoading, let location, let bucket = location.bucket, let client, let token = listing.nextToken else { return }
        isLoading = true
        loadTask = Task {
            defer { isLoading = false }
            guard let page = try? await client.list(bucket: bucket, prefix: location.prefix, token: token),
                  location == self.location else { return }
            listing.prefixes += page.prefixes
            listing.objects += page.objects
            listing.nextToken = page.nextToken
            rebuild()
        }
    }

    private func rebuild() {
        guard let location else { return }
        var rows: [ListRow] = []
        if let bucket = location.bucket {
            for prefix in listing.prefixes {
                let name = String(prefix.dropLast().split(separator: "/").last ?? "")
                let item = FileItem(url: S3Location.url(connectionID: location.connectionID, bucket: bucket, key: prefix),
                                    name: name, isDirectory: true, contentType: .folder)
                rows.append(ListRow(item: item))
            }
            // The empty object a console creates to mark the folder itself isn't a file in it.
            for object in listing.objects where object.key != location.prefix {
                let name = String(object.key.dropFirst(location.prefix.count))
                let item = FileItem(url: S3Location.url(connectionID: location.connectionID, bucket: bucket, key: object.key),
                                    name: name, isDirectory: false, isHidden: name.hasPrefix("."), fileSize: object.size,
                                    modified: object.modified, contentType: UTType(filenameExtension: (name as NSString).pathExtension))
                rows.append(ListRow(item: item, size: object.size, date: object.modified))
            }
        } else {
            for bucket in buckets {
                let item = FileItem(url: S3Location.url(connectionID: location.connectionID, bucket: bucket.name, key: ""),
                                    name: bucket.name, isDirectory: true, created: bucket.created, modified: bucket.created,
                                    contentType: .folder)
                rows.append(ListRow(item: item, date: bucket.created))
            }
        }
        self.rows = RowSorter.sorted(rows, by: sort, foldersFirst: true)
        hasMore = listing.nextToken != nil
    }

    // MARK: Actions on the listing

    func createFolder(named name: String) {
        guard let location, let bucket = location.bucket, let client else { return }
        let key = location.prefix + name.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) + "/"
        Task {
            do {
                try await client.createFolder(bucket: bucket, key: key)
                NotificationCenter.default.post(name: .s3Changed, object: location)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Deletes objects, and everything under folders.
    func delete(_ urls: Set<URL>) {
        guard let location, let bucket = location.bucket, let client else { return }
        let keys = urls.compactMap { S3Location(url: $0)?.prefix }
        Task {
            do {
                var all: [String] = []
                for key in keys {
                    if key.hasSuffix("/") {
                        all += try await client.listAll(bucket: bucket, prefix: key).map(\.key)
                        all.append(key)
                    } else {
                        all.append(key)
                    }
                }
                try await client.delete(bucket: bucket, keys: Array(Set(all)))
                NotificationCenter.default.post(name: .s3Changed, object: location)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Copies a link anyone can download from for 7 days.
    func copyShareLink(_ url: URL) {
        guard let target = S3Location(url: url), let bucket = target.bucket, let client else { return }
        Task {
            do {
                let link = try await client.shareURL(bucket: bucket, key: target.prefix)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link.absoluteString, forType: .string)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func dismissError() { error = nil }
}

// MARK: - Transfers

/// Uploads to and downloads from S3 and Google Drive, with progress for the status bar.
@MainActor
@Observable
final class Transfers {
    static let shared = Transfers()

    struct Transfer: Identifiable {
        enum Kind { case upload, download }
        enum State: Equatable {
            case running, done, cancelled
            case failed(String)
        }

        let id = UUID()
        let kind: Kind
        /// "3 items to my-bucket/videos"
        let title: String
        var totalBytes: Int64 = 0
        var doneBytes: Int64 = 0
        var totalItems = 0
        var doneItems = 0
        var current: String?
        var state = State.running
        let started = Date()
        var finished: Date?

        var fraction: Double { totalBytes > 0 ? min(1, Double(doneBytes) / Double(totalBytes)) : 0 }
    }

    private(set) var transfers: [Transfer] = []
    @ObservationIgnored var tasks: [UUID: Task<Void, Never>] = [:]

    var activeCount: Int { transfers.filter { $0.state == .running }.count }

    func cancel(_ id: UUID) { tasks[id]?.cancel() }

    func clearFinished() { transfers.removeAll { $0.state != .running } }

    /// Uploads files and folders (with everything in them) into `location`.
    func upload(_ urls: [URL], to target: S3Location) {
        // Uploads go inside the folder: "videos" means "videos/".
        var location = target
        if !location.prefix.isEmpty && !location.prefix.hasSuffix("/") { location.prefix += "/" }
        guard let bucket = location.bucket, let client = S3Store.shared.client(for: location.connectionID) else { return }
        let sources = urls.filter(\.isFileURL)
        guard !sources.isEmpty else { return }
        let destination = bucket + "/" + location.prefix
        let id = start(.upload, title: "\(Self.noun(sources)) to \(destination)")
        tasks[id] = Task {
            // Every file with the key it goes to, folders walked off the main thread.
            let files = await Task.detached { Self.expand(sources, under: location.prefix) }.value
            update(id) {
                $0.totalItems = files.count
                $0.totalBytes = files.reduce(0) { $0 + $1.size }
            }
            var finishedBytes: Int64 = 0
            do {
                for file in files {
                    try Task.checkCancellation()
                    update(id) { $0.current = file.url.lastPathComponent }
                    let base = finishedBytes
                    try await client.upload(file: file.url, bucket: bucket, key: file.key) { sent in
                        Task { @MainActor in self.update(id) { $0.doneBytes = base + sent } }
                    }
                    finishedBytes += file.size
                    update(id) {
                        $0.doneItems += 1
                        $0.doneBytes = finishedBytes
                    }
                }
                finish(id, .done)
            } catch {
                finish(id, Self.state(for: error))
            }
            NotificationCenter.default.post(name: .s3Changed, object: location)
        }
    }

    /// Downloads objects and folders (keeping their structure) into a local folder.
    /// `completion` gets the top-level items that landed there; `failed` hears about errors,
    /// including a stop or a connection that's gone.
    func download(_ urls: [URL], into folder: URL, completion: (([URL]) -> Void)? = nil, failed: ((Error) -> Void)? = nil) {
        let targets = urls.compactMap(S3Location.init(url:)).filter { $0.bucket != nil }
        guard let first = targets.first, let client = S3Store.shared.client(for: first.connectionID), let bucket = first.bucket else {
            failed?(CocoaError(.fileReadNoSuchFile))
            return
        }
        let id = start(.download, title: Self.downloadTitle(urls, into: folder))
        tasks[id] = Task {
            do {
                // Each object with where it goes; folder names are made unique once, up front.
                var plan: [(key: String, size: Int64, destination: URL)] = []
                var placed: [URL] = []
                for target in targets {
                    let key = target.prefix
                    if key.isEmpty || key.hasSuffix("/") {
                        let top = FileTransfer.uniqueDestination(for: target.name, in: folder)
                        placed.append(top)
                        try FileManager.default.createDirectory(at: top, withIntermediateDirectories: true)
                        for object in try await client.listAll(bucket: bucket, prefix: key) where !object.key.hasSuffix("/") {
                            let relative = String(object.key.dropFirst(key.count))
                            plan.append((object.key, object.size, Self.safeDestination(relative, in: top)))
                        }
                    } else {
                        let destination = FileTransfer.uniqueDestination(for: (key as NSString).lastPathComponent, in: folder)
                        placed.append(destination)
                        plan.append((key, -1, destination))
                    }
                }
                update(id) {
                    $0.totalItems = plan.count
                    $0.totalBytes = plan.reduce(0) { $0 + max(0, $1.size) }
                }
                var finishedBytes: Int64 = 0
                for item in plan {
                    try Task.checkCancellation()
                    update(id) { $0.current = item.destination.lastPathComponent }
                    let base = finishedBytes
                    try await client.download(bucket: bucket, key: item.key, to: item.destination) { written, expected in
                        Task { @MainActor in
                            self.update(id) { transfer in
                                // Single files only learn their size once the download starts.
                                if item.size < 0, expected > 0, transfer.totalBytes < base + expected { transfer.totalBytes = base + expected }
                                transfer.doneBytes = base + written
                            }
                        }
                    }
                    finishedBytes = transfers.first { $0.id == id }?.doneBytes ?? finishedBytes
                    update(id) { $0.doneItems += 1 }
                }
                finish(id, .done)
                completion?(placed)
            } catch {
                finish(id, Self.state(for: error))
                failed?(error)
            }
        }
    }

    /// Downloads one object to a cache folder (once) and hands back the local file, for
    /// opening and Quick Look.
    func fetchForViewing(_ url: URL, then use: @escaping (URL) -> Void) {
        guard let target = S3Location(url: url), let bucket = target.bucket else { return }
        let cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("TheExplorer S3", isDirectory: true)
            .appendingPathComponent(String(UInt64(bitPattern: Int64(url.absoluteString.hashValue)), radix: 36), isDirectory: true)
        let local = cache.appendingPathComponent((target.prefix as NSString).lastPathComponent)
        if FileManager.default.fileExists(atPath: local.path) {
            use(local)
            return
        }
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        download([S3Location.url(connectionID: target.connectionID, bucket: bucket, key: target.prefix)], into: cache) { placed in
            if let file = placed.first { use(file) }
        }
    }

    func start(_ kind: Transfer.Kind, title: String) -> UUID {
        let transfer = Transfer(kind: kind, title: title)
        transfers.insert(transfer, at: 0)
        if transfers.count > 20 { transfers.removeLast(transfers.count - 20) }
        return transfer.id
    }

    func update(_ id: UUID, _ change: (inout Transfer) -> Void) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        change(&transfers[index])
    }

    func finish(_ id: UUID, _ state: Transfer.State) {
        tasks[id] = nil
        update(id) {
            $0.state = state
            $0.current = nil
            $0.finished = Date()
        }
    }

    static func state(for error: Error) -> Transfer.State {
        error is CancellationError || (error as? URLError)?.code == .cancelled ? .cancelled : .failed(error.localizedDescription)
    }

    /// "“clip.mov” to “Downloads”", or "“clip.mov” for viewing" for the cache Quick Look uses.
    static func downloadTitle(_ urls: [URL], into folder: URL) -> String {
        let cache = FileManager.default.temporaryDirectory.standardizedFileURL.path
        return noun(urls) + (folder.standardizedFileURL.path.hasPrefix(cache) ? " for viewing" : " to “\(folder.lastPathComponent)”")
    }

    static func noun(_ urls: [URL]) -> String {
        urls.count == 1 ? "“\(S3Location(url: urls[0])?.itemName.nilIfEmpty ?? DriveLocation(url: urls[0])?.name ?? urls[0].lastPathComponent)”" : "\(urls.count) items"
    }

    /// A key from the archive-style relative path, kept inside `folder` (no "..").
    nonisolated static func safeDestination(_ relative: String, in folder: URL) -> URL {
        relative.split(separator: "/").filter { $0 != ".." && $0 != "." }
            .reduce(folder) { $0.appendingPathComponent(String($1)) }
    }

    /// Files to upload with their keys: folders become their whole tree under the prefix.
    nonisolated static func expand(_ urls: [URL], under prefix: String) -> [(url: URL, key: String, size: Int64)] {
        var files: [(URL, String, Int64)] = []
        for url in urls {
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]))
                .map { ($0.isDirectory ?? false) } ?? false
            guard isFolder else {
                let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                files.append((url, prefix + url.lastPathComponent, size))
                continue
            }
            let base = url.standardizedFileURL.path
            let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
            while let file = enumerator?.nextObject() as? URL {
                guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true,
                      file.lastPathComponent != ".DS_Store" else { continue }
                let relative = String(file.standardizedFileURL.path.dropFirst(base.count + 1))
                files.append((file, prefix + url.lastPathComponent + "/" + relative, Int64(values.fileSize ?? 0)))
            }
        }
        return files
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
