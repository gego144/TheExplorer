import Foundation
import Observation

struct Favorite: Identifiable, Codable, Hashable {
    var id = UUID()
    var path: String
    var isDirectory: Bool
    var addedAt = Date()

    var url: URL { URL(fileURLWithPath: path) }
    var name: String { FileManager.default.displayName(atPath: path) }
    var exists: Bool { FileManager.default.fileExists(atPath: path) }
}

/// Favorite files and folders, persisted to Application Support and shared across windows.
@MainActor
@Observable
final class FavoritesStore {
    static let shared = FavoritesStore()

    private(set) var favorites: [Favorite] = []
    @ObservationIgnored private let fileURL: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TheExplorer", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        fileURL = support.appendingPathComponent("favorites.json")
        #if DEBUG
        if let pins = DemoMode.pins {
            favorites = pins.map { Favorite(path: $0, isDirectory: true) }
            isDemo = true
            return
        }
        #endif
        load()
    }

    /// Demo pins (debug screenshots) are never written over your real ones.
    @ObservationIgnored private var isDemo = false

    func contains(_ url: URL) -> Bool {
        favorites.contains { $0.path == url.path }
    }

    func add(_ url: URL, at index: Int? = nil) {
        guard !contains(url) else { return }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
        let isPackage = (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) ?? false
        let favorite = Favorite(path: url.path, isDirectory: isDir.boolValue && !isPackage)
        favorites.insert(favorite, at: min(index ?? favorites.count, favorites.count))
        save()
    }

    func remove(_ url: URL) {
        favorites.removeAll { $0.path == url.path }
        save()
    }

    func toggle(_ url: URL) {
        contains(url) ? remove(url) : add(url)
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        favorites.move(fromOffsets: source, toOffset: destination)
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Favorite].self, from: data) else {
            favorites = Self.defaults()
            return
        }
        favorites = decoded
    }

    private func save() {
        guard !isDemo else { return }
        guard let data = try? JSONEncoder().encode(favorites) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func defaults() -> [Favorite] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        return ["Developer", "Dev", "Projects"]
            .map { home.appendingPathComponent($0) }
            .filter { fm.fileExists(atPath: $0.path) }
            .map { Favorite(path: $0.path, isDirectory: true) }
    }
}
