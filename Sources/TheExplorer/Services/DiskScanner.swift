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

    func add(files: Int, bytes: Int64, path: String) {
        lock.lock()
        _files += files
        _bytes += bytes
        _currentPath = path
        lock.unlock()
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

    /// Scans `root`, fanning out across its top-level folders in parallel.
    static func scan(root: URL, progress: ScanProgress) async throws -> ScanResult {
        let start = Date()
        let rootPath = root.standardizedFileURL.path
        let rootNode = SizeNode(name: displayName(for: rootPath), path: rootPath, kind: .folder)
        rootNode.filesListed = true
        let skipped = protectedPaths()

        let entries = (try? FileManager.default.contentsOfDirectory(atPath: rootPath)) ?? []
        var folderPaths: [String] = []
        var rootFiles = FileCollector(limit: filesPerFolder)
        var largest = FileCollector(limit: largestFileCount)

        for name in entries {
            let path = rootPath == "/" ? "/" + name : rootPath + "/" + name
            if excludedPaths.contains(path) || skipped.contains(path) { continue }
            var st = stat()
            guard lstat(path, &st) == 0 else { continue }
            if (st.st_mode & S_IFMT) == S_IFDIR {
                folderPaths.append(path)
            } else {
                let size = Int64(st.st_blocks) * 512
                rootNode.size += size
                rootNode.fileCount += 1
                rootFiles.add(size: size) { path }
                largest.add(size: size) { path }
            }
        }

        var unreadable = 0
        try await withThrowingTaskGroup(of: SubtreeResult.self) { group in
            var pending = folderPaths[...]
            let width = max(4, ProcessInfo.processInfo.activeProcessorCount)
            func launchNext() {
                guard let path = pending.popFirst() else { return }
                group.addTask { try scanSubtree(path: path, skipping: skipped, progress: progress) }
            }
            for _ in 0..<width { launchNext() }
            while let result = try await group.next() {
                if let node = result.node {
                    node.parent = rootNode
                    rootNode.children.append(node)
                    rootNode.size += node.size
                    rootNode.fileCount += node.fileCount
                }
                unreadable += result.unreadable
                for file in result.largest { largest.add(size: file.size) { file.path } }
                launchNext()
            }
        }

        attachFiles(rootFiles, to: rootNode)
        rootNode.children.sort { $0.size > $1.size }

        return ScanResult(
            root: rootNode,
            largestFiles: largest.finalized().items.map { LargeFile(path: $0.path, size: $0.size) },
            unreadableFolders: unreadable,
            duration: Date().timeIntervalSince(start)
        )
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

    // MARK: - Subtree scanning

    private struct SubtreeResult: @unchecked Sendable {
        let node: SizeNode?
        let largest: [(path: String, size: Int64)]
        let unreadable: Int
    }

    private struct Frame {
        let node: SizeNode
        /// The folder's own files, which become one node until it's opened.
        var files = 0
        var bytes: Int64 = 0
    }

    private static func scanSubtree(path: String, skipping skipped: Set<String>, progress: ScanProgress) throws -> SubtreeResult {
        var stack: [Frame] = []
        var top: SizeNode?
        var largest = FileCollector(limit: largestFileCount)
        var unreadable = 0
        var seenInodes = Set<HardLinkKey>()
        var pendingFiles = 0
        var pendingBytes: Int64 = 0

        let finished = walk(path: path, skipping: skipped) { event in
            switch event {
            case .enterFolder(let folderPath):
                let node: SizeNode
                if let parent = stack.last?.node {
                    node = SizeNode(name: name(of: folderPath), kind: .folder)
                    node.parent = parent
                    parent.children.append(node)
                } else {
                    node = SizeNode(name: name(of: folderPath), path: folderPath, kind: .folder)
                    top = node
                }
                stack.append(Frame(node: node))

            case .exitFolder:
                guard let frame = stack.popLast() else { break }
                let node = frame.node
                if frame.files > 0 {
                    let summary = SizeNode(name: filesTitle(frame.files), kind: .otherFiles, size: frame.bytes, fileCount: frame.files)
                    summary.parent = node
                    node.children.append(summary)
                }
                node.children.sort { $0.size > $1.size }
                if let parent = stack.last?.node {
                    parent.size += node.size
                    parent.fileCount += node.fileCount
                }
                progress.add(files: pendingFiles, bytes: pendingBytes, path: node.path)
                pendingFiles = 0
                pendingBytes = 0

            case .file(let st, let pathProvider):
                if st.st_nlink > 1, !seenInodes.insert(HardLinkKey(st)).inserted { break }
                let size = Int64(st.st_blocks) * 512
                guard !stack.isEmpty else { break }
                stack[stack.count - 1].node.size += size
                stack[stack.count - 1].node.fileCount += 1
                stack[stack.count - 1].files += 1
                stack[stack.count - 1].bytes += size
                largest.add(size: size, path: pathProvider)
                pendingFiles += 1
                pendingBytes += size

            case .unreadable(let folderPath):
                unreadable += 1
                let node: SizeNode
                if let parent = stack.last?.node {
                    node = SizeNode(name: name(of: folderPath), kind: .folder)
                    node.parent = parent
                    parent.children.append(node)
                } else {
                    node = SizeNode(name: name(of: folderPath), path: folderPath, kind: .folder)
                    top = node
                }
                node.isReadable = false
                node.filesListed = true
            }
            return !Task.isCancelled
        }
        if !finished { try Task.checkCancellation() }
        progress.add(files: pendingFiles, bytes: pendingBytes, path: path)
        return SubtreeResult(node: top, largest: largest.items, unreadable: unreadable)
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
