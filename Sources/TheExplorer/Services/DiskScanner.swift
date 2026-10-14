import Darwin
import Foundation

/// A node in a disk-usage tree. Built off the main thread, then treated as read-only.
final class SizeNode: Identifiable, @unchecked Sendable {
    enum Kind { case folder, file, otherFiles }

    let name: String
    let path: String
    let kind: Kind
    fileprivate(set) var size: Int64 = 0
    fileprivate(set) var fileCount: Int = 0
    fileprivate(set) var children: [SizeNode] = []
    fileprivate(set) var isReadable = true
    fileprivate(set) weak var parent: SizeNode?

    var id: ObjectIdentifier { ObjectIdentifier(self) }
    var url: URL { URL(fileURLWithPath: path) }
    var isFolder: Bool { kind == .folder }

    init(name: String, path: String, kind: Kind, size: Int64 = 0, fileCount: Int = 0) {
        self.name = name
        self.path = path
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

    /// Walks every folder in the tree (pre-order).
    func forEachFolder(_ body: (SizeNode) -> Void) {
        guard kind == .folder else { return }
        body(self)
        for child in children where child.kind == .folder {
            child.forEachFolder(body)
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

    /// Scans `root`, fanning out across its top-level folders in parallel.
    static func scan(root: URL, progress: ScanProgress) async throws -> ScanResult {
        let start = Date()
        let rootPath = root.standardizedFileURL.path
        let rootNode = SizeNode(name: displayName(for: rootPath), path: rootPath, kind: .folder)

        let entries = (try? FileManager.default.contentsOfDirectory(atPath: rootPath)) ?? []
        var folderPaths: [String] = []
        var rootFiles = FileCollector(limit: filesPerFolder)
        var largest = FileCollector(limit: largestFileCount)

        for name in entries {
            let path = rootPath == "/" ? "/" + name : rootPath + "/" + name
            if excludedPaths.contains(path) { continue }
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
                group.addTask { try scanSubtree(path: path, progress: progress) }
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

    /// Total allocated size and file count of a folder, without building a tree.
    static func folderSize(path: String) -> (bytes: Int64, files: Int, complete: Bool)? {
        var bytes: Int64 = 0
        var files = 0
        var complete = true
        var seenInodes = Set<HardLinkKey>()
        let ok = walk(path: path) { event in
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
        var files: FileCollector
    }

    private static func scanSubtree(path: String, progress: ScanProgress) throws -> SubtreeResult {
        var stack: [Frame] = []
        var top: SizeNode?
        var largest = FileCollector(limit: largestFileCount)
        var unreadable = 0
        var seenInodes = Set<HardLinkKey>()
        var pendingFiles = 0
        var pendingBytes: Int64 = 0

        let finished = walk(path: path) { event in
            switch event {
            case .enterFolder(let folderPath):
                let node = SizeNode(name: (folderPath as NSString).lastPathComponent, path: folderPath, kind: .folder)
                if let parent = stack.last?.node {
                    node.parent = parent
                    parent.children.append(node)
                } else {
                    top = node
                }
                stack.append(Frame(node: node, files: FileCollector(limit: filesPerFolder)))

            case .exitFolder:
                guard let frame = stack.popLast() else { break }
                let node = frame.node
                attachFiles(frame.files, to: node)
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
                stack[stack.count - 1].files.add(size: size, path: pathProvider)
                largest.add(size: size, path: pathProvider)
                pendingFiles += 1
                pendingBytes += size

            case .unreadable(let folderPath):
                unreadable += 1
                let node = SizeNode(name: (folderPath as NSString).lastPathComponent, path: folderPath, kind: .folder)
                node.isReadable = false
                if let parent = stack.last?.node {
                    node.parent = parent
                    parent.children.append(node)
                } else {
                    top = node
                }
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
            let child = SizeNode(name: (file.path as NSString).lastPathComponent, path: file.path, kind: .file, size: file.size, fileCount: 1)
            child.parent = node
            node.children.append(child)
        }
        if otherCount > 0 {
            let other = SizeNode(name: "\(otherCount.formatted()) smaller files", path: node.path, kind: .otherFiles, size: otherSize, fileCount: otherCount)
            other.parent = node
            node.children.append(other)
        }
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
    private static func walk(path: String, visitor: (WalkEvent) -> Bool) -> Bool {
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
