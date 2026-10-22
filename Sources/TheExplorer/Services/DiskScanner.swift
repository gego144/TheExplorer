import Darwin
import Foundation

/// A node in a disk-usage tree. Built off the main thread, then only changed on the main thread.
///
/// A home folder scan is hundreds of thousands of folders, so nodes are kept small: a node holds
/// its name, not its path (that comes from its parents), and a folder's own files are one
/// "N files" node until the folder is opened (see DiskScanner.listFiles), rather than a node
/// for each of its largest files in every folder of the tree. That took a home scan from about
/// a gigabyte to a tenth of that.
final class SizeNode: Identifiable, @unchecked Sendable {
    enum Kind { case folder, file, otherFiles }

    let name: String
    /// Only the scan's root (and folders scanned on their own) keep a path.
    private let rootPath: String?
    let kind: Kind
    fileprivate(set) var size: Int64 = 0
    fileprivate(set) var fileCount: Int = 0
    fileprivate(set) var children: [SizeNode] = []
    fileprivate(set) var isReadable = true
    /// Whether the folder's own files are listed, or still one node for all of them.
    fileprivate(set) var filesListed = false
    fileprivate(set) weak var parent: SizeNode?

    var id: ObjectIdentifier { ObjectIdentifier(self) }
    var url: URL { URL(fileURLWithPath: path) }
    var isFolder: Bool { kind == .folder }

    /// Built from the parents; "other files" nodes share their folder's.
    var path: String {
        if let rootPath { return rootPath }
        guard let parent else { return name }
        let base = parent.path
        if kind == .otherFiles { return base }
        return base == "/" ? "/" + name : base + "/" + name
    }

    init(name: String, path: String? = nil, kind: Kind, size: Int64 = 0, fileCount: Int = 0) {
        self.name = name
        rootPath = path
        self.kind = kind
        self.size = size
        self.fileCount = fileCount
    }

    /// Removes this node from the tree and subtracts its size from every ancestor.
    func detachFromParent() {
        guard let parent else { return }
        parent.children.removeAll { $0 === self }
        var ancestor: SizeNode? = parent
        while let node = ancestor {
            node.size -= size
            node.fileCount -= fileCount
            ancestor = node.parent
        }
        self.parent = nil
    }

    /// Walks the folders in the tree (pre-order) with their paths and depth below this one,
    /// going into a folder only when `descend` says so.
    func forEachFolder(path: String? = nil, depth: Int = 0, descend: (SizeNode, Int) -> Bool = { _, _ in true },
                       _ body: (SizeNode, String, Int) -> Void) {
        guard kind == .folder else { return }
        let path = path ?? self.path
        body(self, path, depth)
        guard descend(self, depth) else { return }
        for child in children where child.kind == .folder {
            child.forEachFolder(path: path == "/" ? "/" + child.name : path + "/" + child.name, depth: depth + 1,
                                descend: descend, body)
        }
    }
}

struct LargeFile: Identifiable, Sendable {
    let path: String
    let size: Int64
    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var name: String { (path as NSString).lastPathComponent }
}

struct ScanResult: @unchecked Sendable {
    let root: SizeNode
    let largestFiles: [LargeFile]
    let unreadableFolders: Int
    let duration: TimeInterval
}

/// Thread-safe progress counters shared between scanning tasks and the UI.
final class ScanProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var _files = 0
    private var _bytes: Int64 = 0
    private var _currentPath = ""
    /// The root's folders and how much of each has been read, shown while the scan runs.
    private var folderNames: [String] = []
    private var folderBytes: [Int64] = []

    func begin(folders: [String]) {
        lock.withLock {
            folderNames = folders
            folderBytes = Array(repeating: 0, count: folders.count)
        }
    }

    func add(files: Int, bytes: Int64, path: String, top: Int = -1) {
        lock.lock()
        _files += files
        _bytes += bytes
        _currentPath = path
        if folderBytes.indices.contains(top) { folderBytes[top] += bytes }
        lock.unlock()
    }

    /// The root's folders, largest so far first.
    var folders: [(name: String, bytes: Int64)] {
        lock.withLock { zip(folderNames, folderBytes).map { ($0, $1) } }.sorted { $0.bytes > $1.bytes }
    }

    var snapshot: (files: Int, bytes: Int64, path: String) {
        lock.lock()
        defer { lock.unlock() }
        return (_files, _bytes, _currentPath)
    }
}

/// Fast recursive disk usage scanner built on fts(3). Sizes are allocated bytes on disk.
enum DiskScanner {
    /// Files kept per folder in the tree; the rest are rolled into a single "other files" node.
    static let filesPerFolder = 25
    static let largestFileCount = 200

    /// Paths never descended into: virtual filesystems and automount points that can hang.
    static let excludedPaths: Set<String> = ["/dev", "/net", "/home", "/Volumes", "/System/Volumes", "/private/var/vm"]

    /// Other apps' data. Without Full Disk Access, macOS asks before each app's container is
    /// read, and the read waits for an answer, so a scan would stop there behind a prompt
    /// nobody asked for. Without it they're skipped and counted as unreadable.
    static func protectedPaths() -> Set<String> {
        guard !StorageModel.checkFullDiskAccess() else { return [] }
        let library = URL.home.path + "/Library"
        return [library + "/Containers", library + "/Group Containers"]
    }

    /// Scans `root` on every core at once. Folders go into one shared queue, so a big folder
    /// is shared out across threads rather than walked by one while the rest sit idle, and
    /// each folder is read with getattrlistbulk, which returns many entries per call where a
    /// walk asks about each file on its own.
    static func scan(root: URL, progress: ScanProgress) async throws -> ScanResult {
        let start = Date()
        let rootPath = root.standardizedFileURL.path
        let queue = ScanQueue()
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: scanAll(rootPath: rootPath, queue: queue, progress: progress))
                }
            }
        } onCancel: {
            queue.cancel()
        }
        try Task.checkCancellation()
        return ScanResult(root: result.root, largestFiles: result.largest, unreadableFolders: result.unreadable,
                          duration: Date().timeIntervalSince(start))
    }

    private static func scanAll(rootPath: String, queue: ScanQueue, progress: ScanProgress)
        -> (root: SizeNode, largest: [LargeFile], unreadable: Int) {
        let rootNode = SizeNode(name: displayName(for: rootPath), path: rootPath, kind: .folder)
        rootNode.filesListed = true
        let skipped = protectedPaths()
        let hardLinks = HardLinks()
        var rootFiles = FileCollector(limit: filesPerFolder)
        var largest = FileCollector(limit: largestFileCount)
        var unreadable = 0
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: bulkBufferSize, alignment: 16)
        defer { buffer.deallocate() }

        // The root first, on its own: its files are listed one by one, and its folders are
        // the ones whose totals show while the scan runs.
        var folders: [ScanQueue.Job] = []
        let readable = readFolder(rootPath, buffer: buffer) { entry in
            if entry.isFolder {
                guard let job = subfolder(entry, of: rootNode, at: rootPath, top: folders.count, skipped: skipped,
                                          unreadable: &unreadable) else { return }
                folders.append(job)
            } else {
                guard entry.links <= 1 || hardLinks.isFirst(entry.fileID) else { return }
                let size = entry.size
                rootNode.size += size
                rootNode.fileCount += 1
                let path = { (rootPath == "/" ? "/" : rootPath + "/") + String(cString: entry.name) }
                rootFiles.add(size: size, path: path)
                largest.add(size: size, path: path)
            }
        }
        if !readable {
            rootNode.isReadable = false
            unreadable += 1
        }
        progress.begin(folders: folders.map(\.node.name))
        queue.push(folders)

        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: max(4, ProcessInfo.processInfo.activeProcessorCount)) { _ in
            var found = FileCollector(limit: largestFileCount)
            var cantRead = 0
            let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: bulkBufferSize, alignment: 16)
            defer { buffer.deallocate() }
            while let job = queue.next() {
                let subfolders = read(job, queue: queue, buffer: buffer, skipped: skipped, hardLinks: hardLinks,
                                      largest: &found, unreadable: &cantRead, progress: progress)
                queue.finished(subfolders)
            }
            lock.withLock {
                for file in found.items { largest.add(size: file.size) { file.path } }
                unreadable += cantRead
            }
        }

        addUp(rootNode)
        attachFiles(rootFiles, to: rootNode)
        rootNode.children.sort { $0.size > $1.size }
        return (rootNode, largest.finalized().items.map { LargeFile(path: $0.path, size: $0.size) }, unreadable)
    }

    /// Reads one folder: its files count toward it, its folders join the tree and are returned
    /// to be read in turn.
    private static func read(_ job: ScanQueue.Job, queue: ScanQueue, buffer: UnsafeMutableRawBufferPointer, skipped: Set<String>,
                             hardLinks: HardLinks, largest: inout FileCollector, unreadable: inout Int,
                             progress: ScanProgress) -> [ScanQueue.Job] {
        let node = job.node
        let path = job.path
        let top = job.top
        var subfolders: [ScanQueue.Job] = []
        var files = 0
        var bytes: Int64 = 0
        var cantRead = 0
        let readable = readFolder(path, buffer: buffer, stop: { queue.isCancelled }) { entry in
            if entry.isFolder {
                if let next = subfolder(entry, of: node, at: path, top: top, skipped: skipped, unreadable: &cantRead) {
                    subfolders.append(next)
                }
            } else {
                guard entry.links <= 1 || hardLinks.isFirst(entry.fileID) else { return }
                files += 1
                bytes += entry.size
                largest.add(size: entry.size) { path + "/" + String(cString: entry.name) }
            }
        }
        if !readable {
            node.isReadable = false
            node.filesListed = true
            cantRead += 1
        }
        unreadable += cantRead
        // Its own files for now; its subfolders are added once they're all read.
        node.size = bytes
        node.fileCount = files
        progress.add(files: files, bytes: bytes, path: path, top: top)
        return subfolders
    }

    /// A folder found in `parent`, added to the tree. Returns the job to read it, or nil when it
    /// isn't read: another volume, a virtual filesystem, or protected (then it's marked unreadable).
    private static func subfolder(_ entry: BulkEntry, of parent: SizeNode, at parentPath: String, top: Int,
                                  skipped: Set<String>, unreadable: inout Int) -> ScanQueue.Job? {
        guard !entry.isMountPoint else { return nil }
        let name = String(cString: entry.name)
        let path = parentPath == "/" ? "/" + name : parentPath + "/" + name
        guard !excludedPaths.contains(path) else { return nil }
        let node = SizeNode(name: name, kind: .folder)
        node.parent = parent
        parent.children.append(node)
        if skipped.contains(path) {
            node.isReadable = false
            node.filesListed = true
            unreadable += 1
            return nil
        }
        return ScanQueue.Job(node: node, path: path, top: top)
    }

    /// Once every folder is read: each folder's own files become one "N files" node, and its
    /// size and count take in its subfolders'. Children come before their parents in reverse
    /// pre-order, so one pass adds everything up.
    private static func addUp(_ root: SizeNode) {
        var order: [SizeNode] = []
        var stack = root.children.filter(\.isFolder)
        while let node = stack.popLast() {
            order.append(node)
            for child in node.children where child.kind == .folder { stack.append(child) }
        }
        for node in order.reversed() {
            // Its subfolders have added themselves in by now; what's left is its own files.
            var ownFiles = node.fileCount
            var ownBytes = node.size
            for child in node.children where child.kind == .folder {
                ownFiles -= child.fileCount
                ownBytes -= child.size
            }
            if ownFiles > 0 {
                let summary = SizeNode(name: filesTitle(ownFiles), kind: .otherFiles, size: ownBytes, fileCount: ownFiles)
                summary.parent = node
                node.children.append(summary)
            }
            node.children.sort { $0.size > $1.size }
            if let parent = node.parent {
                parent.size += node.size
                parent.fileCount += node.fileCount
            }
        }
    }

    /// A folder's own files, and its subfolders (to add up from their sizes).
    struct ShallowSize: Sendable {
        let path: String
        let bytes: Int64
        let files: Int
        let folders: [String]
        let complete: Bool
    }

    static func shallowSize(path: String) -> ShallowSize? {
        guard let dir = opendir(path) else { return nil }
        defer { closedir(dir) }
        let skipped = protectedPaths()
        var bytes: Int64 = 0
        var files = 0
        var folders: [String] = []
        var complete = true
        while let entry = readdir(dir) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name == "." || name == ".." { continue }
            let child = path == "/" ? "/" + name : path + "/" + name
            var st = stat()
            guard lstat(child, &st) == 0 else { continue }
            if (st.st_mode & S_IFMT) == S_IFDIR {
                if excludedPaths.contains(child) { continue }
                // Skipped the way a walk would skip them.
                if skipped.contains(child) {
                    complete = false
                    continue
                }
                folders.append(child)
            } else {
                bytes += Int64(st.st_blocks) * 512
                files += 1
            }
        }
        return ShallowSize(path: path, bytes: bytes, files: files, folders: folders, complete: complete)
    }

    /// Total allocated size and file count of a folder, without building a tree.
    static func folderSize(path: String) -> (bytes: Int64, files: Int, complete: Bool)? {
        var bytes: Int64 = 0
        var files = 0
        var complete = true
        var seenInodes = Set<HardLinkKey>()
        let ok = walk(path: path, skipping: protectedPaths()) { event in
            switch event {
            case .file(let st, _):
                if st.st_nlink > 1, !seenInodes.insert(HardLinkKey(st)).inserted { return true }
                bytes += Int64(st.st_blocks) * 512
                files += 1
            case .enterFolder, .exitFolder:
                break
            case .unreadable:
                complete = false
            }
            return !Task.isCancelled
        }
        return ok ? (bytes, files, complete) : nil
    }

    private static func attachFiles(_ collector: FileCollector, to node: SizeNode) {
        let (files, otherCount, otherSize) = collector.finalized()
        for file in files {
            let child = SizeNode(name: name(of: file.path), kind: .file, size: file.size, fileCount: 1)
            child.parent = node
            node.children.append(child)
        }
        if otherCount > 0 {
            let other = SizeNode(name: "\(otherCount.formatted()) smaller files", kind: .otherFiles, size: otherSize, fileCount: otherCount)
            other.parent = node
            node.children.append(other)
        }
    }

    /// The last path component as a native string: names of 15 bytes or less then take no
    /// memory of their own, where NSString's lastPathComponent keeps an object per name.
    private static func name(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/"), path.index(after: slash) < path.endIndex else { return path }
        return String(path[path.index(after: slash)...])
    }

    private static func filesTitle(_ count: Int) -> String {
        count == 1 ? "1 file" : "\(count.formatted()) files"
    }

    // MARK: - Files, when a folder is opened

    /// A folder's own files, largest first: read when the folder is opened in Storage (a
    /// listing, not a scan), since the tree only counts them.
    static func listFiles(in path: String) -> [(name: String, size: Int64)]? {
        guard let dir = opendir(path) else { return nil }
        defer { closedir(dir) }
        var files: [(name: String, size: Int64)] = []
        while let entry = readdir(dir) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name == "." || name == ".." { continue }
            var st = stat()
            guard lstat(path == "/" ? "/" + name : path + "/" + name, &st) == 0, (st.st_mode & S_IFMT) != S_IFDIR else { continue }
            files.append((name, Int64(st.st_blocks) * 512))
        }
        files.sort { $0.size > $1.size }
        return files
    }

    /// Swaps a folder's "N files" node for its largest files and one node for the rest. If
    /// the files changed since the scan, the folder's totals (and its parents') follow the
    /// listing.
    static func attachListedFiles(_ files: [(name: String, size: Int64)], to node: SizeNode) {
        guard !node.filesListed else { return }
        node.filesListed = true
        let summary = node.children.firstIndex(where: { $0.kind == .otherFiles }).map { node.children.remove(at: $0) }
        var listedSize: Int64 = 0
        for (index, file) in files.enumerated() {
            listedSize += file.size
            guard index < filesPerFolder else { continue }
            let child = SizeNode(name: file.name, kind: .file, size: file.size, fileCount: 1)
            child.parent = node
            node.children.append(child)
        }
        if files.count > filesPerFolder {
            let rest = files.dropFirst(filesPerFolder)
            let other = SizeNode(name: "\(rest.count.formatted()) smaller files", kind: .otherFiles,
                                 size: rest.reduce(0) { $0 + $1.size }, fileCount: rest.count)
            other.parent = node
            node.children.append(other)
        }
        let sizeChange = listedSize - (summary?.size ?? 0)
        let countChange = files.count - (summary?.fileCount ?? 0)
        if sizeChange != 0 || countChange != 0 {
            var ancestor: SizeNode? = node
            while let current = ancestor {
                current.size += sizeChange
                current.fileCount += countChange
                ancestor = current.parent
            }
        }
        node.children.sort { $0.size > $1.size }
    }

    // MARK: - fts walking

    private enum WalkEvent {
        case enterFolder(String)
        case exitFolder
        /// Stat buffer plus a lazy path accessor (only materialised when needed).
        case file(stat, () -> String)
        case unreadable(String)
    }

    /// Walks `path` with fts. The visitor returns false to stop early. Returns false if stopped.
    @discardableResult
    private static func walk(path: String, skipping skipped: Set<String> = [], visitor: (WalkEvent) -> Bool) -> Bool {
        guard let cPath = strdup(path) else { return false }
        defer { free(cPath) }
        var paths: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        // FTS_XDEV keeps us on one volume; this also skips the duplicate /System/Volumes/Data tree.
        guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return false }
        defer { fts_close(fts) }

        var openFolders: [Int] = [] // fts levels of folders we've emitted enterFolder for
        while let entry = fts_read(fts) {
            let ent = entry.pointee
            let level = Int(ent.fts_level)
            let keepGoing: Bool
            switch Int32(ent.fts_info) {
            case FTS_D:
                let folderPath = String(cString: ent.fts_path)
                if excludedPaths.contains(folderPath) {
                    fts_set(fts, entry, FTS_SKIP)
                    continue
                }
                if skipped.contains(folderPath) {
                    fts_set(fts, entry, FTS_SKIP)
                    keepGoing = visitor(.unreadable(folderPath))
                    if !keepGoing { return false }
                    continue
                }
                openFolders.append(level)
                keepGoing = visitor(.enterFolder(folderPath))
            case FTS_DP:
                guard openFolders.last == level else { continue }
                openFolders.removeLast()
                keepGoing = visitor(.exitFolder)
            case FTS_DNR, FTS_ERR:
                keepGoing = visitor(.unreadable(String(cString: ent.fts_path)))
            case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                guard let statp = ent.fts_statp else { continue }
                let pathPointer = ent.fts_path
                keepGoing = visitor(.file(statp.pointee, { String(cString: pathPointer!) }))
            default:
                continue
            }
            if !keepGoing { return false }
        }
        return true
    }

    private static func displayName(for path: String) -> String {
        if path == "/" {
            return FileManager.default.displayName(atPath: "/")
        }
        return (path as NSString).lastPathComponent
    }
}

/// Folders waiting to be read, shared by the scanning threads. Taken newest first, so the scan
/// goes deep before wide and the queue stays short.
private final class ScanQueue: @unchecked Sendable {
    struct Job {
        let node: SizeNode
        let path: String
        /// Which of the root's folders it's in, for the totals shown while scanning.
        let top: Int
    }

    private let condition = NSCondition()
    private var jobs: [Job] = []
    private var reading = 0
    private var cancelled = false

    func push(_ new: [Job]) {
        condition.withLock { jobs.append(contentsOf: new) }
        condition.broadcast()
    }

    /// The next folder to read, waiting while others are being read (they may find more).
    /// Nil once everything's read, or the scan is cancelled.
    func next() -> Job? {
        condition.lock()
        defer { condition.unlock() }
        while jobs.isEmpty && reading > 0 && !cancelled { condition.wait() }
        guard !cancelled, let job = jobs.popLast() else { return nil }
        reading += 1
        return job
    }

    func finished(_ subfolders: [Job]) {
        condition.lock()
        jobs.append(contentsOf: subfolders)
        reading -= 1
        let done = reading == 0 && jobs.isEmpty
        condition.unlock()
        if done || subfolders.count > 1 { condition.broadcast() } else if subfolders.count == 1 { condition.signal() }
    }

    func cancel() {
        condition.withLock { cancelled = true }
        condition.broadcast()
    }

    var isCancelled: Bool { condition.withLock { cancelled } }
}

/// Files with more than one hard link, so each is counted once. Rare, so one lock is plenty.
private final class HardLinks: @unchecked Sendable {
    private let lock = NSLock()
    private var seen = Set<UInt64>()

    func isFirst(_ fileID: UInt64) -> Bool {
        lock.withLock { seen.insert(fileID).inserted }
    }
}

/// One item in a folder, as getattrlistbulk returns it. `name` is only valid during the visit.
private struct BulkEntry {
    let name: UnsafePointer<CChar>
    let isFolder: Bool
    let isMountPoint: Bool
    let fileID: UInt64
    let links: UInt32
    /// Allocated bytes on disk; 0 for folders.
    let size: Int64
}

extension DiskScanner {
    fileprivate static let bulkBufferSize = 128 * 1024

    /// Reads a folder's entries in batches. Returns false if it can't be read.
    /// `stop` is asked between batches, so a folder of a hundred thousand files doesn't hold up Stop.
    fileprivate static func readFolder(_ path: String, buffer: UnsafeMutableRawBufferPointer, stop: () -> Bool = { false },
                                       _ visit: (BulkEntry) -> Void) -> Bool {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME)
            | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_FILEID) | attrgroup_t(ATTR_CMN_ERROR)
        request.dirattr = attrgroup_t(ATTR_DIR_MOUNTSTATUS)
        request.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT) | attrgroup_t(ATTR_FILE_ALLOCSIZE)
        var first = true
        while true {
            let count = getattrlistbulk(fd, &request, buffer.baseAddress, buffer.count, 0)
            if count < 0 && first { return false }
            guard count > 0, let base = buffer.baseAddress, first || !stop() else { return true }
            first = false
            var entry = base
            for _ in 0..<count {
                let length = Int(entry.load(as: UInt32.self))
                defer { entry += length }
                // Attributes follow in a fixed order, each only if returned.
                var field = entry + 4
                let returned = field.loadUnaligned(as: attribute_set_t.self)
                field += MemoryLayout<attribute_set_t>.size
                guard returned.commonattr & attrgroup_t(ATTR_CMN_NAME) != 0 else { continue }
                let reference = field.loadUnaligned(as: attrreference_t.self)
                let name = UnsafePointer((field + Int(reference.attr_dataoffset)).assumingMemoryBound(to: CChar.self))
                field += MemoryLayout<attrreference_t>.size
                var type = VNON.rawValue
                if returned.commonattr & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 {
                    type = field.loadUnaligned(as: fsobj_type_t.self)
                    field += MemoryLayout<fsobj_type_t>.size
                }
                var fileID: UInt64 = 0
                if returned.commonattr & attrgroup_t(ATTR_CMN_FILEID) != 0 {
                    fileID = field.loadUnaligned(as: UInt64.self)
                    field += 8
                }
                if returned.commonattr & attrgroup_t(ATTR_CMN_ERROR) != 0 { field += 4 }
                var isMountPoint = false
                if returned.dirattr & attrgroup_t(ATTR_DIR_MOUNTSTATUS) != 0 {
                    isMountPoint = field.loadUnaligned(as: UInt32.self) & UInt32(DIR_MNTSTATUS_MNTPOINT) != 0
                    field += 4
                }
                var links: UInt32 = 1
                if returned.fileattr & attrgroup_t(ATTR_FILE_LINKCOUNT) != 0 {
                    links = field.loadUnaligned(as: UInt32.self)
                    field += 4
                }
                var size: Int64 = 0
                if returned.fileattr & attrgroup_t(ATTR_FILE_ALLOCSIZE) != 0 {
                    size = field.loadUnaligned(as: Int64.self)
                }
                visit(BulkEntry(name: name, isFolder: type == VDIR.rawValue, isMountPoint: isMountPoint,
                                fileID: fileID, links: links, size: size))
            }
        }
    }
}

private struct HardLinkKey: Hashable {
    let device: Int32
    let inode: UInt64
    init(_ st: stat) {
        device = st.st_dev
        inode = st.st_ino
    }
}

/// Keeps the N largest files seen, without materialising paths for small files.
private struct FileCollector {
    let limit: Int
    private(set) var items: [(path: String, size: Int64)] = []
    private(set) var droppedCount = 0
    private(set) var droppedSize: Int64 = 0
    private var threshold: Int64 = -1

    init(limit: Int) {
        self.limit = limit
        items.reserveCapacity(limit)
    }

    mutating func add(size: Int64, path: () -> String) {
        guard size > threshold || items.count < limit else {
            droppedCount += 1
            droppedSize += size
            return
        }
        items.append((path(), size))
        if items.count >= limit * 2 { compact() }
    }

    private mutating func compact() {
        items.sort { $0.size > $1.size }
        guard items.count > limit else { return }
        for dropped in items[limit...] {
            droppedCount += 1
            droppedSize += dropped.size
        }
        items.removeSubrange(limit...)
        threshold = items.last?.size ?? -1
    }

    /// The kept files, largest first, plus totals for everything that didn't make the cut.
    func finalized() -> (items: [(path: String, size: Int64)], otherCount: Int, otherSize: Int64) {
        var copy = self
        copy.compact()
        return (copy.items, copy.droppedCount, copy.droppedSize)
    }
}
