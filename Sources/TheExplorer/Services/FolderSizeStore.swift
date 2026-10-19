import CoreServices
import Foundation
import Observation

struct FolderSize: Sendable {
    let bytes: Int64
    let files: Int
    /// False when some subfolders couldn't be read (permissions).
    let complete: Bool
    let measuredAt: Date
    /// How long measuring took.
    var cost: TimeInterval = 0
    /// The FSEvents event current when measuring began: changes after it aren't counted.
    var eventID: UInt64 = 0
    /// Added up from its subfolders' sizes rather than walked: any change below it counts,
    /// since the sizes it was made of may be older than `eventID`.
    var addedUp = false
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
    /// How long a size is trusted, at least, where FSEvents doesn't say what changed
    /// (~/Library, other disks). Inside the watched folders a size holds until something in it
    /// changes: re-measuring every subfolder of your home folder is walking millions of files.
    @ObservationIgnored private let freshness: TimeInterval = 1800
    /// Recent FSEvents changes (see absorb), and the latest event of those no longer kept.
    @ObservationIgnored private var recentChanges: [Change] = []
    @ObservationIgnored private var droppedThrough: UInt64 = 0
    /// Folders waiting for their subfolders' sizes, to add them up.
    @ObservationIgnored private var waiting: Set<String> = []
    /// Subfolders queued for a folder that's adding up: they're walked, never added up
    /// themselves, so a folder's sizes are worked out one level down, not all the way.
    @ObservationIgnored private var walkOnly: Set<String> = []
    /// Folders asked to be measured again even though their sizes are current.
    @ObservationIgnored private var forced: Set<String> = []
    /// The folders each list on screen shows, by list (held weakly, so closed tabs drop out).
    @ObservationIgnored private let shown = NSMapTable<AnyObject, NSArray>.weakToStrongObjects()
    @ObservationIgnored private var recheck: DispatchWorkItem?
    /// Measured (or being measured) folders something has changed inside since, with the
    /// latest such change's FSEvents event.
    @ObservationIgnored private var changed: [String: UInt64] = [:]

    func size(for path: String) -> FolderSize? { sizes[path] }

    // MARK: Between launches

    /// Sizes are kept between launches, so opening your home folder doesn't measure every
    /// folder in it again (a minute of work for millions of files). While the app runs it hears
    /// of every change, so when it quits it knows which sizes something changed in; those
    /// marks are saved too, with the FSEvents event they're good to. The next launch uses them
    /// when the index's replay of what changed since starts at or before that point, so
    /// changes made while the app was closed count as well.
    private struct Saved: Codable {
        struct Entry: Codable {
            let bytes: Int64
            let files: Int
            let complete: Bool
            let measuredAt: Date
            let cost: TimeInterval
            let eventID: UInt64
            let addedUp: Bool?
        }

        /// Every change before this event is in the marks.
        let eventID: UInt64
        let historyID: String?
        let sizes: [String: Entry]
        let changed: [String: UInt64]
    }

    nonisolated private static var fileURL: URL? {
        #if DEBUG
        // Scripted runs keep their sizes to themselves, if they keep them at all.
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["EXPLORER_SIZES_FILE"] { return URL(fileURLWithPath: path) }
        if environment["EXPLORER_SCENES"] != nil { return nil }
        #endif
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TheExplorer", isDirectory: true)
        return support.appendingPathComponent("folder-sizes.json")
    }

    /// Writes the sizes (when the app quits). Ones something has changed in since are kept
    /// too: if the next launch's replay covers them, it marks them changed again, so they show
    /// until they're measured and a big folder that's always changing waits its usual turn.
    func save() {
        guard let url = Self.fileURL else { return }
        let heard = FileIndex.shared.heardThrough()
        drainInbox()
        // Folders that are gone aren't worth keeping.
        let entries = sizes.filter { Darwin.access($0.key, F_OK) == 0 }.mapValues {
            Saved.Entry(bytes: $0.bytes, files: $0.files, complete: $0.complete, measuredAt: $0.measuredAt, cost: $0.cost,
                        eventID: $0.eventID, addedUp: $0.addedUp)
        }
        let saved = Saved(eventID: heard, historyID: FileIndexStore.historyID(for: URL.home.path), sizes: entries,
                          changed: changed.filter { sizes[$0.key] != nil })
        try? JSONEncoder().encode(saved).write(to: url, options: .atomic)
    }

    /// Called by the index, on its queue, just before FSEvents starts replaying changes from
    /// `eventID`. If the replay covers everything since the sizes were saved, they're all good
    /// (with their marks); if not (the app didn't quit cleanly), only those measured after it
    /// starts are, plus the ones FSEvents doesn't watch, which go by age as usual.
    nonisolated static func restoreSaved(replayingFrom eventID: FSEventStreamEventId, historyID: String?) {
        guard let url = fileURL, let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode(Saved.self, from: data), saved.historyID == historyID else { return }
        let covered = eventID <= saved.eventID
        let sizes = saved.sizes.filter { covered || $0.value.eventID >= eventID || !FileIndex.watches($0.key) }.mapValues {
            FolderSize(bytes: $0.bytes, files: $0.files, complete: $0.complete, measuredAt: $0.measuredAt, cost: $0.cost,
                       eventID: $0.eventID, addedUp: $0.addedUp ?? false)
        }
        let changed = covered ? saved.changed : [:]
        // Queued before the replay's changes, which then mark what changed meanwhile.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                shared.sizes.merge(sizes) { current, _ in current }
                shared.changed.merge(changed.filter { sizes[$0.key] != nil }) { max($0, $1) }
                NotificationCenter.default.post(name: didChange, object: shared)
            }
        }
    }

    typealias Change = (path: String, recursive: Bool, eventID: UInt64)

    /// Changes from FSEvents not handled yet. A box rather than a hop to the main thread per
    /// batch, so saving can take what's in it (see save).
    nonisolated private static let inbox = Inbox()

    private final class Inbox: @unchecked Sendable {
        private let lock = NSLock()
        private var changes: [Change] = []
        private var scheduled = false

        /// Adds changes; true if nobody's been asked to handle them yet.
        func add(_ new: [Change]) -> Bool {
            lock.withLock {
                changes += new
                defer { scheduled = true }
                return !scheduled
            }
        }

        func take() -> [Change] {
            lock.withLock {
                scheduled = false
                defer { changes = [] }
                return changes
            }
        }
    }

    /// Called from FSEvents (any thread) with folders whose contents changed.
    nonisolated static func filesChanged(_ changes: [Change]) {
        guard !changes.isEmpty, inbox.add(changes) else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { shared.drainInbox() }
        }
    }

    private func drainInbox() {
        let changes = Self.inbox.take()
        if !changes.isEmpty { markChanged(changes) }
    }

    /// A change in a folder changes the size of it and of every folder above it, unless the
    /// size was measured after the change (replayed changes at launch often were).
    private func markChanged(_ changes: [Change]) {
        // Kept a while, for sizes that arrive from a Storage scan begun before them.
        recentChanges.append(contentsOf: changes)
        if recentChanges.count > 20_000 {
            let dropped = recentChanges.count - 10_000
            droppedThrough = max(droppedThrough, recentChanges[..<dropped].map(\.eventID).max() ?? 0)
            recentChanges.removeFirst(dropped)
        }
        guard !sizes.isEmpty || !inFlight.isEmpty || !pending.isEmpty else { return }
        func mark(_ path: String, _ eventID: UInt64) {
            if let size = pending[path] ?? sizes[path], size.addedUp || eventID > size.eventID {
                changed[path] = max(changed[path] ?? 0, eventID)
            } else if inFlight.contains(path) {
                changed[path] = max(changed[path] ?? 0, eventID)
            }
        }
        for change in changes {
            var path = change.path
            while !path.isEmpty {
                mark(path, change.eventID)
                let parent = (path as NSString).deletingLastPathComponent
                if parent == path { break }
                path = parent
            }
            // Events were coalesced or dropped: anything inside may have changed.
            if change.recursive {
                let prefix = change.path == "/" ? "/" : change.path + "/"
                for key in sizes.keys where key.hasPrefix(prefix) { mark(key, change.eventID) }
            }
        }
        scheduleRecheck(after: 2)
    }

    /// A list's folders, whose sizes it shows: measured if they need to be, and measured again
    /// when something inside changes. An empty list when it leaves the screen.
    func show(_ paths: [String], by list: AnyObject) {
        if paths.isEmpty { shown.removeObject(forKey: list) } else { shown.setObject(paths as NSArray, forKey: list) }
        request(paths)
        // Ones that changed but aren't due yet get their turn.
        if paths.contains(where: { changed[$0] != nil }) { scheduleRecheck(after: 2) }
    }

    /// By the lists still around: the table can keep a gone list's folders a while, so they're
    /// looked up by its live keys.
    private var wanted: Set<String> {
        var paths = Set<String>()
        for list in shown.keyEnumerator().allObjects as [AnyObject] {
            if let folders = shown.object(forKey: list) as? [String] { paths.formUnion(folders) }
        }
        return paths
    }

    /// Measures again the sizes on screen that something changed inside, once changes settle
    /// and each folder's turn comes round (see isCurrent).
    private func scheduleRecheck(after delay: TimeInterval) {
        guard recheck == nil, !changed.isEmpty else { return }
        let wanted = wanted
        guard changed.keys.contains(where: wanted.contains) else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.recheck = nil
                let now = Date()
                let wanted = self.wanted
                let due = self.changed.keys.filter(wanted.contains)
                self.request(due)
                // The rest are waiting their turn, or being measured (a change may have come in
                // after the walk passed it): come back when the soonest is up.
                let waits = due.compactMap { path -> TimeInterval? in
                    guard self.changed[path] != nil else { return nil }
                    if self.inFlight.contains(path) || self.waiting.contains(path) || self.queued.contains(path) { return 30 }
                    guard let size = self.sizes[path] else { return nil }
                    return Self.remeasureWait(size) - now.timeIntervalSince(size.measuredAt)
                }
                if let soonest = waits.min() { self.scheduleRecheck(after: max(soonest, 5)) }
            }
        }
        recheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// How long a changed size waits to be measured again. Home folders always have something
    /// changing (app data, logs, caches), and each change touches every folder above it, so
    /// even cheap totals wait half a minute.
    private static func remeasureWait(_ size: FolderSize) -> TimeInterval { max(30, size.cost * 30) }

    private func isCurrent(_ path: String, _ size: FolderSize, now: Date) -> Bool {
        let age = now.timeIntervalSince(size.measuredAt)
        if changed[path] != nil {
            // Folders that never stop changing (an app's data, a build) and take seconds to
            // walk are re-measured now and then, not on every change: at most two minutes'
            // walking an hour, so a big folder's size can be a few minutes behind. Measured
            // again, a folder adds up its subfolders, so from then on only the ones that
            // changed are walked.
            return age < Self.remeasureWait(size)
        }
        // Unwatched, a size goes by age, and big ones (~/Library) last longer.
        return FileIndex.watches(path) || age < max(freshness, size.cost * 120)
    }

    func isCalculating(_ path: String) -> Bool {
        sizes[path] == nil && (inFlight.contains(path) || queued.contains(path) || waiting.contains(path) || pending[path] != nil)
    }

    /// Requests sizes for `paths`. Most recent requests run first so the visible folder wins.
    func request(_ paths: [String], force: Bool = false) {
        let now = Date()
        let needed = paths.filter { path in
            if inFlight.contains(path) || waiting.contains(path) || pending[path] != nil { return false }
            if !force, let cached = sizes[path], isCurrent(path, cached, now: now) { return false }
            return true
        }
        guard !needed.isEmpty else { return }
        let neededSet = Set(needed)
        if force { forced.formUnion(neededSet) }
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
        changed[path] = nil
    }

    /// Seeds the cache from a completed storage scan: its top levels, and anything bigger
    /// than a megabyte below them. A home folder has hundreds of thousands of small folders
    /// (most inside node_modules), not worth keeping a size for; browsing one measures it.
    /// `eventID` is the FSEvents event current when the scan began.
    func absorb(_ root: SizeNode, eventID: UInt64, finishedAt now: Date) {
        var updates: [String: FolderSize] = [:]
        let worthKeeping = { (node: SizeNode, depth: Int) in depth < 3 || node.size >= 1_000_000 }
        root.forEachFolder(descend: worthKeeping) { node, path, depth in
            guard worthKeeping(node, depth) else { return }
            updates[path] = FolderSize(bytes: node.size, files: node.fileCount, complete: node.isReadable, measuredAt: now, eventID: eventID)
        }
        // A size measured since the scan began is newer than the scan's.
        sizes.merge(updates) { current, scanned in current.eventID > scanned.eventID ? current : scanned }
        for path in updates.keys { if let latest = changed[path], latest <= eventID, sizes[path]?.eventID == eventID { changed[path] = nil } }
        // What changed while the scan ran isn't in it. If some of that's no longer kept, all of
        // the scan's sizes count as changed.
        if eventID < droppedThrough {
            for path in updates.keys where sizes[path]?.eventID == eventID { changed[path] = max(changed[path] ?? 0, droppedThrough) }
        }
        markChanged(recentChanges.filter { $0.eventID > eventID })
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    private func pump() {
        while inFlight.count < maxConcurrent, let path = queue.popLast() {
            queued.remove(path)
            // Restored from the last launch since it was asked for (unless asked to measure again).
            if !forced.contains(path), let cached = sizes[path], isCurrent(path, cached, now: Date()) {
                walkOnly.remove(path)
                retryWaiting()
                continue
            }
            let wasForced = forced.remove(path) != nil
            let canAddUp = walkOnly.remove(path) == nil && !wasForced
            inFlight.insert(path)
            let started = Date()
            let startEvent = FSEventsGetCurrentEventId()
            Task.detached(priority: .utility) {
                // A folder whose subfolders all have sizes adds them up instead of walking
                // everything again: your home folder's total, shown when nothing's selected,
                // would otherwise be millions of files every time.
                if canAddUp, let contents = DiskScanner.shallowSize(path: path), !contents.folders.isEmpty {
                    await MainActor.run {
                        self.inFlight.remove(path)
                        switch self.addedUp(contents, startEvent: startEvent, started: started) {
                        case .added(let size): self.publish(path, size)
                        // Its subfolders are being measured; it adds them up after.
                        case .waiting: self.waiting.insert(path)
                        }
                        self.pump()
                    }
                    return
                }
                let result = DiskScanner.folderSize(path: path)
                await MainActor.run {
                    self.inFlight.remove(path)
                    if let result {
                        self.publish(path, FolderSize(bytes: result.bytes, files: result.files, complete: result.complete,
                                                      measuredAt: started, cost: Date().timeIntervalSince(started), eventID: startEvent))
                    } else {
                        self.retryWaiting()
                    }
                    self.pump()
                }
            }
        }
    }

    private enum AddedUp {
        case added(FolderSize)
        /// Some subfolders are being measured.
        case waiting
    }

    /// A folder's size from its own files and its subfolders' sizes, once every subfolder has
    /// one; subfolders without one are queued.
    private func addedUp(_ contents: DiskScanner.ShallowSize, startEvent: UInt64, started: Date) -> AddedUp {
        let now = Date()
        var bytes = contents.bytes
        var files = contents.files
        var complete = contents.complete
        var oldest = started
        var missing: [String] = []
        var waits = false
        for folder in contents.folders {
            guard let size = pending[folder] ?? sizes[folder], isCurrent(folder, size, now: now) else {
                if inFlight.contains(folder) || queued.contains(folder) || waiting.contains(folder) {
                    waits = true
                } else {
                    missing.append(folder)
                }
                continue
            }
            bytes += size.bytes
            files += size.files
            complete = complete && size.complete
                oldest = min(oldest, size.measuredAt)
        }
        if !missing.isEmpty {
            // Ones nobody's asked about (hidden folders, Library) are measured for this: walked
            // if they've never been measured, so it goes one level down rather than all the
            // way, or added up again from their own subfolders if they have.
            walkOnly.formUnion(missing.filter { sizes[$0] == nil })
            queue.insert(contentsOf: missing, at: 0)
            queued.formUnion(missing)
            return .waiting
        }
        if waits { return .waiting }
        // It holds until something below it changes. A subfolder still waiting its turn to be
        // measured again is used as it is: when it gets a new size, that marks this one too.
        // Adding up again is cheap (its cost is the listing).
        // Unwatched folders go by age, so they're as old as their oldest part.
        return .added(FolderSize(bytes: bytes, files: files, complete: complete,
                                 measuredAt: FileIndex.watches(contents.path) ? started : oldest,
                                 cost: Date().timeIntervalSince(started), eventID: startEvent, addedUp: true))
    }

    /// Gives folders waiting on subfolders another go, once there's news of them: those that
    /// are the parents of `paths`, or all of them.
    private func retryWaiting(parentsOf paths: [String]? = nil) {
        guard !waiting.isEmpty else { return }
        let ready = paths.map { Set($0.map { ($0 as NSString).deletingLastPathComponent }).intersection(waiting) } ?? waiting
        guard !ready.isEmpty else { return }
        waiting.subtract(ready)
        queue.insert(contentsOf: ready, at: 0)
        queued.formUnion(ready)
    }

    private func publish(_ path: String, _ size: FolderSize) {
        // A new size for a folder is a new total for the one it's in.
        if let old = pending[path] ?? sizes[path], old.bytes != size.bytes || old.files != size.files {
            let parent = (path as NSString).deletingLastPathComponent
            if parent != path, sizes[parent] != nil || pending[parent] != nil {
                changed[parent] = max(changed[parent] ?? 0, FSEventsGetCurrentEventId())
                scheduleRecheck(after: 2)
            }
        }
        pending[path] = size
        // Changes from before measuring began are in it; later ones may have been missed, and
        // it gets measured again in its turn.
        if let latest = changed[path], latest <= size.eventID { changed[path] = nil }
        if changed[path] != nil { scheduleRecheck(after: Self.remeasureWait(size)) }
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [self] in
            flushScheduled = false
            let published = Array(pending.keys)
            sizes.merge(pending) { _, new in new }
            pending = [:]
            NotificationCenter.default.post(name: Self.didChange, object: self)
            // Folders waiting on these try adding up again (after anything already queued).
            if !waiting.isEmpty {
                retryWaiting(parentsOf: published)
                pump()
            }
        }
    }
}
