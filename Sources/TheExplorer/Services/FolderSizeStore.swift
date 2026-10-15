import Foundation
import Observation

struct FolderSize: Sendable {
    let bytes: Int64
    let files: Int
    /// False when some subfolders couldn't be read (permissions).
    let complete: Bool
    let measuredAt: Date
}

/// Computes and caches recursive folder sizes in the background, shared across windows.
/// Results are published in batches so a folder of hundreds of subfolders doesn't redraw the
/// list hundreds of times.
@MainActor
@Observable
final class FolderSizeStore {
    static let shared = FolderSizeStore()
    /// Posted after each batch of new sizes lands in `sizes`.
    static let didChange = Notification.Name("FolderSizeStoreDidChange")

    private(set) var sizes: [String: FolderSize] = [:]
    @ObservationIgnored private var queue: [String] = []
    @ObservationIgnored private var queued: Set<String> = []
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private var pending: [String: FolderSize] = [:]
    @ObservationIgnored private var flushScheduled = false
    @ObservationIgnored private let maxConcurrent = 4
    @ObservationIgnored private let freshness: TimeInterval = 300

    func size(for path: String) -> FolderSize? { sizes[path] }

    func isCalculating(_ path: String) -> Bool {
        sizes[path] == nil && (inFlight.contains(path) || queued.contains(path) || pending[path] != nil)
    }

    /// Requests sizes for `paths`. Most recent requests run first so the visible folder wins.
    func request(_ paths: [String], force: Bool = false) {
        let now = Date()
        let needed = paths.filter { path in
            if inFlight.contains(path) || pending[path] != nil { return false }
            if !force, let cached = sizes[path], now.timeIntervalSince(cached.measuredAt) < freshness { return false }
            return true
        }
        guard !needed.isEmpty else { return }
        let neededSet = Set(needed)
        if !queued.isDisjoint(with: neededSet) {
            queue.removeAll { neededSet.contains($0) }
        }
        queue.append(contentsOf: needed.reversed())
        queued.formUnion(neededSet)
        pump()
    }

    func invalidate(_ path: String) {
        pending[path] = nil
        sizes[path] = nil
    }

    /// Seeds the cache from a completed storage scan.
    func absorb(_ root: SizeNode) {
        let now = Date()
        var updates: [String: FolderSize] = [:]
        root.forEachFolder { node in
            updates[node.path] = FolderSize(bytes: node.size, files: node.fileCount, complete: node.isReadable, measuredAt: now)
        }
        sizes.merge(updates) { _, new in new }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    private func pump() {
        while inFlight.count < maxConcurrent, let path = queue.popLast() {
            queued.remove(path)
            inFlight.insert(path)
            Task.detached(priority: .utility) {
                let result = DiskScanner.folderSize(path: path)
                await MainActor.run {
                    self.inFlight.remove(path)
                    if let result {
                        self.publish(path, FolderSize(bytes: result.bytes, files: result.files, complete: result.complete, measuredAt: Date()))
                    }
                    self.pump()
                }
            }
        }
    }

    private func publish(_ path: String, _ size: FolderSize) {
        pending[path] = size
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [self] in
            flushScheduled = false
            sizes.merge(pending) { _, new in new }
            pending = [:]
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }
}
