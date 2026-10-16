import Compression
import Foundation

/// A zip's table of contents, read straight from its central directory at the end of the
/// file, so listing a multi-gigabyte archive only reads a few kilobytes. Single entries can
/// be unpacked for previewing.
struct ZipArchive: Sendable {
    struct Entry: Sendable {
        let path: String
        let isDirectory: Bool
        let size: Int64
        let compressedSize: Int64
        let method: UInt16
        let isEncrypted: Bool
        let localHeaderOffset: Int64
        /// MS-DOS date and time; decoded only when shown.
        let dosDateTime: UInt32

        var name: String { (path as NSString).lastPathComponent }

        var modified: Date? {
            let date = dosDateTime >> 16, time = dosDateTime & 0xFFFF
            var components = DateComponents()
            components.year = Int(date >> 9) + 1980
            components.month = Int((date >> 5) & 0xF)
            components.day = Int(date & 0x1F)
            components.hour = Int(time >> 11)
            components.minute = Int((time >> 5) & 0x3F)
            components.second = Int(time & 0x1F) * 2
            return Calendar.current.date(from: components)
        }
    }

    enum Failure: LocalizedError {
        case notZip, corrupt, encrypted, unsupportedMethod, tooLarge

        var errorDescription: String? {
            switch self {
            case .notZip: "This isn't a zip archive."
            case .corrupt: "The archive looks damaged."
            case .encrypted: "This file is password-protected."
            case .unsupportedMethod: "This file uses a compression method that can't be previewed."
            case .tooLarge: "This file is too large to preview from inside the archive."
            }
        }
    }

    /// Unpacking for a preview stops here; open the archive for anything bigger.
    static let maxExtractSize: Int64 = 512 << 20

    let url: URL
    let entries: [Entry]

    init(url: URL) throws {
        self.url = url
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let fileSize = Int64(try file.seekToEnd())
        guard fileSize >= 22 else { throw Failure.notZip }

        // The end-of-central-directory record sits in the last 22 bytes plus an optional comment.
        let tailLength = min(fileSize, 22 + 0xFFFF + 20)
        let tail = try Self.read(file, at: fileSize - tailLength, count: Int(tailLength))
        guard let end = stride(from: tail.count - 22, through: 0, by: -1).first(where: { tail.u32($0) == 0x0605_4B50 }) else {
            throw Failure.notZip
        }
        var count = UInt64(tail.u16(end + 10))
        var directorySize = UInt64(tail.u32(end + 12))
        var directoryOffset = UInt64(tail.u32(end + 16))

        // Zip64: the real values live in a second record that a locator just before this one points to.
        if count == 0xFFFF || directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF {
            guard end >= 20, tail.u32(end - 20) == 0x0706_4B50 else { throw Failure.corrupt }
            let record = try Self.read(file, at: Int64(tail.u64(end - 20 + 8)), count: 56)
            guard record.count == 56, record.u32(0) == 0x0606_4B50 else { throw Failure.corrupt }
            count = record.u64(32)
            directorySize = record.u64(40)
            directoryOffset = record.u64(48)
        }
        guard directorySize <= 512 << 20, Int64(directoryOffset + directorySize) <= fileSize else { throw Failure.corrupt }

        let directory = try Self.read(file, at: Int64(directoryOffset), count: Int(directorySize))
        var entries: [Entry] = []
        entries.reserveCapacity(Int(min(count, 1_000_000)))
        var p = 0
        while p + 46 <= directory.count, directory.u32(p) == 0x0201_4B50 {
            let flags = directory.u16(p + 8)
            let nameLength = Int(directory.u16(p + 28))
            let extraLength = Int(directory.u16(p + 30))
            let commentLength = Int(directory.u16(p + 32))
            guard p + 46 + nameLength + extraLength <= directory.count else { throw Failure.corrupt }
            var size = UInt64(directory.u32(p + 24))
            var compressedSize = UInt64(directory.u32(p + 20))
            var offset = UInt64(directory.u32(p + 42))

            // Zip64 extra field: 64-bit values for whichever fields overflowed, in this order.
            var extra = p + 46 + nameLength
            let extraEnd = extra + extraLength
            while extra + 4 <= extraEnd {
                let id = directory.u16(extra), length = Int(directory.u16(extra + 2))
                if id == 0x0001 {
                    var field = extra + 4
                    if size == 0xFFFF_FFFF, field + 8 <= extraEnd { size = directory.u64(field); field += 8 }
                    if compressedSize == 0xFFFF_FFFF, field + 8 <= extraEnd { compressedSize = directory.u64(field); field += 8 }
                    if offset == 0xFFFF_FFFF, field + 8 <= extraEnd { offset = directory.u64(field) }
                }
                extra += 4 + length
            }

            let nameBytes = directory.bytes[(p + 46)..<(p + 46 + nameLength)]
            // Names are UTF-8 in practice (flag bit 11 or not); very old archives fall back to Latin-1.
            let rawName = String(bytes: nameBytes, encoding: .utf8) ?? String(bytes: nameBytes, encoding: .isoLatin1) ?? ""
            let path = rawName.replacingOccurrences(of: "\\", with: "/")
            entries.append(Entry(
                path: path,
                isDirectory: path.hasSuffix("/"),
                size: Int64(size),
                compressedSize: Int64(compressedSize),
                method: directory.u16(p + 10),
                isEncrypted: flags & 1 != 0,
                localHeaderOffset: Int64(offset),
                dosDateTime: UInt32(directory.u16(p + 14)) << 16 | UInt32(directory.u16(p + 12))
            ))
            p += 46 + nameLength + extraLength + commentLength
        }
        self.entries = entries
    }

    /// Unpacks one entry to `destination`.
    func extract(_ entry: Entry, to destination: URL) throws {
        guard !entry.isEncrypted else { throw Failure.encrypted }
        guard entry.method == 0 || entry.method == 8 else { throw Failure.unsupportedMethod }
        guard entry.size <= Self.maxExtractSize, entry.compressedSize <= Self.maxExtractSize else { throw Failure.tooLarge }

        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let header = try Self.read(file, at: entry.localHeaderOffset, count: 30)
        guard header.count == 30, header.u32(0) == 0x0403_4B50 else { throw Failure.corrupt }
        let dataOffset = entry.localHeaderOffset + 30 + Int64(header.u16(26)) + Int64(header.u16(28))
        try file.seek(toOffset: UInt64(dataOffset))
        let compressed = try file.read(upToCount: Int(entry.compressedSize)) ?? Data()
        guard compressed.count == Int(entry.compressedSize) else { throw Failure.corrupt }

        let contents: Data
        if entry.method == 0 || entry.size == 0 {
            contents = compressed
        } else {
            // Method 8 is raw DEFLATE, which is what Compression's ZLIB algorithm decodes.
            var output = Data(count: Int(entry.size))
            let written = output.withUnsafeMutableBytes { out in
                compressed.withUnsafeBytes { input in
                    compression_decode_buffer(
                        out.bindMemory(to: UInt8.self).baseAddress!, Int(entry.size),
                        input.bindMemory(to: UInt8.self).baseAddress!, compressed.count,
                        nil, COMPRESSION_ZLIB
                    )
                }
            }
            guard written == Int(entry.size) else { throw Failure.corrupt }
            contents = output
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: destination)
    }

    private static func read(_ file: FileHandle, at offset: Int64, count: Int) throws -> Bytes {
        try file.seek(toOffset: UInt64(offset))
        return Bytes(bytes: [UInt8](try file.read(upToCount: count) ?? Data()))
    }
}

/// Little-endian reads; out-of-range reads return 0 so a truncated file fails a signature check
/// instead of crashing.
private struct Bytes {
    let bytes: [UInt8]
    var count: Int { bytes.count }

    func u16(_ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= bytes.count else { return 0 }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    func u32(_ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= bytes.count else { return 0 }
        return UInt32(u16(offset)) | UInt32(u16(offset + 2)) << 16
    }

    func u64(_ offset: Int) -> UInt64 {
        guard offset >= 0, offset + 8 <= bytes.count else { return 0 }
        return UInt64(u32(offset)) | UInt64(u32(offset + 4)) << 32
    }
}

/// An archive's entries as a folder tree with rolled-up sizes, for display.
struct ArchiveTree: Sendable {
    struct Node: Sendable, Identifiable {
        let path: String
        let name: String
        let isDirectory: Bool
        let size: Int64
        let fileCount: Int
        /// Index into `ZipArchive.entries`; nil for folders implied only by their contents.
        let entry: Int?
        let children: [Node]

        var id: String { path }
    }

    let roots: [Node]
    let fileCount: Int
    let totalSize: Int64

    init(_ archive: ZipArchive) {
        final class Builder {
            var name: String
            var path: String
            var isDirectory: Bool
            var entry: Int?
            var children: [String: Builder] = [:]
            init(name: String, path: String, isDirectory: Bool) {
                self.name = name
                self.path = path
                self.isDirectory = isDirectory
            }
        }
        let root = Builder(name: "", path: "", isDirectory: true)
        var sizes: [Int: Int64] = [:]
        for (index, entry) in archive.entries.enumerated() {
            let parts = entry.path.split(separator: "/", omittingEmptySubsequences: true)
            // Finder's resource-fork copies and folder metadata aren't part of the contents.
            guard let first = parts.first, first != "__MACOSX", parts.last != ".DS_Store" else { continue }
            var node = root
            for (depth, part) in parts.enumerated() {
                let isLast = depth == parts.count - 1
                let key = String(part)
                if let next = node.children[key] {
                    node = next
                } else {
                    let path = node.path.isEmpty ? key : node.path + "/" + key
                    let next = Builder(name: key, path: path, isDirectory: !isLast || entry.isDirectory)
                    node.children[key] = next
                    node = next
                }
            }
            node.entry = index
            if !entry.isDirectory { sizes[index] = entry.size }
        }

        func freeze(_ builder: Builder) -> Node {
            let children = builder.children.values.map(freeze).sorted {
                $0.isDirectory != $1.isDirectory ? $0.isDirectory : $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            let isFile = !builder.isDirectory
            return Node(
                path: builder.path,
                name: builder.name,
                isDirectory: builder.isDirectory,
                size: isFile ? (builder.entry.flatMap { sizes[$0] } ?? 0) : children.reduce(0) { $0 + $1.size },
                fileCount: isFile ? 1 : children.reduce(0) { $0 + $1.fileCount },
                entry: builder.entry,
                children: children
            )
        }
        let top = freeze(root)
        roots = top.children
        fileCount = top.fileCount
        totalSize = top.size
    }
}
