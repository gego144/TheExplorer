import Foundation

/// Folders listed lately, shared by every tab and window, so going back to one (Back, Up, a
/// sidebar place, a new tab) shows it on the next frame instead of after it's been read
/// again. Whoever shows one lists it again straight away and changes only what changed since,
/// so a folder that changed while you were elsewhere is put right a few milliseconds later.
///
/// Folders you're about to open are read ahead: the one you point at or select in a list,
/// the sidebar or the path, and the enclosing folder of the one you're in. A double-click's
/// first click selects the folder, so by the second it's usually been read.
@MainActor
final class ListingCache {
    static let shared = ListingCache()

    struct Entry {
        let items: [FileItem]
        let folder: FileItem?
        var volume: VolumeUsage?
        /// When it was listed.
        var listed: TimeInterval
    }

    /// What a read-ahead is for; a newer one of the same kind replaces one not yet started.
    enum Hint {
        /// Pointed at or selected.
        case pointer
        /// Next to where you are (the enclosing folder).
        case nearby
    }

    private var entries: [String: Entry] = [:]
    /// Paths, least recently used first.
    private var order: [String] = []
    private var itemCount = 0

    /// Folders kept, and items across all of them (a few megabytes at most).
    private let maxFolders: Int
    private let maxItems: Int
    /// Bigger folders aren't kept at all.
    private let maxFolderItems: Int

    init(maxFolders: Int = 40, maxItems: Int = 60_000, maxFolderItems: Int = 15_000) {
        self.maxFolders = maxFolders
        self.maxItems = maxItems
        self.maxFolderItems = maxFolderItems
    }

    func entry(for url: URL) -> Entry? {
        #if DEBUG
        if ProcessInfo.processInfo.environment["EXPLORER_NO_LISTCACHE"] != nil { return nil }
        #endif
        let path = url.path
        guard let entry = entries[path] else { return nil }
        touch(path)
        return entry
    }

    func store(_ items: [FileItem], folder: FileItem?, for url: URL) {
        let path = url.path
        guard items.count <= maxFolderItems else { return forget(url) }
        if let old = entries[path] { itemCount -= old.items.count }
        entries[path] = Entry(items: items, folder: folder, volume: entries[path]?.volume, listed: ProcessInfo.processInfo.systemUptime)
        itemCount += items.count
        touch(path)
        while order.count > maxFolders || itemCount > maxItems, let oldest = order.first {
            order.removeFirst()
            if let removed = entries.removeValue(forKey: oldest) { itemCount -= removed.items.count }
        }
    }

    func store(_ volume: VolumeUsage, for url: URL) {
        entries[url.path]?.volume = volume
    }

    func forget(_ url: URL) {
        let path = url.path
        guard let removed = entries.removeValue(forKey: path) else { return }
        itemCount -= removed.items.count
        order.removeAll { $0 == path }
    }

    private var readAheads: [Hint: Task<Void, Never>] = [:]

    /// Reads a folder you're likely to open next, in the background, unless it was read in the
    /// last couple of seconds.
    func readAhead(_ url: URL, _ hint: Hint) {
        guard url.isFileURL else { return }
        readAheads[hint]?.cancel()
        readAheads[hint] = Task { [weak self] in
            // The pointer passing over on its way somewhere else doesn't count.
            try? await Task.sleep(for: .milliseconds(hint == .pointer ? 30 : 150))
            guard !Task.isCancelled, let self else { return }
            let url = url.standardizedFileURL
            if let entry = self.entries[url.path], ProcessInfo.processInfo.systemUptime - entry.listed < 2 { return }
            let read = await Task.detached(priority: .utility) { () -> ([FileItem], FileItem?)? in
                guard let items = try? BrowserModel.listContents(of: url) else { return nil }
                return (items, FileItem(url: url))
            }.value
            guard let (items, folder) = read else { return }
            self.store(items, folder: folder, for: url)
        }
    }

    private func touch(_ path: String) {
        if let index = order.lastIndex(of: path) { order.remove(at: index) }
        order.append(path)
    }
}
