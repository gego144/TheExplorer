import CoreServices
import Darwin
import Foundation

/// TheExplorer's own index of file names, searched instead of Spotlight.
///
/// It covers your home folder, Applications, iCloud Drive and cloud storage folders, and skips
/// what you'd never look for there: Library, the insides of apps and other packages, hidden
/// folders, and dependency and build folders like node_modules (the folders themselves are
/// indexed, just not their contents). That leaves a few hundred thousand items on a typical Mac,
/// small enough to keep in memory as plain arrays and match in full on every keystroke.
///
/// It's built once, in parallel (a second or two), saved to disk (see FileIndexStore), and from
/// then on kept current with FSEvents: changes show up in results right away, and at launch the
/// saved copy loads in milliseconds and catches up on whatever changed while the app was closed.
final class FileIndex: @unchecked Sendable {
    static let shared = FileIndex()
    /// Posted on the main thread after the index changes.
    static let didChange = Notification.Name("FileIndex.didChange")

    struct Flags: OptionSet, Sendable {
        let rawValue: UInt8
        static let folder = Flags(rawValue: 1 << 0)
        static let package = Flags(rawValue: 1 << 1)
        static let hidden = Flags(rawValue: 1 << 2)
        static let removed = Flags(rawValue: 1 << 3)
        /// A folder whose contents aren't indexed (node_modules, packages, hidden folders…).
        static let pruned = Flags(rawValue: 1 << 4)
        /// A name that isn't plain ASCII; it's matched through `folded`.
        static let nonASCII = Flags(rawValue: 1 << 5)
        static let root = Flags(rawValue: 1 << 6)
    }

    /// Every entry as parallel arrays. Parents always come before their children, so one pass
    /// in index order can carry anything (like "inside this folder") down the tree.
    struct Storage: Sendable {
        var parent: [Int32] = []
        var firstChild: [Int32] = []
        var nextSibling: [Int32] = []
        var nameStart: [UInt32] = []
        var nameLength: [UInt16] = []
        var flags: [Flags] = []
        /// Content modification time, in seconds since 2001.
        var modified: [Int32] = []
        /// Creation time, in seconds since 2001.
        var created: [Int32] = []
        /// Last change to the entry itself (content, name, folder, permissions), in seconds since
        /// 2001. Moving or copying something into a folder sets it, so it's never earlier than
        /// the date the item was added there.
        var changed: [Int32] = []
        /// Names as stored on disk, UTF-8. Roots hold their full path.
        var names: [UInt8] = []
        /// Lowercased, accent-free spellings of names that aren't plain ASCII.
        var folded: [Int32: [UInt8]] = [:]
        var roots: [Int32] = []
        var removedCount = 0

        var count: Int { parent.count }
        var liveCount: Int { count - removedCount - roots.count }

        func name(_ index: Int32) -> String {
            let start = Int(nameStart[Int(index)])
            return String(decoding: names[start..<start + Int(nameLength[Int(index)])], as: UTF8.self)
        }

        func path(_ index: Int32) -> String {
            var parts: [String] = []
            var current = index
            while current >= 0 {
                parts.append(name(current))
                current = parent[Int(current)]
            }
            return parts.reversed().joined(separator: "/")
        }

        func depth(_ index: Int32) -> Int {
            var depth = 0
            var current = parent[Int(index)]
            while current >= 0 {
                depth += 1
                current = parent[Int(current)]
            }
            return depth
        }

        func times(_ index: Int32) -> Times {
            let i = Int(index)
            return Times(modified: modified[i], created: created[i], changed: changed[i])
        }

        mutating func add(name: UnsafeBufferPointer<UInt8>, parent: Int32, flags: Flags, times: Times) -> Int32 {
            let index = Int32(count)
            var flags = flags
            if name.contains(where: { $0 >= 0x80 }) {
                flags.insert(.nonASCII)
                folded[index] = FuzzyMatcher.fold(String(decoding: name, as: UTF8.self))
            }
            self.parent.append(parent)
            firstChild.append(-1)
            nextSibling.append(-1)
            nameStart.append(UInt32(names.count))
            nameLength.append(UInt16(min(name.count, Int(UInt16.max))))
            names.append(contentsOf: name.prefix(Int(UInt16.max)))
            self.flags.append(flags)
            modified.append(times.modified)
            created.append(times.created)
            changed.append(times.changed)
            return index
        }

        mutating func add(name: String, parent: Int32, flags: Flags, times: Times) -> Int32 {
            var name = name
            return name.withUTF8 { add(name: $0, parent: parent, flags: flags, times: times) }
        }

        /// Adds an entry to the front of its parent's children.
        mutating func link(_ index: Int32) {
            let parent = parent[Int(index)]
            guard parent >= 0 else { return }
            nextSibling[Int(index)] = firstChild[Int(parent)]
            firstChild[Int(parent)] = index
        }

        /// Appends a separately built subtree. Entries whose parent is -1 go under `base`.
        mutating func append(_ chunk: Storage, under base: Int32) {
            let offset = Int32(count)
            let nameOffset = UInt32(names.count)
            parent.reserveCapacity(count + chunk.count)
            for i in 0..<chunk.count {
                let local = chunk.parent[i]
                parent.append(local < 0 ? base : local + offset)
                nameStart.append(chunk.nameStart[i] + nameOffset)
            }
            firstChild.append(contentsOf: repeatElement(-1, count: chunk.count))
            nextSibling.append(contentsOf: repeatElement(-1, count: chunk.count))
            nameLength.append(contentsOf: chunk.nameLength)
            flags.append(contentsOf: chunk.flags)
            modified.append(contentsOf: chunk.modified)
            created.append(contentsOf: chunk.created)
            changed.append(contentsOf: chunk.changed)
            names.append(contentsOf: chunk.names)
            for (key, value) in chunk.folded { folded[key + offset] = value }
            // In reverse, so children end up listed in index order.
            for i in stride(from: count - 1, through: Int(offset), by: -1) { link(Int32(i)) }
        }

        func children(of index: Int32) -> [Int32] {
            var result: [Int32] = []
            var child = firstChild[Int(index)]
            while child >= 0 {
                result.append(child)
                child = nextSibling[Int(child)]
            }
            return result
        }

        /// Marks an entry and everything below it as gone. The caller relinks the parent.
        mutating func remove(_ index: Int32) {
            var stack = [index]
            while let current = stack.popLast() {
                guard !flags[Int(current)].contains(.removed) else { continue }
                flags[Int(current)].insert(.removed)
                removedCount += 1
                stack.append(contentsOf: children(of: current))
            }
        }

        /// Rebuilds a folder's child list without removed entries.
        mutating func relink(_ index: Int32) {
            let live = children(of: index).filter { !flags[Int($0)].contains(.removed) }
            firstChild[Int(index)] = -1
            for child in live.reversed() {
                nextSibling[Int(child)] = firstChild[Int(index)]
                firstChild[Int(index)] = child
            }
        }

        /// Drops removed entries for good, renumbering the rest (still parents first).
        func compacted() -> Storage {
            var result = Storage()
            var map = [Int32](repeating: -1, count: count)
            for i in 0..<count where !flags[i].contains(.removed) {
                let parent = parent[i]
                let newParent = parent >= 0 ? map[Int(parent)] : -1
                if parent >= 0 && newParent < 0 { continue }
                let start = Int(nameStart[i])
                let index = names.withUnsafeBufferPointer { buffer in
                    result.add(name: UnsafeBufferPointer(rebasing: buffer[start..<start + Int(nameLength[i])]),
                               parent: newParent, flags: flags[i], times: times(Int32(i)))
                }
                map[i] = index
            }
            for i in stride(from: result.count - 1, through: 0, by: -1) { result.link(Int32(i)) }
            result.roots = roots.map { map[Int($0)] }.filter { $0 >= 0 }
            return result
        }
    }

    // MARK: - State

    private let lock = NSLock()
    /// What searches read. Replaced (never edited) under the lock, so a search can take it
    /// without waiting for the disk.
    private var storage = Storage()
    /// The copy `queue` edits before publishing it as `storage`.
    private var working = Storage()
    private var rootPaths: [String] = []
    private var ready = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// Index changes run here, one at a time: the build, then FSEvents updates.
    private let queue = DispatchQueue(label: "FileIndex", qos: .utility)
    /// One stream for the roots outside ~/Library, which skips Library's constant churn
    /// (Biome, caches, preferences: most of a home folder's events), and one for the cloud roots
    /// inside it. Excluding a path silences roots under it too, hence two.
    private var streams: [FSEventStreamRef] = []
    /// The latest event each stream has delivered.
    private var streamEventIDs: [FSEventStreamEventId] = []
    /// When each stream last called back.
    private var streamHeardAt: [CFAbsoluteTime] = []
    /// Streams still replaying what changed while the app was closed.
    private var streamReplaying: [Bool] = []
    /// The current event ID now and then, with when it was read (see settledEventID).
    private var idSamples: [(time: CFAbsoluteTime, id: FSEventStreamEventId)] = []
    private var started = false
    private(set) var lastBuildDuration: TimeInterval = 0
    /// How the index came to be this session, for diagnostics ("loaded in 9ms").
    private(set) var origin = ""
    /// The latest FSEvents event the index reflects; saved so the next launch replays from it.
    private var lastEventID: FSEventStreamEventId = 0
    private var historyID: String?
    private var pendingSave: DispatchWorkItem?
    private let storeURL = FileIndexStore.defaultURL
    /// Changes are saved this long after they happen, so a burst is written once.
    private static let saveDelay: TimeInterval = 20

    var isReady: Bool { lock.withLock { ready } }
    var itemCount: Int { lock.withLock { storage.liveCount } }

    /// Whether FSEvents reports changes inside `path` (see watch): the indexed roots, apart
    /// from Library's churn.
    static func watches(_ path: String) -> Bool {
        let library = URL.home.path + "/Library"
        let roots = defaultRoots
        guard roots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { return false }
        if path == library || path.hasPrefix(library + "/") {
            return roots.contains { $0.hasPrefix(library + "/") && (path == $0 || path.hasPrefix($0 + "/")) }
        }
        return true
    }

    /// The folders indexed by default.
    static var defaultRoots: [String] {
        let home = URL.home.path
        return [home, "/Applications", "/System/Applications",
                home + "/Library/Mobile Documents", home + "/Library/CloudStorage"]
    }

    /// Builds the index in the background and starts following changes. Safe to call again.
    func start(roots: [String] = FileIndex.defaultRoots) {
        let begin = lock.withLock { () -> Bool in
            guard !started else { return false }
            started = true
            return true
        }
        guard begin else { return }
        queue.async { [self] in
            let began = Date()
            let roots = roots.filter { FileManager.default.fileExists(atPath: $0) }
            lock.withLock { rootPaths = roots }
            historyID = FileIndexStore.historyID(for: URL.home.path)
            if let saved = FileIndexStore.load(from: storeURL), saved.roots == roots {
                publish(saved.storage)
                origin = String(format: "loaded in %.0fms", Date().timeIntervalSince(began) * 1000)
                if saved.historyID == historyID && saved.eventID > 0 {
                    // FSEvents replays what changed while the app was closed, then keeps going.
                    // Saved folder sizes are good if the replay covers everything since they
                    // were saved; it tells them what changed.
                    lastEventID = saved.eventID
                    FolderSizeStore.restoreSaved(replayingFrom: saved.eventID, historyID: historyID)
                    watch(roots, since: saved.eventID)
                    return
                }
                // The disk's change history was reset, so it can't say what changed. Searches
                // use the saved copy while a fresh one is built.
                origin += ", rebuilding (change history reset)"
            }
            // Watch first, so nothing that changes during the build is missed; the events
            // queue up behind the build and apply once it's done.
            watch(roots, since: FSEventStreamEventId(kFSEventStreamEventIdSinceNow))
            rebuild()
        }
    }

    /// Writes any unsaved changes now (when the app quits).
    func saveIfNeeded() {
        queue.sync {
            guard pendingSave != nil else { return }
            save()
        }
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        pendingSave = work
        queue.asyncAfter(deadline: .now() + Self.saveDelay, execute: work)
    }

    /// Runs on `queue`.
    private func save() {
        pendingSave?.cancel()
        pendingSave = nil
        lastEventID = max(lastEventID, settledEventID())
        try? FileIndexStore.save(working, roots: lock.withLock { rootPaths }, eventID: lastEventID, historyID: historyID, to: storeURL)
    }

    /// Re-indexes everything from scratch, e.g. from Settings.
    func rebuildNow() {
        queue.async { [self] in rebuild() }
    }

    /// Waits for the first build to finish.
    func waitUntilReady() async {
        await withCheckedContinuation { continuation in
            let done = lock.withLock { () -> Bool in
                if ready { return true }
                waiters.append(continuation)
                return false
            }
            if done { continuation.resume() }
        }
    }

    /// Whether searching inside `folder` can use the index: it's indexed, and so is everything
    /// in it (apart from hidden and dependency folders). Before the first build, assumes so.
    func covers(_ folder: String) -> Bool {
        let storage = snapshot()
        guard isReady else { return Self.defaultRoots.contains { folder == $0 || folder.hasPrefix($0 + "/") } }
        guard let index = Self.resolve(folder, in: storage) else { return false }
        return !storage.flags[Int(index)].contains(.pruned)
    }

    /// A consistent copy for a search; changes after this don't affect it.
    func snapshot() -> Storage {
        lock.withLock { storage }
    }

    private func rebuild() {
        let began = Date()
        // Everything after this is either in the build or replayed by FSEvents.
        let eventID = FSEventsGetCurrentEventId()
        IgnoreRules.shared.reset()
        let built = Self.build(roots: lock.withLock { rootPaths })
        lastBuildDuration = Date().timeIntervalSince(began)
        origin = (origin.isEmpty ? "" : origin + "; ") + String(format: "built in %.2fs", lastBuildDuration)
        lastEventID = max(lastEventID, eventID)
        publish(built)
        save()
    }

    /// Makes `built` what searches use. Runs on `queue`.
    private func publish(_ built: Storage) {
        working = built
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            storage = built
            ready = true
            defer { waiters = [] }
            return waiters
        }
        waiting.forEach { $0.resume() }
        notifyChanged()
    }

    private func notifyChanged() {
        let count = itemCount
        let duration = lastBuildDuration
        DispatchQueue.main.async {
            IndexStatus.shared.update(itemCount: count, buildDuration: duration)
            NotificationCenter.default.post(name: FileIndex.didChange, object: nil)
        }
    }

    // MARK: - What gets indexed

    enum Rules {
        /// Folders indexed themselves but never descended into.
        static let skippedFolderNames: Set<String> = [
            "node_modules", "bower_components", "DerivedData", "Pods", "Carthage", "__pycache__",
            "venv", "site-packages", "Caches", "PackageCache", "CMakeFiles",
        ]
        /// Folders of apps, indexed two levels deep: enough for every app (and folders of apps,
        /// like Utilities) without the thousands of files some installers put alongside them.
        static let appFolders = ["/Applications/", "/System/Applications/"]
        static let packageExtensions: Set<String> = [
            "app", "bundle", "framework", "plugin", "kext", "appex", "xpc", "photoslibrary",
            "musiclibrary", "tvlibrary", "imovielibrary", "fcpbundle", "logicx", "band", "xcodeproj",
            "xcworkspace", "xcarchive", "dsym", "playground", "sparsebundle", "pkg", "mpkg", "rtfd",
            "pages", "numbers", "key", "scptd", "mdimporter", "qlgenerator", "prefpane", "saver",
            "docarchive", "lproj", "xcassets", "aplibrary",
        ]
        /// Library is skipped, apart from iCloud Drive and cloud storage, which are their own roots.
        static let skippedPaths: Set<String> = [URL.home.path + "/Library", "/System/Volumes", "/Volumes"]

        static func isPackage(_ name: String) -> Bool {
            guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
            return packageExtensions.contains(name[name.index(after: dot)...].lowercased())
        }

        /// Whether a folder's contents belong in the index.
        /// What Unity regenerates inside a project (next to its ProjectSettings folder).
        static let unityCaches: Set<String> = ["Library", "Temp", "Logs", "obj", "UserSettings"]

        static func descends(name: String, path: String, hidden: Bool) -> Bool {
            if hidden || skippedFolderNames.contains(name) || isPackage(name) || skippedPaths.contains(path) { return false }
            for folder in appFolders where path.hasPrefix(folder) && path.dropFirst(folder.count).contains("/") {
                return false
            }
            if unityCaches.contains(name), access((path as NSString).deletingLastPathComponent + "/ProjectSettings", F_OK) == 0 {
                return false
            }
            return !IgnoreRules.shared.ignores(path)
        }
    }

    // MARK: - Building

    static func build(roots: [String]) -> Storage {
        var storage = Storage()
        // Each root's top-level folders are walked in parallel, then stitched together.
        var jobs: [(path: String, root: Int32)] = []
        for root in roots {
            let rootIndex = storage.add(name: root, parent: -1, flags: [.folder, .root], times: .none)
            storage.roots.append(rootIndex)
            for child in shallowList(root) {
                // Another root nested inside (cloud folders under Library) is walked as its own root.
                guard !roots.contains(child.path) || child.path == root else { continue }
                if child.flags.contains(.folder) && !child.flags.contains(.pruned) {
                    jobs.append((child.path, rootIndex))
                } else {
                    let index = storage.add(name: child.name, parent: rootIndex, flags: child.flags, times: child.times)
                    storage.link(index)
                }
            }
        }
        var chunks = [Storage?](repeating: nil, count: jobs.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: jobs.count) { job in
            var chunk = Storage()
            walk(jobs[job].path, into: &chunk)
            lock.withLock { chunks[job] = chunk }
        }
        for (job, chunk) in zip(jobs, chunks) {
            if let chunk { storage.append(chunk, under: job.root) }
        }
        return storage
    }

    struct Listed {
        let name: String
        let path: String
        let flags: Flags
        let times: Times
    }

    /// An entry's dates, in seconds since 2001.
    struct Times: Equatable, Sendable {
        var modified: Int32
        var created: Int32
        var changed: Int32

        static let none = Times(modified: 0, created: 0, changed: 0)

        init(modified: Int32, created: Int32, changed: Int32) {
            self.modified = modified
            self.created = created
            self.changed = changed
        }

        init(_ st: stat) {
            modified = Self.seconds(st.st_mtimespec)
            created = Self.seconds(st.st_birthtimespec)
            changed = Self.seconds(st.st_ctimespec)
        }

        private static func seconds(_ time: timespec) -> Int32 {
            Int32(clamping: time.tv_sec - 978_307_200)
        }
    }

    /// A folder's direct contents, classified.
    static func shallowList(_ folder: String) -> [Listed] {
        guard let dir = opendir(folder) else { return [] }
        defer { closedir(dir) }
        var result: [Listed] = []
        while let entry = readdir(dir) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name == "." || name == ".." { continue }
            let path = folder == "/" ? "/" + name : folder + "/" + name
            var st = stat()
            guard lstat(path, &st) == 0 else { continue }
            result.append(Listed(name: name, path: path, flags: classify(name: name, path: path, st: st), times: Times(st)))
        }
        return result
    }

    static func classify(name: String, path: String, st: stat) -> Flags {
        var flags: Flags = []
        let hidden = name.hasPrefix(".") || (st.st_flags & UInt32(UF_HIDDEN)) != 0
        if hidden { flags.insert(.hidden) }
        if (st.st_mode & S_IFMT) == S_IFDIR {
            flags.insert(.folder)
            if Rules.isPackage(name) { flags.insert(.package) }
            if !Rules.descends(name: name, path: path, hidden: hidden) { flags.insert(.pruned) }
        }
        return flags
    }

    /// Walks a folder and everything indexable inside it into `chunk`. The folder itself gets
    /// parent -1 (the caller attaches it).
    static func walk(_ path: String, into chunk: inout Storage) {
        guard let cPath = strdup(path) else { return }
        defer { free(cPath) }
        var paths: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return }
        defer { fts_close(fts) }
        // The entry recorded for the folder open at each depth.
        var parents: [Int32] = []
        while let entry = fts_read(fts) {
            let ent = entry.pointee
            let info = Int32(ent.fts_info)
            if info == FTS_DP { continue }
            let level = Int(ent.fts_level)
            guard let statp = ent.fts_statp, let fullPath = ent.fts_path else { continue }
            // fts names the starting folder by its whole path; every other entry by its name.
            let nameLength = level == 0 ? strlen(fullPath) - (strrchr(fullPath, 0x2F).map { $0 - fullPath + 1 } ?? 0) : Int(ent.fts_namelen)
            let nameBytes = UnsafeBufferPointer(
                start: UnsafeRawPointer(fullPath + Int(ent.fts_pathlen) - nameLength).assumingMemoryBound(to: UInt8.self),
                count: nameLength)
            let parent: Int32 = level == 0 ? -1 : (level - 1 < parents.count ? parents[level - 1] : -1)
            if level > 0 && parent < 0 { continue }
            let st = statp.pointee
            switch info {
            case FTS_D, FTS_DNR, FTS_DC:
                let name = String(decoding: nameBytes, as: UTF8.self)
                let flags = classify(name: name, path: String(cString: fullPath), st: st)
                let index = chunk.add(name: nameBytes, parent: parent, flags: flags, times: Times(st))
                if parents.count > level { parents.removeSubrange(level...) }
                parents.append(index)
                if info == FTS_D && flags.contains(.pruned) { fts_set(fts, entry, FTS_SKIP) }
            case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                var flags: Flags = []
                if nameBytes.first == UInt8(ascii: ".") || (st.st_flags & UInt32(UF_HIDDEN)) != 0 { flags.insert(.hidden) }
                _ = chunk.add(name: nameBytes, parent: parent, flags: flags, times: Times(st))
            default:
                continue
            }
        }
        // Children were appended after their parents; link them in index order.
        for i in stride(from: chunk.count - 1, through: 0, by: -1) { chunk.link(Int32(i)) }
    }

    // MARK: - Following changes

    /// Events are batched for this long. A second is fresh enough for search, and wakes the app
    /// a third as often as a shorter wait while folders churn.
    private static let eventLatency: CFTimeInterval = 1.0

    private func watch(_ roots: [String], since eventID: FSEventStreamEventId) {
        let library = URL.home.path + "/Library"
        let inLibrary = roots.filter { $0.hasPrefix(library + "/") }
        let outside = roots.filter { !$0.hasPrefix(library + "/") }
        for (group, excluded) in [(outside, [library]), (inLibrary, [])] where !group.isEmpty {
            guard let stream = makeStream(group, since: eventID) else { continue }
            if !excluded.isEmpty { FSEventStreamSetExclusionPaths(stream, excluded as CFArray) }
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
            streams.append(stream)
            streamEventIDs.append(eventID == FSEventStreamEventId(kFSEventStreamEventIdSinceNow) ? FSEventsGetCurrentEventId() : eventID)
            streamHeardAt.append(CFAbsoluteTimeGetCurrent())
            streamReplaying.append(eventID != FSEventStreamEventId(kFSEventStreamEventIdSinceNow))
        }
        noteCurrentEventID()
    }

    private func makeStream(_ roots: [String], since eventID: FSEventStreamEventId) -> FSEventStreamRef? {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { stream, info, count, paths, flags, ids in
            guard let info else { return }
            let index = Unmanaged<FileIndex>.fromOpaque(info).takeUnretainedValue()
            let cPaths = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            var changes: [(path: String, recursive: Bool)] = []
            var sized: [FolderSizeStore.Change] = []
            var latest: FSEventStreamEventId = 0
            for i in 0..<count {
                // Marks the end of the replay; not a change (and its ID isn't one to go by).
                if flags[i] & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) != 0 {
                    index.replayDone(stream)
                    continue
                }
                latest = max(latest, ids[i])
                var path = String(cString: cPaths[i])
                if path.count > 1 && path.hasSuffix("/") { path.removeLast() }
                let recursive = flags[i] & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0
                changes.append((path, recursive))
                sized.append((path, recursive, ids[i]))
            }
            index.received(through: latest, from: stream)
            index.apply(changes)
            FolderSizeStore.filesChanged(sized)
        }
        return FSEventStreamCreate(
            nil, callback, &context, roots as CFArray, eventID, Self.eventLatency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)
        )
    }

    /// Records how far a stream has got. The index reflects everything up to the stream that's
    /// furthest behind, so that's where the next launch replays from. Runs on `queue`.
    private func received(through eventID: FSEventStreamEventId, from stream: ConstFSEventStreamRef) {
        guard eventID > 0, let slot = streams.firstIndex(where: { UnsafeRawPointer($0) == UnsafeRawPointer(stream) }) else { return }
        streamEventIDs[slot] = max(streamEventIDs[slot], eventID)
        streamHeardAt[slot] = CFAbsoluteTimeGetCurrent()
        noteCurrentEventID()
        lastEventID = max(lastEventID, settledEventID())
    }

    private func replayDone(_ stream: ConstFSEventStreamRef) {
        guard let slot = streams.firstIndex(where: { UnsafeRawPointer($0) == UnsafeRawPointer(stream) }) else { return }
        streamReplaying[slot] = false
    }

    /// The event the index has heard everything before (see settledEventID). Waits for any
    /// change being handled, so every change before it has been passed on.
    func heardThrough() -> FSEventStreamEventId {
        queue.sync { settledEventID() }
    }

    private func noteCurrentEventID() {
        idSamples.append((CFAbsoluteTimeGetCurrent(), FSEventsGetCurrentEventId()))
        if idSamples.count > 64 { idSamples.removeFirst(idSamples.count - 32) }
    }

    /// How far every stream has got. A quiet stream (iCloud Drive with nothing syncing) hears
    /// nothing, but that doesn't mean it's behind: once it's been quiet well past its latency,
    /// anything from before then would have arrived, so it counts as caught up to the event
    /// current back then. Otherwise the next launch would replay everything since this one began.
    private func settledEventID() -> FSEventStreamEventId {
        let now = CFAbsoluteTimeGetCurrent()
        let margin = Self.eventLatency * 5
        noteCurrentEventID()
        let settled = idSamples.last { now - $0.time > margin }?.id
        var result: FSEventStreamEventId?
        for (slot, id) in streamEventIDs.enumerated() {
            var reached = id
            if let settled, !streamReplaying[slot], now - streamHeardAt[slot] > margin { reached = max(reached, settled) }
            result = min(result ?? reached, reached)
        }
        return result ?? 0
    }

    /// Brings the folders FSEvents reported up to date. Runs on `queue`.
    func apply(_ changes: [(path: String, recursive: Bool)]) {
        guard isReady else { return }
        var seen = Set<String>()
        var changed = false
        for change in changes where seen.insert(change.path).inserted {
            if Self.update(&working, folder: change.path, recursive: change.recursive) { changed = true }
        }
        guard changed else { return }
        if working.removedCount > max(20_000, working.count / 4) {
            working = working.compacted()
        }
        let published = working
        lock.withLock { storage = published }
        notifyChanged()
        scheduleSave()
    }

    /// The entry at `path`, if it's indexed.
    static func resolve(_ path: String, in storage: Storage) -> Int32? {
        let root = storage.roots
            .filter { let rootPath = storage.name($0); return path == rootPath || path.hasPrefix(rootPath == "/" ? "/" : rootPath + "/") }
            .max { storage.name($0).count < storage.name($1).count }
        guard let root else { return nil }
        let rootPath = storage.name(root)
        var current = root
        // Compared as bytes rather than by making a String of every sibling's name.
        for component in path.utf8.dropFirst(rootPath.utf8.count).split(separator: UInt8(ascii: "/")) {
            var child = storage.firstChild[Int(current)]
            while child >= 0 {
                let i = Int(child)
                let start = Int(storage.nameStart[i])
                if !storage.flags[i].contains(.removed), Int(storage.nameLength[i]) == component.count,
                   storage.names[start..<start + component.count].elementsEqual(component) {
                    break
                }
                child = storage.nextSibling[i]
            }
            guard child >= 0 else { return nil }
            current = child
        }
        return current
    }

    /// Re-reads one folder's contents into the index. Returns whether anything changed.
    @discardableResult
    static func update(_ storage: inout Storage, folder path: String, recursive: Bool) -> Bool {
        guard let index = resolve(path, in: storage) else {
            // A folder that's new to the index: refresh the nearest one that's known (which
            // does nothing if that one's contents aren't indexed, e.g. node_modules).
            var ancestor = path
            while true {
                let parent = (ancestor as NSString).deletingLastPathComponent
                guard parent != ancestor, !parent.isEmpty else { return false }
                if resolve(parent, in: storage) != nil { return update(&storage, folder: parent, recursive: false) }
                ancestor = parent
            }
        }
        let flags = storage.flags[Int(index)]
        guard flags.contains(.folder), !flags.contains(.pruned) else { return false }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue else {
            // The folder itself is gone.
            guard !flags.contains(.root) else { return false }
            let parent = storage.parent[Int(index)]
            storage.remove(index)
            if parent >= 0 { storage.relink(parent) }
            return true
        }

        var existing: [String: Int32] = [:]
        for child in storage.children(of: index) where !storage.flags[Int(child)].contains(.removed) {
            existing[storage.name(child)] = child
        }
        var changed = false
        for listed in shallowList(path) {
            if let child = existing.removeValue(forKey: listed.name) {
                let old = storage.flags[Int(child)]
                let sameKind = old.contains(.folder) == listed.flags.contains(.folder)
                    && old.contains(.pruned) == listed.flags.contains(.pruned)
                if sameKind {
                    if storage.times(child) != listed.times {
                        storage.modified[Int(child)] = listed.times.modified
                        storage.created[Int(child)] = listed.times.created
                        storage.changed[Int(child)] = listed.times.changed
                        changed = true
                    }
                    if recursive && listed.flags.contains(.folder) && !listed.flags.contains(.pruned) {
                        if update(&storage, folder: listed.path, recursive: true) { changed = true }
                    }
                    continue
                }
                storage.remove(child)
            }
            changed = true
            if listed.flags.contains(.folder) && !listed.flags.contains(.pruned) {
                var chunk = Storage()
                walk(listed.path, into: &chunk)
                storage.append(chunk, under: index)
            } else {
                storage.link(storage.add(name: listed.name, parent: index, flags: listed.flags, times: listed.times))
            }
        }
        for gone in existing.values {
            storage.remove(gone)
            changed = true
        }
        if changed { storage.relink(index) }
        return changed
    }
}

/// The index's state for the UI.
@MainActor
@Observable
final class IndexStatus {
    static let shared = IndexStatus()
    private(set) var itemCount = 0
    private(set) var isReady = false
    private(set) var buildDuration: TimeInterval = 0

    func update(itemCount: Int, buildDuration: TimeInterval) {
        self.itemCount = itemCount
        self.buildDuration = buildDuration
        isReady = true
    }
}
