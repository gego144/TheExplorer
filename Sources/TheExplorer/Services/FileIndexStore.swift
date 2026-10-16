import CoreServices
import Foundation

/// Saves the search index between launches, so opening the app loads it in milliseconds instead
/// of walking the disk again. Alongside it goes the FSEvents event ID it's current to; on the
/// next launch FSEvents replays everything that changed since, and only those folders are
/// re-read. The event IDs belong to the disk's FSEvents history, so the history's UUID is saved
/// too: if it changed (the history was reset), the saved index is used for now and rebuilt in
/// the background.
enum FileIndexStore {
    struct Saved {
        let storage: FileIndex.Storage
        let roots: [String]
        let eventID: FSEventStreamEventId
        let historyID: String?
    }

    private static let magic: UInt32 = 0x5854_4958 // "XIXT"
    /// Bumped whenever what gets indexed changes, so older saved indexes are rebuilt.
    private static let version: UInt32 = 2

    static var defaultURL: URL {
        #if DEBUG
        // Scripted runs and tests use their own file so they never touch yours.
        if let path = ProcessInfo.processInfo.environment["EXPLORER_INDEX_FILE"] {
            return URL(fileURLWithPath: path)
        }
        #endif
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TheExplorer", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("search-index.bin")
    }

    /// The FSEvents history ID of the disk holding `path`.
    static func historyID(for path: String) -> String? {
        var st = stat()
        guard stat(path, &st) == 0, let uuid = FSEventsCopyUUIDForDevice(st.st_dev) else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    // MARK: Writing

    static func save(_ storage: FileIndex.Storage, roots: [String], eventID: FSEventStreamEventId, historyID: String?, to url: URL) throws {
        // Removed entries aren't worth keeping, and child links are rebuilt on load.
        let storage = storage.removedCount > 0 ? storage.compacted() : storage
        var data = Data()
        data.reserveCapacity(storage.names.count + storage.count * 16 + 4096)
        append(magic, to: &data)
        append(version, to: &data)
        append(eventID, to: &data)
        appendString(historyID ?? "", to: &data)
        append(UInt32(roots.count), to: &data)
        roots.forEach { appendString($0, to: &data) }
        append(UInt32(storage.count), to: &data)
        append(UInt32(storage.names.count), to: &data)
        appendArray(storage.parent, to: &data)
        appendArray(storage.nameStart, to: &data)
        appendArray(storage.nameLength, to: &data)
        appendArray(storage.flags.map(\.rawValue), to: &data)
        appendArray(storage.modified, to: &data)
        appendArray(storage.names, to: &data)
        append(UInt32(storage.roots.count), to: &data)
        appendArray(storage.roots, to: &data)
        append(UInt32(storage.folded.count), to: &data)
        for (index, bytes) in storage.folded {
            append(index, to: &data)
            append(UInt32(bytes.count), to: &data)
            appendArray(bytes, to: &data)
        }
        try data.write(to: url, options: .atomic)
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
    }

    private static func appendArray<T: FixedWidthInteger>(_ values: [T], to data: inout Data) {
        values.withUnsafeBytes { data.append(contentsOf: $0) }
    }

    private static func appendString(_ string: String, to data: inout Data) {
        let bytes = Array(string.utf8)
        append(UInt32(bytes.count), to: &data)
        data.append(contentsOf: bytes)
    }

    // MARK: Reading

    /// The saved index, or nil if there isn't one or it can't be read.
    static func load(from url: URL) -> Saved? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        var reader = Reader(data: data)
        guard reader.read(UInt32.self) == magic, reader.read(UInt32.self) == version,
              let eventID = reader.read(UInt64.self),
              let historyID = reader.readString(),
              let rootCount = reader.read(UInt32.self) else { return nil }
        var roots: [String] = []
        for _ in 0..<rootCount {
            guard let root = reader.readString() else { return nil }
            roots.append(root)
        }
        guard let count = reader.read(UInt32.self).map(Int.init), let nameBytes = reader.read(UInt32.self).map(Int.init),
              let parent = reader.readArray(Int32.self, count: count),
              let nameStart = reader.readArray(UInt32.self, count: count),
              let nameLength = reader.readArray(UInt16.self, count: count),
              let flags = reader.readArray(UInt8.self, count: count),
              let modified = reader.readArray(Int32.self, count: count),
              let names = reader.readArray(UInt8.self, count: nameBytes),
              let rootIndexCount = reader.read(UInt32.self).map(Int.init),
              let rootIndices = reader.readArray(Int32.self, count: rootIndexCount),
              let foldedCount = reader.read(UInt32.self) else { return nil }
        var folded: [Int32: [UInt8]] = [:]
        folded.reserveCapacity(Int(foldedCount))
        for _ in 0..<foldedCount {
            guard let index = reader.read(Int32.self), let length = reader.read(UInt32.self),
                  let bytes = reader.readArray(UInt8.self, count: Int(length)) else { return nil }
            folded[index] = bytes
        }

        // Sanity: parents before children, names inside the buffer, roots in range.
        for i in 0..<count {
            let parentIndex = parent[i]
            guard parentIndex < Int32(i), Int(nameStart[i]) + Int(nameLength[i]) <= names.count else { return nil }
        }
        guard rootIndices.allSatisfy({ $0 >= 0 && Int($0) < count }) else { return nil }

        var storage = FileIndex.Storage()
        storage.parent = parent
        storage.nameStart = nameStart
        storage.nameLength = nameLength
        storage.flags = flags.map(FileIndex.Flags.init(rawValue:))
        storage.modified = modified
        storage.names = names
        storage.folded = folded
        storage.roots = rootIndices
        storage.firstChild = [Int32](repeating: -1, count: count)
        storage.nextSibling = [Int32](repeating: -1, count: count)
        for i in stride(from: count - 1, through: 0, by: -1) { storage.link(Int32(i)) }
        return Saved(storage: storage, roots: roots, eventID: eventID, historyID: historyID.isEmpty ? nil : historyID)
    }

    private struct Reader {
        let data: Data
        var offset = 0

        mutating func read<T: FixedWidthInteger>(_: T.Type) -> T? {
            let size = MemoryLayout<T>.size
            guard offset + size <= data.count else { return nil }
            var value: T = 0
            _ = withUnsafeMutableBytes(of: &value) { data.copyBytes(to: $0, from: data.startIndex + offset..<data.startIndex + offset + size) }
            offset += size
            return value
        }

        mutating func readArray<T: FixedWidthInteger>(_: T.Type, count: Int) -> [T]? {
            let size = MemoryLayout<T>.stride * count
            guard count >= 0, offset + size <= data.count else { return nil }
            let values = [T](unsafeUninitializedCapacity: count) { buffer, initialized in
                data.copyBytes(to: UnsafeMutableRawBufferPointer(buffer), from: data.startIndex + offset..<data.startIndex + offset + size)
                initialized = count
            }
            offset += size
            return values
        }

        mutating func readString() -> String? {
            guard let length = read(UInt32.self), let bytes = readArray(UInt8.self, count: Int(length)) else { return nil }
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}
