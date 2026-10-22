import Foundation
import QuartzCore
import UniformTypeIdentifiers

/// NSMetadataQuery run on a private serial queue, so result sets of hundreds of thousands of
/// items never touch the main thread.
///
/// Reading attributes item by item is slow (each read is a round trip to the Spotlight server),
/// but attributes the query sorts by or lists as value-list attributes arrive in bulk and cost
/// nothing to read. Everything is fetched that way except the path, which Spotlight resolves per
/// item (~16µs), so consumers should only ask for the paths of results they keep.
final class SpotlightQuery: @unchecked Sendable {
    /// Runs on the query's queue whenever results change. `results` is only valid during the call.
    typealias Handler = @Sendable (_ results: Results, _ gathering: Bool) -> Void

    static let prefetched = [
        NSMetadataItemFSNameKey, NSMetadataItemContentTypeKey, NSMetadataItemFSSizeKey,
        NSMetadataItemFSCreationDateKey, NSMetadataItemFSContentChangeDateKey, FileItem.addedDateAttribute,
    ]

    private let query = NSMetadataQuery()
    private let queue = OperationQueue()
    private var handler: Handler?
    private var observers: [NSObjectProtocol] = []
    private let cache = Cache()
    private var lastDelivery: CFTimeInterval = 0
    private var deferredDelivery = false
    private var isPaused = false
    /// Results (or a new handler) came in while paused.
    private var missedDelivery = false

    /// Once gathering is done, live updates (files changing anywhere in scope, often thousands
    /// a second in dependency folders) are coalesced to at most one handler run per interval.
    private static let liveUpdateInterval: CFTimeInterval = 1.5

    init(predicate: NSPredicate, scopes: [Any], sortedBy sortKey: String? = nil, ascending: Bool = false) {
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        query.operationQueue = queue
        query.notificationBatchingInterval = 0.3
        query.predicate = predicate
        query.searchScopes = scopes
        if let sortKey {
            query.sortDescriptors = [NSSortDescriptor(key: sortKey, ascending: ascending)]
        }
        query.valueListAttributes = Self.prefetched.filter { $0 != sortKey }
    }

    /// Starts gathering; `handler` runs on a background queue with each batch of changes.
    func start(_ handler: @escaping Handler) {
        let names: [Notification.Name] = [.NSMetadataQueryGatheringProgress, .NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate]
        for name in names {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: query, queue: queue) { [weak self] note in
                self?.resultsChanged(finished: note.name == .NSMetadataQueryDidFinishGathering)
            })
        }
        queue.addOperation { [self] in
            self.handler = handler
            query.start()
        }
    }

    /// Swaps the handler (e.g. after a filter change) and runs it over the current results.
    func setHandler(_ handler: @escaping Handler) {
        // You asked for this (a filter, the next page), so it's not background work.
        queue.qualityOfService = .userInitiated
        queue.addOperation { [self] in
            self.handler = handler
            deliver()
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Holds live updates while nobody's looking (the window is hidden or covered); resuming
    /// delivers what changed meanwhile in one go.
    func setPaused(_ paused: Bool) {
        queue.addOperation { [self] in
            guard paused != isPaused else { return }
            isPaused = paused
            if paused {
                query.disableUpdates()
            } else {
                query.enableUpdates()
                if missedDelivery { deliver() }
            }
        }
    }

    func stop() {
        let observers = observers
        self.observers = []
        queue.addOperation { [self] in
            handler = nil
            query.stop()
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }

    private func resultsChanged(finished: Bool) {
        // Once the first results are in, keeping them current is background work.
        if !query.isGathering && queue.qualityOfService != .utility { queue.qualityOfService = .utility }
        let elapsed = CACurrentMediaTime() - lastDelivery
        // The finished results go out straight away: they're what the list is waiting for.
        if query.isGathering || finished || elapsed >= Self.liveUpdateInterval {
            deliver()
            return
        }
        guard !deferredDelivery else { return }
        deferredDelivery = true
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.liveUpdateInterval - elapsed) { [weak self] in
            self?.queue.addOperation {
                self?.deferredDelivery = false
                self?.deliver()
            }
        }
    }

    private func deliver() {
        guard let handler else { return }
        guard !isPaused else {
            missedDelivery = true
            return
        }
        missedDelivery = false
        query.disableUpdates()
        defer {
            query.enableUpdates()
            lastDelivery = CACurrentMediaTime()
        }
        handler(Results(query: query, cache: cache), query.isGathering)
    }

    /// Per-query memo of resolved paths, clutter checks and parsed types, so walking the same
    /// results again (next page, live update) costs almost nothing. Only touched on the query's queue.
    fileprivate final class Cache {
        final class Entry {
            let path: String
            lazy var isNoisy = PathNoise.isNoisy(path)
            init(path: String) { self.path = path }
        }

        let entries = NSMapTable<NSMetadataItem, Entry>(keyOptions: [.weakMemory, .objectPointerPersonality], valueOptions: .strongMemory)
        var types: [String: UTType] = [:]
        var folderTypes: [String: Bool] = [:]
    }

    /// A read-only view of the current results.
    struct Results {
        fileprivate let query: NSMetadataQuery
        fileprivate let cache: Cache

        var count: Int { query.resultCount }

        /// A prefetched attribute. Free to call for every result.
        func value<T>(_ attribute: String, at index: Int) -> T? {
            query.value(ofAttribute: attribute, forResultAt: index) as? T
        }

        func name(at index: Int) -> String? { value(NSMetadataItemFSNameKey, at: index) }

        func contentType(at index: Int) -> UTType? {
            guard let identifier: String = value(NSMetadataItemContentTypeKey, at: index) else { return nil }
            if let type = cache.types[identifier] { return type }
            let type = UTType(identifier)
            cache.types[identifier] = type
            return type
        }

        /// A browsable folder (not a package). Free to call for every result.
        func isFolder(at index: Int) -> Bool {
            guard let identifier: String = value(NSMetadataItemContentTypeKey, at: index) else { return false }
            if let known = cache.folderTypes[identifier] { return known }
            let isFolder = contentType(at: index).map {
                ($0.conforms(to: .folder) || $0.conforms(to: .volume)) && !$0.conforms(to: .package)
            } ?? false
            cache.folderTypes[identifier] = isFolder
            return isFolder
        }

        /// The one expensive attribute: resolved per item, then memoized.
        func path(at index: Int) -> String? {
            entry(at: index)?.path
        }

        /// Whether the item sits in clutter (Library, dependency folders…). Memoized with the path.
        func isNoisy(at index: Int) -> Bool {
            entry(at: index)?.isNoisy ?? true
        }

        private func entry(at index: Int) -> Cache.Entry? {
            guard let item = query.result(at: index) as? NSMetadataItem else { return nil }
            if let cached = cache.entries.object(forKey: item) { return cached }
            guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { return nil }
            let entry = Cache.Entry(path: path)
            cache.entries.setObject(entry, forKey: item)
            return entry
        }

        func item(at index: Int) -> FileItem? {
            guard let path = path(at: index) else { return nil }
            let type = contentType(at: index)
            let isPackage = type?.conforms(to: .package) ?? false
            let isFolder = type.map { $0.conforms(to: .folder) || $0.conforms(to: .volume) } ?? false
            let size: NSNumber? = value(NSMetadataItemFSSizeKey, at: index)
            return FileItem(
                url: URL(fileURLWithPath: path, isDirectory: isFolder || isPackage),
                name: name(at: index) ?? (path as NSString).lastPathComponent,
                isDirectory: isFolder || isPackage,
                isPackage: isPackage,
                fileSize: isFolder && !isPackage ? nil : size?.int64Value,
                created: value(NSMetadataItemFSCreationDateKey, at: index),
                modified: value(NSMetadataItemFSContentChangeDateKey, at: index),
                contentType: type
            )
        }
    }
}

extension FileItem {
    static let addedDateAttribute = "kMDItemDateAdded"
}
