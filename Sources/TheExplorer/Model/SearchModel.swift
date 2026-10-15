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

    /// Broad terms can match hundreds of thousands of items, so ranking happens on the query's
    /// background queue: names are free to read, so every match is ranked by name, and only the
    /// best few thousand have their paths resolved.
    private func runSpotlight(terms: [String]) {
        let predicates = terms.map {
            NSPredicate(format: "%K LIKE[cd] %@", NSMetadataItemFSNameKey, "*\($0)*")
        }
        // NSMetadataQuery throws on an AND compound with a single subpredicate.
        let predicate = predicates.count == 1 ? predicates[0] : NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        let query = SpotlightQuery(predicate: predicate, scopes: [NSMetadataQueryLocalComputerScope])
        let lowered = terms.map { $0.lowercased() }
        let limit = Self.maxResults
        query.start { [weak self] results, gathering in
            let count = results.count
            var candidates: [(index: Int, rank: Int, modified: Date)] = []
            candidates.reserveCapacity(count)
            for index in 0..<count {
                let name = results.name(at: index) ?? ""
                let modified: Date = results.value(NSMetadataItemFSContentChangeDateKey, at: index) ?? .distantPast
                candidates.append((index, Self.rank(name: name, terms: lowered), modified))
            }
            candidates.sort { $0.rank != $1.rank ? $0.rank < $1.rank : $0.modified > $1.modified }
            // Resolve twice what's shown, so noisy paths sinking to the bottom still leave a full list.
            let ranked = candidates.prefix(limit * 2).compactMap { candidate -> SearchHit? in
                guard let item = results.item(at: candidate.index) else { return nil }
                return SearchHit(item: item, rank: candidate.rank + (PathNoise.isNoisy(item.path) ? 10 : 0))
            }
            let hits = Self.sorted(ranked).prefix(limit)
            DispatchQueue.main.async {
                guard let self, self.spotlight === query else { return }
                self.scannedCount = count
                self.hits = Array(hits)
                self.truncated = count > limit
                self.isRunning = gathering
                if !self.selection.isEmpty {
                    self.selection.formIntersection(hits.map(\.id))
                }
            }
        }
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
        let sorted = Self.sorted(ranked)
        truncated = sorted.count > Self.maxResults
        hits = Array(sorted.prefix(Self.maxResults))
        let present = Set(hits.map(\.id))
        selection.formIntersection(present)
    }

    nonisolated static func sorted(_ hits: [SearchHit]) -> [SearchHit] {
        hits.sorted { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            return (lhs.item.modified ?? .distantPast) > (rhs.item.modified ?? .distantPast)
        }
    }

    /// Lower is better: exact name, then prefix, then word start, then anywhere.
    /// Items buried in Library, caches or dependency folders sink to the bottom.
    nonisolated static func rank(_ item: FileItem, terms: [String]) -> Int {
        rank(name: item.name, terms: terms.map { $0.lowercased() }) + (PathNoise.isNoisy(item.path) ? 10 : 0)
    }

    /// Name-only part of the rank; `terms` must be lowercased.
    nonisolated static func rank(name: String, terms: [String]) -> Int {
        guard let first = terms.first else { return 3 }
        let name = name.lowercased()
        if name == first { return 0 }
        let stem = name.lastIndex(of: ".").map { name[..<$0] } ?? name[...]
        if stem == first[...] { return 0 }
        if name.hasPrefix(first) { return 1 }
        // A match right after a separator is a word start ("my-report" for "report").
        var searchStart = name.startIndex
        while let match = name.range(of: first, range: searchStart..<name.endIndex) {
            if match.lowerBound > name.startIndex, " _-.".contains(name[name.index(before: match.lowerBound)]) {
                return 2
            }
            searchStart = name.index(after: match.lowerBound)
        }
        return 3
    }
}

/// Heuristics for paths people rarely mean when they search or browse recents.
enum PathNoise {
    static let noisyComponents: Set<Substring> = [
        "node_modules", ".git", "DerivedData", ".build", "Pods", "__pycache__", ".venv", "venv",
        ".cache", ".Trash", ".npm", ".gradle", ".next", ".turbo", "Caches", "site-packages",
    ]
    static let packageExtensions: Set<String> = [
        "app", "bundle", "framework", "photoslibrary", "musiclibrary", "xcodeproj", "xcworkspace",
        "xcassets", "plugin", "kext", "appex", "lproj", "playground", "sparsebundle", "pkg",
    ]

    private static let libraryPrefix = URL.home.path + "/Library/"
    /// iCloud Drive lives inside Library but holds your own documents.
    private static let iCloudPrefix = URL.home.path + "/Library/Mobile Documents/"

    static func isNoisy(_ path: String) -> Bool {
        let inICloud = path.hasPrefix(iCloudPrefix)
        if path.hasPrefix(libraryPrefix) && !inICloud { return true }
        // Within iCloud Drive, judge only the part below the container (com~apple~CloudDocs etc.).
        let checked = inICloud ? path.dropFirst(iCloudPrefix.count).drop { $0 != "/" } : path[...]
        let components = checked.split(separator: "/").dropLast()
        for component in components {
            if component.hasPrefix(".") || noisyComponents.contains(component) { return true }
            if let dot = component.lastIndex(of: "."),
               packageExtensions.contains(component[component.index(after: dot)...].lowercased()) {
                return true
            }
        }
        return false
    }
}
