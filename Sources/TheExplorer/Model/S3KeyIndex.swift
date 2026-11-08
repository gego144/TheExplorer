import Foundation
import Observation
import UniformTypeIdentifiers

/// Every key in a bucket (or under a folder in one), read from S3 once, a thousand at a time,
/// and kept so Find can search them on the Mac. S3 has no search: without this, every
/// keystroke would list the bucket again from the start (1,500 requests for 1.5 million keys).
///
/// Keys are kept compactly (one byte buffer per page), about 75 bytes a key with its size and
/// date, so a bucket of 1.5 million keys takes about 110 MB while it's searched.
@MainActor
@Observable
final class S3KeyIndex {
    let connectionID: UUID
    let bucket: String
    let prefix: String
    private(set) var pages: [S3KeyPage] = []
    private(set) var count = 0
    private(set) var isComplete = false
    private(set) var error: String?
    /// When it was last read into or searched; one idle for ten minutes is let go.
    @ObservationIgnored private(set) var lastUsed = Date()
    @ObservationIgnored private var task: Task<Void, Never>?

    init(connectionID: UUID, bucket: String, prefix: String) {
        self.connectionID = connectionID
        self.bucket = bucket
        self.prefix = prefix
    }

    /// Whether this index has every key a search under `prefix` in `bucket` needs.
    func covers(bucket: String, prefix: String) -> Bool {
        self.bucket == bucket && prefix.hasPrefix(self.prefix)
    }

    /// How many ranges of keys are read at once.
    static let parallelReads = 16

    /// A stretch of keys one reader lists: those after `after` up to and including `upTo` (nil:
    /// from the start, to the end). Another reader can take the rest of it over by lowering
    /// `upTo`, which is how eight readers share a bucket whatever shape its keys are.
    private final class Span {
        var after: String?
        var upTo: String?
        /// The last key read.
        var position: String?
        var started = false
        /// Pages read from it, and whether the last was full with more to come: only a range shown
        /// to hold many keys is split, so readers don't carve up empty stretches forever.
        var pages = 0
        var more = false

        init(after: String?, upTo: String?) {
            self.after = after
            self.upTo = upTo
        }
    }

    @ObservationIgnored private var spans: [Span] = []

    fileprivate func start(_ client: S3Client) {
        guard task == nil else { return }
        spans = [Span(after: nil, upTo: nil)]
        task = Task { [weak self, bucket, prefix] in
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for _ in 0..<Self.parallelReads {
                        group.addTask { [weak self] in
                            while let span = await self?.nextSpan() {
                                var token: String?
                                var first = true
                                while true {
                                    let listing = try await Self.page(client, bucket: bucket, prefix: prefix, token: token,
                                                                      startAfter: first ? span.after : nil)
                                    try Task.checkCancellation()
                                    first = false
                                    guard let self, await self.take(listing, into: span) else { break }
                                    token = listing.nextToken
                                }
                                await self?.finish(span)
                            }
                        }
                    }
                    try await group.waitForAll()
                }
                self?.isComplete = true
            } catch {
                guard let self, !(error is CancellationError) else { return }
                #if DEBUG
                FileHandle.standardError.write(Data("[snapshot] s3 index \(bucket) failed after \(self.count) keys: \(error)\n".utf8))
                #endif
                self.error = error.localizedDescription
                self.isComplete = true
            }
        }
    }

    /// One page, tried again a few times: over a read of thousands of pages, S3 now and then
    /// asks to slow down or a request drops, and that shouldn't throw away minutes of reading.
    private nonisolated static func page(_ client: S3Client, bucket: String, prefix: String, token: String?,
                                         startAfter: String?) async throws -> S3Listing {
        var attempt = 0
        while true {
            do {
                return try await client.list(bucket: bucket, prefix: prefix, delimiter: nil, token: token, startAfter: startAfter)
            } catch {
                attempt += 1
                guard attempt < 4, !(error is CancellationError), !Task.isCancelled else { throw error }
                #if DEBUG
                FileHandle.standardError.write(Data("[snapshot] s3 index \(bucket) retrying a page (\(attempt)): \(error)\n".utf8))
                #endif
                try await Task.sleep(for: .milliseconds(400 << attempt))
            }
        }
    }

    /// The next range for a reader, waiting while every range being read is too small (so far)
    /// to share; nil once everything has been read.
    private func nextSpan() async -> Span? {
        while !Task.isCancelled {
            if let span = claim() { return span }
            if spans.isEmpty { return nil }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return nil
    }

    /// A range for a reader: the first one, or the second half of what's left of the widest
    /// range shown to hold many keys.
    private func claim() -> Span? {
        if let fresh = spans.first(where: { !$0.started }) {
            fresh.started = true
            return fresh
        }
        let end = prefix + "\u{7F}"
        let widest = spans
            .filter { $0.pages >= 1 && $0.more }
            .map { span -> (Span, String, Int) in
                let low = span.position ?? span.after ?? prefix
                return (span, low, Self.width(low, span.upTo ?? end))
            }
            .max { $0.2 < $1.2 }
        guard let (span, low, width) = widest, width > 1,
              let middle = Self.midpoint(low, span.upTo ?? end) else { return nil }
        let taken = Span(after: middle, upTo: span.upTo)
        taken.started = true
        span.upTo = middle
        spans.append(taken)
        return taken
    }

    /// Adds a page's keys that fall in the range; false once the range is done.
    private func take(_ listing: S3Listing, into span: Span) -> Bool {
        var objects = listing.objects
        var passed = false
        if let upTo = span.upTo, let cut = objects.firstIndex(where: { $0.key > upTo }) {
            objects.removeSubrange(cut...)
            passed = true
        }
        add(S3KeyPage(objects))
        if let last = objects.last?.key { span.position = last }
        span.pages += 1
        span.more = !passed && listing.nextToken != nil && listing.objects.count >= 1000
        return !passed && listing.nextToken != nil
    }

    private func finish(_ span: Span) {
        spans.removeAll { $0 === span }
    }

    /// The bytes after two keys' shared start, read as a number (four places of the printable
    /// characters), to compare ranges' widths and find their middles.
    private nonisolated static let base = 96
    private nonisolated static let places = 4

    private nonisolated static func digits(_ low: String, _ high: String) -> (shared: [UInt8], low: Int, high: Int) {
        let a = Array(low.utf8), b = Array(high.utf8)
        var shared = 0
        while shared < a.count, shared < b.count, a[shared] == b[shared] { shared += 1 }
        func value(_ bytes: [UInt8]) -> Int {
            (0..<places).reduce(0) { total, place in
                let index = shared + place
                let digit = index < bytes.count ? min(max(Int(bytes[index]) - 0x20, 0), base - 1) : 0
                return total * base + digit
            }
        }
        return (Array(a.prefix(shared)), value(a), value(b))
    }

    nonisolated static func width(_ low: String, _ high: String) -> Int {
        let (_, low, high) = digits(low, high)
        return high - low
    }

    /// A key between `low` and `high` (in byte order), to split a range there.
    nonisolated static func midpoint(_ low: String, _ high: String) -> String? {
        let (shared, lowValue, highValue) = digits(low, high)
        guard highValue - lowValue > 1 else { return nil }
        var middle = (lowValue + highValue) / 2
        var bytes = [UInt8](repeating: 0x20, count: places)
        for place in (0..<places).reversed() {
            bytes[place] = UInt8(0x20 + middle % base)
            middle /= base
        }
        while bytes.count > 1, bytes.last == 0x20 { bytes.removeLast() }
        let result = String(decoding: shared + bytes, as: UTF8.self)
        return result > low && result < high ? result : nil
    }

    /// A search is using it (searches call this as they go, so a long one never loses it).
    func touch() { lastUsed = Date() }

    private func add(_ page: S3KeyPage) {
        lastUsed = Date()
        guard page.count > 0 else { return }
        pages.append(page)
        count += page.count
    }

    fileprivate func stop() {
        task?.cancel()
        task = nil
    }
}

/// One page of keys: their bytes end to end, where each ends, and their sizes and dates.
struct S3KeyPage: Sendable {
    let bytes: [UInt8]
    let ends: [UInt32]
    let sizes: [Int64]
    /// Seconds since 1970; 0 when S3 didn't say.
    let modified: [UInt32]

    var count: Int { ends.count }

    init(_ objects: [S3Object]) {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(objects.count * 64)
        var ends: [UInt32] = []
        ends.reserveCapacity(objects.count)
        for object in objects {
            bytes.append(contentsOf: object.key.utf8)
            ends.append(UInt32(bytes.count))
        }
        self.bytes = bytes
        self.ends = ends
        sizes = objects.map(\.size)
        modified = objects.map { UInt32(max(0, min(Double(UInt32.max), $0.modified?.timeIntervalSince1970 ?? 0))) }
    }

    func key(_ index: Int) -> String {
        let start = index == 0 ? 0 : Int(ends[index - 1])
        return String(decoding: bytes[start..<Int(ends[index])], as: UTF8.self)
    }
}

/// The indexes Find has read, shared by every pane: searching a bucket again (or a folder in it)
/// reuses what was read. One unused for ten minutes is let go, and so is one whose bucket changed.
@MainActor
final class S3IndexStore {
    static let shared = S3IndexStore()
    private var indexes: [S3KeyIndex] = []
    private var observer: NSObjectProtocol?
    static let idleLimit: TimeInterval = 600

    private init() {
        observer = NotificationCenter.default.addObserver(forName: .s3Changed, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let changed = note.object as? S3Location, let bucket = changed.bucket else { return }
                self?.drop { $0.connectionID == changed.connectionID && $0.bucket == bucket }
            }
        }
    }

    /// The index to search `bucket` under `prefix`: one already read (or being read) that covers
    /// it, or a new one, started now.
    func index(connectionID: UUID, bucket: String, prefix: String, client: S3Client) -> S3KeyIndex {
        drop { Date().timeIntervalSince($0.lastUsed) > Self.idleLimit }
        if let index = indexes.first(where: { $0.connectionID == connectionID && $0.covers(bucket: bucket, prefix: prefix) && $0.error == nil }) {
            index.touch()
            return index
        }
        let index = S3KeyIndex(connectionID: connectionID, bucket: bucket, prefix: prefix)
        indexes.append(index)
        index.start(client)
        return index
    }

    private func drop(where shouldDrop: (S3KeyIndex) -> Bool) {
        for index in indexes where shouldDrop(index) { index.stop() }
        indexes.removeAll(where: shouldDrop)
    }
}

/// Matching keys against what's typed, off the main thread.
enum S3KeyMatcher {
    /// The terms, lowercased, as bytes.
    static func terms(_ text: String) -> [[UInt8]] {
        text.lowercased().split(separator: " ").map { Array($0.utf8) }
    }

    /// Rows for the keys (and folders on their way) in `pages` under `prefix` whose names contain
    /// every term. `folders` holds the matching folders already listed, so each is listed once.
    static func matches(_ pages: ArraySlice<S3KeyPage>, connectionID: UUID, bucket: String, prefix: String,
                        terms: [[UInt8]], limit: Int, folders: inout Set<String>) -> [ListRow] {
        let prefixBytes = Array(prefix.utf8)
        var rows: [ListRow] = []
        for page in pages {
            if Task.isCancelled { return rows }
            page.bytes.withUnsafeBufferPointer { bytes in
                var start = 0
                for index in 0..<page.count {
                    let end = Int(page.ends[index])
                    defer { start = end }
                    guard rows.count < limit, end - start > prefixBytes.count,
                          hasPrefix(bytes, start, prefixBytes) else { continue }
                    // Each name along the key after the prefix: folders, then the file.
                    var segment = start + prefixBytes.count
                    var position = segment
                    while position <= end {
                        if position == end || bytes[position] == UInt8(ascii: "/") {
                            let isFile = position == end
                            if position > segment, contains(bytes, segment, position, terms) {
                                if isFile {
                                    rows.append(fileRow(page, index, connectionID: connectionID, bucket: bucket))
                                } else {
                                    let folderKey = String(decoding: bytes[start...position], as: UTF8.self)
                                    if folders.insert(folderKey).inserted {
                                        rows.append(folderRow(folderKey, connectionID: connectionID, bucket: bucket))
                                    }
                                }
                            }
                            segment = position + 1
                        }
                        position += 1
                    }
                }
            }
        }
        return rows
    }

    private static func hasPrefix(_ bytes: UnsafeBufferPointer<UInt8>, _ start: Int, _ prefix: [UInt8]) -> Bool {
        for (offset, byte) in prefix.enumerated() where bytes[start + offset] != byte { return false }
        return true
    }

    /// Whether bytes[from..<to] contains every term, ignoring ASCII case.
    private static func contains(_ bytes: UnsafeBufferPointer<UInt8>, _ from: Int, _ to: Int, _ terms: [[UInt8]]) -> Bool {
        terms.allSatisfy { term in
            guard !term.isEmpty, to - from >= term.count else { return term.isEmpty }
            var i = from
            while i + term.count <= to {
                var j = 0
                while j < term.count && lower(bytes[i + j]) == term[j] { j += 1 }
                if j == term.count { return true }
                i += 1
            }
            return false
        }
    }

    private static func lower(_ byte: UInt8) -> UInt8 {
        byte >= 65 && byte <= 90 ? byte + 32 : byte
    }

    private static func fileRow(_ page: S3KeyPage, _ index: Int, connectionID: UUID, bucket: String) -> ListRow {
        let key = page.key(index)
        let name = String(key.split(separator: "/", omittingEmptySubsequences: false).last ?? "")
        let date = page.modified[index] == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(page.modified[index]))
        let item = FileItem(url: S3Location.url(connectionID: connectionID, bucket: bucket, key: key),
                            name: name, isDirectory: false, isHidden: name.hasPrefix("."), fileSize: page.sizes[index],
                            modified: date, contentType: UTType(filenameExtension: (name as NSString).pathExtension))
        return ListRow(item: item, size: page.sizes[index], date: date, location: location(of: key, bucket: bucket))
    }

    private static func folderRow(_ key: String, connectionID: UUID, bucket: String) -> ListRow {
        let name = String(key.dropLast().split(separator: "/").last ?? "")
        let item = FileItem(url: S3Location.url(connectionID: connectionID, bucket: bucket, key: key),
                            name: name, isDirectory: true, contentType: .folder)
        return ListRow(item: item, location: location(of: String(key.dropLast()), bucket: bucket))
    }

    /// "bucket/photos/2024" for the Location column: where the item is.
    private static func location(of key: String, bucket: String) -> String {
        let parent = (key as NSString).deletingLastPathComponent
        return parent.isEmpty ? bucket : bucket + "/" + parent
    }
}
