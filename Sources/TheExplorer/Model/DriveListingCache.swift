import Foundation

/// Drive folders listed recently, so going back to one (or into one you pointed at) shows it at
/// once while it's listed again. Without it every folder waited on a round trip to Google
/// with an empty list, even one left a moment ago. The local equivalent is ListingCache.
@MainActor
final class DriveListingCache {
    static let shared = DriveListingCache()

    struct Entry {
        var files: [DriveFile]
        var drives: [SharedDrive]
        var nextToken: String?
        /// When it was listed (system uptime).
        var listed: TimeInterval
    }

    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private var readAhead: Task<Void, Never>?
    private var observer: NSObjectProtocol?
    static let limit = 40

    private init() {
        // Something changed in a folder (made, renamed, moved, trashed): its listing is stale.
        observer = NotificationCenter.default.addObserver(forName: .driveChanged, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let location = note.object as? DriveLocation else { return }
                self?.remove(Self.key(location))
            }
        }
    }

    private static func key(_ location: DriveLocation) -> String { location.accountID.uuidString + "/" + location.id }

    func entry(for location: DriveLocation) -> Entry? { entries[Self.key(location)] }

    func store(_ location: DriveLocation, files: [DriveFile], drives: [SharedDrive], nextToken: String?) {
        let key = Self.key(location)
        entries[key] = Entry(files: files, drives: drives, nextToken: nextToken, listed: ProcessInfo.processInfo.systemUptime)
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > Self.limit { entries[order.removeFirst()] = nil }
    }

    private func remove(_ key: String) {
        entries[key] = nil
        order.removeAll { $0 == key }
    }

    /// The first page of a Drive place: a folder's contents, Shared with me, Starred, or the
    /// account's shared drives.
    nonisolated static func firstPage(of location: DriveLocation, client: DriveClient) async throws -> (DriveListing, [SharedDrive]) {
        switch location.id {
        case DriveLocation.homeID, DriveLocation.drivesID: return (DriveListing(), try await client.allDrives())
        case DriveLocation.sharedID: return (try await client.sharedWithMe(), [])
        case DriveLocation.starredID: return (try await client.starred(), [])
        default: return (try await client.list(in: location.id), [])
        }
    }

    /// Lists a Drive folder you're likely to open next (pointed at or selected), in the
    /// background, unless it was listed in the last half minute.
    func readAhead(_ url: URL) {
        guard let location = DriveLocation(url: url), location.isFolder,
              let client = DriveStore.shared.client(for: location.accountID) else { return }
        readAhead?.cancel()
        readAhead = Task { [weak self] in
            // The pointer passing over on its way somewhere else doesn't count.
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self else { return }
            if let entry = self.entry(for: location), ProcessInfo.processInfo.systemUptime - entry.listed < 30 { return }
            guard let (page, drives) = try? await Self.firstPage(of: location, client: client), !Task.isCancelled else { return }
            DriveStore.shared.remember(page.files, in: location, accountID: location.accountID)
            self.store(location, files: page.files, drives: drives, nextToken: page.nextToken)
        }
    }
}
