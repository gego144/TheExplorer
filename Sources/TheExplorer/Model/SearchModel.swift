import Foundation
import Observation

enum SearchScope: Hashable {
    /// The current folder and everything in it: from the index when it covers the folder,
    /// otherwise (or with hidden files shown) a live walk that finds everything.
    case folder
    /// Everything in TheExplorer's index (see FileIndex).
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
    /// The index is still being built (only right after launch).
    private(set) var isIndexing = false
    var kindFilter: KindFilter = .all
    var selection: Set<URL> = []

    static let maxResults = 2000
    /// Results from the index are ranked, so only the best are worth listing.
    static let indexResults = 200

    @ObservationIgnored private var task: Task<Void, Never>?
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
        // The index answers in milliseconds, so it only waits out a burst of typing; a walk
        // starts over on every change, so it waits for a pause.
        let indexed = scope == .mac || (!includeHidden && FileIndex.shared.covers(folder.path))
        task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(indexed ? 25 : 180))
            guard let self, !Task.isCancelled else { return }
            if indexed {
                await self.runIndex(text: text, under: scope == .folder ? folder.path : nil, includeHidden: includeHidden)
            } else {
                await self.runFolderWalk(terms: terms, folder: folder, includeHidden: includeHidden)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
        isIndexing = false
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

    // MARK: - Index

    private func runIndex(text: String, under folder: String?, includeHidden: Bool) async {
        let index = FileIndex.shared
        if !index.isReady {
            isIndexing = true
            await index.waitUntilReady()
            isIndexing = false
            guard !Task.isCancelled else { return }
        }
        let limit = Self.indexResults
        let boosts = FolderVisits.shared.searchBoosts()
        let found = await Task.detached(priority: .userInitiated) { () -> [SearchHit] in
            let storage = index.snapshot()
            let under = folder.flatMap { FileIndex.resolve($0, in: storage) }
            let hits = FileIndex.search(text, in: storage, under: under, includeHidden: includeHidden,
                                        boosts: boosts, limit: limit)
            return hits.enumerated().compactMap { rank, hit in
                FileItem(url: URL(fileURLWithPath: hit.path, isDirectory: hit.isFolder)).map { SearchHit(item: $0, rank: rank) }
            }
        }.value
        guard !Task.isCancelled else { return }
        // Already in order of relevance.
        hits = found
        truncated = found.count >= limit
        selection.formIntersection(found.map(\.id))
        isRunning = false
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
