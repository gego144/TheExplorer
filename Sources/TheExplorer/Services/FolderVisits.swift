import Foundation
import Observation

/// Folders you spend time in, ranked by frecency the way zoxide does: every visit adds to a
/// folder's count, and the count is weighted by how long ago the last visit was. ⌘K lists the
/// top ones before you type, path completion puts them first, and search ranks them (and what's
/// in them) higher.
///
/// Passing through a folder on the way somewhere else isn't a visit: it counts once you've stayed
/// a moment, or opened a file in it.
@MainActor
@Observable
final class FolderVisits {
    struct Visit: Codable, Equatable {
        var rank: Double
        var last: Date
    }

    static let shared = FolderVisits(fileURL: FolderVisits.defaultURL)

    /// How long you have to stay in a folder for it to count.
    static let dwell: Duration = .milliseconds(1500)
    /// Once the counts add up to this, they all shrink, so old habits fade and the list stays short.
    static let maxTotal = 2000.0

    private(set) var visits: [String: Visit] = [:]
    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: Visit].self, from: data) {
            visits = decoded
        }
    }

    static var defaultURL: URL? {
        #if DEBUG
        // Scripted runs keep their visits to themselves unless given a file.
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["EXPLORER_VISITS_FILE"] { return URL(fileURLWithPath: path) }
        if environment["EXPLORER_SCENES"] != nil { return nil }
        #endif
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TheExplorer", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("folder-visits.json")
    }

    func record(_ folder: URL, now: Date = Date()) {
        guard folder.isFileURL else { return }
        let path = folder.standardizedFileURL.path
        guard path != "/" else { return }
        var visit = visits[path] ?? Visit(rank: 0, last: now)
        visit.rank += 1
        visit.last = now
        visits[path] = visit
        age()
        scheduleSave()
    }

    func forget(_ path: String) {
        guard visits.removeValue(forKey: path) != nil else { return }
        scheduleSave()
    }

    func clear() {
        visits = [:]
        scheduleSave()
    }

    /// Visits weighted by recency: within the hour counts 4×, the day 2×, the week ½, older ¼.
    static func frecency(_ visit: Visit, now: Date) -> Double {
        let age = now.timeIntervalSince(visit.last)
        let weight: Double = age < 3600 ? 4 : age < 86_400 ? 2 : age < 7 * 86_400 ? 0.5 : 0.25
        return visit.rank * weight
    }

    /// The best folders first, leaving out ones that no longer exist.
    func top(_ limit: Int, excluding excluded: Set<String> = [], now: Date = Date()) -> [URL] {
        var result: [URL] = []
        for (path, _) in ranked(now: now) where !excluded.contains(path) {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
            result.append(URL(fileURLWithPath: path, isDirectory: true))
            if result.count == limit { break }
        }
        return result
    }

    /// How much a folder's frecency is worth, for sorting suggestions.
    func score(_ path: String, now: Date = Date()) -> Double {
        visits[path].map { Self.frecency($0, now: now) } ?? 0
    }

    /// Search score bonuses for the top folders, read on the main actor and handed to the index
    /// search. One visit within the hour is worth about a word-start-over-substring bump; a
    /// folder you live in, about a prefix-over-word-start one.
    func searchBoosts(limit: Int = 64, now: Date = Date()) -> [String: Int] {
        var boosts: [String: Int] = [:]
        // Home is where every window starts; boosting it would lift everything you own.
        for (path, frecency) in ranked(now: now).filter({ $0.path != Self.home }).prefix(limit) {
            let boost = min(200, Int(40 * log2(1 + frecency)))
            if boost > 0 { boosts[path] = boost }
        }
        return boosts
    }

    private static let home = URL.home.standardizedFileURL.path

    private func ranked(now: Date) -> [(path: String, frecency: Double)] {
        visits.map { ($0.key, Self.frecency($0.value, now: now)) }
            .sorted { $0.frecency != $1.frecency ? $0.frecency > $1.frecency : $0.path < $1.path }
    }

    private func age() {
        let total = visits.values.reduce(0) { $0 + $1.rank }
        guard total > Self.maxTotal else { return }
        for (path, visit) in visits {
            let rank = visit.rank * 0.9
            if rank < 1 { visits[path] = nil } else { visits[path]?.rank = rank }
        }
    }

    private func scheduleSave() {
        guard let fileURL else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            self.saveNow(to: fileURL)
        }
    }

    /// Writes right away (at quit, so the last few visits aren't lost).
    func saveIfNeeded() {
        guard let saveTask, let fileURL else { return }
        saveTask.cancel()
        self.saveTask = nil
        saveNow(to: fileURL)
    }

    private func saveNow(to fileURL: URL) {
        saveTask = nil
        guard let data = try? JSONEncoder().encode(visits) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
