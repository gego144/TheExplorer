import Foundation
import UniformTypeIdentifiers

/// Thin wrapper over NSMetadataQuery that hands back results on the main thread.
@MainActor
final class SpotlightQuery {
    private let query = NSMetadataQuery()
    private var observers: [NSObjectProtocol] = []

    /// Called with the current results and whether the initial gather is still running.
    var onUpdate: (([NSMetadataItem], _ stillGathering: Bool) -> Void)?

    init() {
        query.notificationBatchingInterval = 0.5
        let center = NotificationCenter.default
        let names: [Notification.Name] = [.NSMetadataQueryGatheringProgress, .NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate]
        for name in names {
            observers.append(center.addObserver(forName: name, object: query, queue: .main) { [weak self] note in
                MainActor.assumeIsolated { self?.deliver(finished: note.name != .NSMetadataQueryGatheringProgress) }
            })
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func start(predicate: NSPredicate, scopes: [Any], sortedBy sortKey: String? = nil, ascending: Bool = false) {
        query.stop()
        query.predicate = predicate
        query.searchScopes = scopes
        query.sortDescriptors = sortKey.map { [NSSortDescriptor(key: $0, ascending: ascending)] } ?? []
        query.start()
    }

    func stop() {
        query.stop()
    }

    private func deliver(finished: Bool) {
        query.disableUpdates()
        defer { query.enableUpdates() }
        let items = (0..<query.resultCount).compactMap { query.result(at: $0) as? NSMetadataItem }
        onUpdate?(items, !finished && query.isGathering)
    }
}

extension FileItem {
    static let addedDateAttribute = "kMDItemDateAdded"

    /// Builds an item from Spotlight metadata without touching the filesystem.
    init?(metadata item: NSMetadataItem) {
        guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { return nil }
        let type = (item.value(forAttribute: NSMetadataItemContentTypeKey) as? String).flatMap { UTType($0) }
        let isPackage = type?.conforms(to: .package) ?? false
        let isFolder = type.map { $0.conforms(to: .folder) || $0.conforms(to: .volume) } ?? false
        let size = (item.value(forAttribute: NSMetadataItemFSSizeKey) as? NSNumber)?.int64Value
        self.init(
            url: URL(fileURLWithPath: path),
            name: item.value(forAttribute: NSMetadataItemFSNameKey) as? String ?? (path as NSString).lastPathComponent,
            isDirectory: isFolder || isPackage,
            isPackage: isPackage,
            isHidden: false,
            fileSize: isFolder ? nil : size,
            created: item.value(forAttribute: NSMetadataItemFSCreationDateKey) as? Date,
            modified: item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date,
            contentType: type
        )
    }
}
