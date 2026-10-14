import Foundation
import Observation

enum SearchScope: Hashable {
    /// Live, exhaustive walk of the current folder (finds hidden and unindexed files too).
    case folder
    /// Spotlight across every indexed volume. Instant, but skips unindexed locations.
    case mac
}

struct SearchHit: Identifiable {
    let item: FileItem
    let rank: Int
    var id: URL { item.url }
}

@MainActor
@Observable
final class SearchModel {
    private(set) var hits: [SearchHit] = []
    private(set) var isRunning = false
    private(set) var scannedCount = 0
    private(set) var truncated = false
    var kindFilter: KindFilter = .all
    var selection: Set<URL> = []

    static let maxResults = 2000
    static let spotlightScanLimit = 25_000

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var spotlight: SpotlightQuery?
    @ObservationIgnored private var currentKey: String?

    var visibleHits: [SearchHit] {
        hits.filter { kindFilter.matches(isFolder: $0.item.isFolder) }
    }

    /// Starts (or restarts) a search, debounced so typing stays smooth.
    func run(text: String, scope: SearchScope, folder: URL, includeHidden: Bool) {
        let terms = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let key = "\(terms)|\(scope)|\(folder.path)|\(includeHidden)"
        guard key != currentKey else { return }
        currentKey = key
        cancel()
        guard !terms.isEmpty else {
            hits = []
            currentKey = nil
            return
        }
        isRunning = true
        task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard let self, !Task.isCancelled else { return }
            switch scope {
            case .mac: self.runSpotlight(terms: terms)
            case .folder: await self.runFolderWalk(terms: terms, folder: folder, includeHidden: includeHidden)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        spotlight?.stop()
        spotlight = nil
        isRunning = false
        scannedCount = 0
        truncated = false
        selection = []
    }

    /// Drops results for items that no longer exist (e.g. after trashing).
    func remove(_ urls: Set<URL>) {
        hits.removeAll { urls.contains($0.id) }
        selection.subtract(urls)
    }

    func clear() {
        cancel()
        hits = []
        currentKey = nil
    }

    // MARK: - Spotlight

    private func runSpotlight(terms: [String]) {
        let predicates = terms.map {
            NSPredicate(format: "%K LIKE[cd] %@", NSMetadataItemFSNameKey, "*\($0)*")
        }
        let query = SpotlightQuery()
        query.onUpdate = { [weak self] items, gathering in
            guard let self else { return }
            var ranked: [SearchHit] = []
            ranked.reserveCapacity(min(items.count, Self.maxResults * 2))
            // Very broad queries can match hundreds of thousands of items; rank a bounded slice.
            for metadata in items.prefix(Self.spotlightScanLimit) {
                guard let item = FileItem(metadata: metadata) else { continue }
                ranked.append(SearchHit(item: item, rank: Self.rank(item, terms: terms)))
            }
            self.scannedCount = items.count
            self.publish(ranked)
            self.truncated = self.truncated || items.count > Self.spotlightScanLimit
            self.isRunning = gathering
        }
        // NSMetadataQuery throws on an AND compound with a single subpredicate.
        let predicate = predicates.count == 1 ? predicates[0] : NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        query.start(predicate: predicate,
                    scopes: [NSMetadataQueryLocalComputerScope])
        spotlight = query
    }

    // MARK: - Folder walk

    private func runFolderWalk(terms: [String], folder: URL, includeHidden: Bool) async {
        let lowered = terms.map { $0.lowercased() }
        let limit = Self.maxResults
        let stream = AsyncStream<([FileItem], Int)> { continuation in
            let walker = Task.detached(priority: .userInitiated) {
                var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
                if !includeHidden { options.insert(.skipsHiddenFiles) }
                guard let enumerator = FileManager.default.enumerator(
                    at: folder, includingPropertiesForKeys: FileItem.resourceKeys, options: options, errorHandler: { _, _ in true }
                ) else {
                    continuation.finish()
                    return
                }
                var batch: [FileItem] = []
                var seen = 0
                var found = 0
                var lastFlush = Date()
                while let url = enumerator.nextObject() as? URL {
                    if Task.isCancelled { break }
                    seen += 1
                    let name = url.lastPathComponent.lowercased()
                    if lowered.allSatisfy(name.contains) {
                        let values = (try? url.resourceValues(forKeys: Set(FileItem.resourceKeys))) ?? URLResourceValues()
                        batch.append(FileItem(url: url, values: values))
                        found += 1
                    }
                    if Date().timeIntervalSince(lastFlush) > 0.15 {
                        continuation.yield((batch, seen))
                        batch = []
                        lastFlush = Date()
                    }
                    if found >= limit { break }
                }
                continuation.yield((batch, seen))
                continuation.finish()
            }
            continuation.onTermination = { _ in walker.cancel() }
        }

        var collected: [SearchHit] = []
        for await (batch, seen) in stream {
            guard !Task.isCancelled else { return }
            collected += batch.map { SearchHit(item: $0, rank: Self.rank($0, terms: terms)) }
            scannedCount = seen
            publish(collected)
        }
        guard !Task.isCancelled else { return }
        isRunning = false
    }

    // MARK: - Ranking

    private func publish(_ ranked: [SearchHit]) {
        let sorted = ranked.sorted { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            return (lhs.item.modified ?? .distantPast) > (rhs.item.modified ?? .distantPast)
        }
        truncated = sorted.count > Self.maxResults
        hits = Array(sorted.prefix(Self.maxResults))
        let present = Set(hits.map(\.id))
        selection.formIntersection(present)
    }

    /// Lower is better: exact name, then prefix, then word start, then anywhere.
    /// Items buried in Library, caches or dependency folders sink to the bottom.
    static func rank(_ item: FileItem, terms: [String]) -> Int {
        let name = item.name.lowercased()
        let stem = (name as NSString).deletingPathExtension
        let first = terms[0].lowercased()
        var rank: Int
        if name == first || stem == first {
            rank = 0
        } else if name.hasPrefix(first) {
            rank = 1
        } else if name.range(of: "[ _\\-.]" + NSRegularExpression.escapedPattern(for: first), options: .regularExpression) != nil {
            rank = 2
        } else {
            rank = 3
        }
        if PathNoise.isNoisy(item.path) { rank += 10 }
        return rank
    }
}

/// Heuristics for paths people rarely mean when they search or browse recents.
enum PathNoise {
    static let noisyComponents: Set<String> = [
        "node_modules", ".git", "DerivedData", ".build", "Pods", "__pycache__", ".venv", "venv",
        ".cache", ".Trash", ".npm", ".gradle", ".next", ".turbo", "Caches", "site-packages",
    ]
    static let packageExtensions: Set<String> = [
        "app", "bundle", "framework", "photoslibrary", "musiclibrary", "xcodeproj", "xcworkspace",
        "xcassets", "plugin", "kext", "appex", "lproj", "playground", "sparsebundle", "pkg",
    ]

    static func isNoisy(_ path: String) -> Bool {
        let homePrefix = URL.home.path + "/"
        if path.hasPrefix(homePrefix + "Library/") { return true }
        let components = path.split(separator: "/").dropLast()
        for component in components {
            if component.hasPrefix(".") || noisyComponents.contains(String(component)) { return true }
            if let dot = component.lastIndex(of: "."),
               packageExtensions.contains(component[component.index(after: dot)...].lowercased()) {
                return true
            }
        }
        return false
    }
}
