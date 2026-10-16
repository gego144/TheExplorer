import Darwin
import Foundation

/// A search result from the index.
struct IndexHit: Sendable {
    let path: String
    let isFolder: Bool
    let score: Int
}

extension FileIndex {
    /// Ranks every indexed item against `query` and returns the best `limit`.
    ///
    /// Every word has to match: in the item's name (scored by `FuzzyMatcher`), or else in the
    /// name of a folder it's in, so "dev readme" finds READMEs under ~/Dev. At least one word has
    /// to match the name itself. Matches then get a nudge for being recently used or changed,
    /// for being apps, and for being near the top of the tree.
    ///
    /// `folder` limits results to what's inside that indexed folder.
    static func search(_ query: String, in storage: Storage, under folder: Int32? = nil,
                       includeHidden: Bool = false, limit: Int, now: Date = Date()) -> [IndexHit] {
        let tokens = FuzzyMatcher.tokens(query)
        guard !tokens.isEmpty, storage.count > 0 else { return [] }
        let count = storage.count
        let nowSeconds = Int32(clamping: Int(now.timeIntervalSinceReferenceDate))

        // For words that might be about the path: which folders have them in their own name or
        // an enclosing folder's. One pass, since parents come before children.
        let inPath: [[Bool]] = tokens.count < 2 ? [] : tokens.map { token in
            var marks = [Bool](repeating: false, count: count)
            token.withUnsafeBufferPointer { token in
                storage.names.withUnsafeBufferPointer { names in
                    var scratch = [UInt8](repeating: 0, count: Int(UInt16.max))
                    for i in 0..<count where storage.flags[i].contains(.folder) {
                        let parent = storage.parent[i]
                        if parent >= 0 && marks[Int(parent)] {
                            marks[i] = true
                        } else if !storage.flags[i].contains(.root) {
                            marks[i] = withFolded(Int32(i), storage: storage, names: names, scratch: &scratch) { folded, _ in
                                FuzzyMatcher.contains(token, in: folded)
                            }
                        }
                    }
                }
            }
            return marks
        }

        // Inside the chosen folder, the same way.
        var inside: [Bool]?
        if let folder {
            var marks = [Bool](repeating: false, count: count)
            marks[Int(folder)] = true
            for i in Int(folder) + 1..<count {
                let parent = storage.parent[i]
                if parent >= 0 && marks[Int(parent)] { marks[i] = true }
            }
            inside = marks
        }
        let start = folder.map { Int($0) + 1 } ?? 0

        // Score in parallel slices, each keeping its own best few.
        let keep = limit
        let slices = max(1, min(ProcessInfo.processInfo.activeProcessorCount, (count - start) / 20_000))
        var found = [[(score: Int, index: Int32)]](repeating: [], count: slices)
        let lock = NSLock()
        storage.names.withUnsafeBufferPointer { names in
            let tokenBuffers = tokens.map { token in
                let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: token.count)
                _ = buffer.initialize(from: token)
                return UnsafeBufferPointer(buffer)
            }
            defer { tokenBuffers.forEach { $0.deallocate() } }
            DispatchQueue.concurrentPerform(iterations: slices) { slice in
                let range = sliceRange(slice, of: slices, from: start, to: count)
                var best: [(score: Int, index: Int32)] = []
                var floor = Int.min
                var scratch = [UInt8](repeating: 0, count: Int(UInt16.max))
                for i in range {
                    let flags = storage.flags[i]
                    if flags.contains(.removed) || flags.contains(.root) { continue }
                    if !includeHidden && flags.contains(.hidden) { continue }
                    if let inside, !inside[i] { continue }
                    let parent = Int(storage.parent[i])
                    let matched: Int? = withFolded(Int32(i), storage: storage, names: names, scratch: &scratch) { folded, original in
                        var total = 0
                        var inName = 0
                        for (t, token) in tokenBuffers.enumerated() {
                            let nameScore = FuzzyMatcher.score(token, name: folded, original: original)
                            let pathScore = !inPath.isEmpty && parent >= 0 && inPath[t][parent] ? 120 : nil
                            guard let top = [nameScore, pathScore].compactMap({ $0 }).max() else { return nil }
                            if let nameScore, nameScore >= (pathScore ?? 0) { inName += 1 }
                            total += top
                        }
                        return inName > 0 ? total : nil
                    }
                    guard var score = matched else { continue }
                    score += bonus(i, storage: storage, now: nowSeconds)
                    guard score > floor || best.count < keep else { continue }
                    best.append((score, Int32(i)))
                    if best.count >= keep * 2 {
                        best.sort { $0.score > $1.score }
                        best.removeSubrange(keep...)
                        floor = best[keep - 1].score
                    }
                }
                lock.withLock { found[slice] = best }
            }
        }

        // Recent use is read from disk, so only for the front-runners.
        var ranked = found.joined().sorted { $0.score > $1.score }.prefix(limit + 50).map { candidate in
            let path = storage.path(candidate.index)
            return (hit: IndexHit(path: path, isFolder: storage.flags[Int(candidate.index)].contains(.folder)
                                    && !storage.flags[Int(candidate.index)].contains(.package),
                                  score: candidate.score + lastUsedBonus(path, now: now)),
                    modified: storage.modified[Int(candidate.index)])
        }
        ranked.sort { $0.hit.score != $1.hit.score ? $0.hit.score > $1.hit.score : $0.modified > $1.modified }
        return ranked.prefix(limit).map(\.hit)
    }

    /// Nudges for things people are more likely after.
    private static func bonus(_ i: Int, storage: Storage, now: Int32) -> Int {
        var bonus = 0
        let age = Int(now) - Int(storage.modified[i])
        if age < 86_400 { bonus += 40 } else if age < 7 * 86_400 { bonus += 25 } else if age < 30 * 86_400 { bonus += 12 } else if age < 365 * 86_400 { bonus += 4 }
        let flags = storage.flags[i]
        if flags.contains(.hidden) { bonus -= 60 }
        if flags.contains(.package) {
            let start = Int(storage.nameStart[i]) + Int(storage.nameLength[i]) - 4
            if start >= 0, storage.names[start..<start + 4].elementsEqual(".app".utf8) { bonus += 40 }
        } else if flags.contains(.folder) {
            bonus += 5
        }
        let depth = storage.depth(Int32(i))
        bonus -= min(36, max(0, depth - 2) * 3)
        let start = Int(storage.nameStart[i])
        bonus -= hashPenalty(storage.names[start..<start + Int(storage.nameLength[i])])
        return bonus
    }

    /// Names made of a long hex hash ("cf2149e75d5dc5d6….bin", "b704a70e.8cb7cf31.js") are
    /// generated, and match short queries by accident. A run counts once it mixes letters and
    /// digits, so words like "facade" or "deadbeef" don't.
    static func hashPenalty(_ name: ArraySlice<UInt8>) -> Int {
        var longest = 0
        var run = 0
        var digits = 0
        var letters = 0
        func finish() {
            if digits >= 2 && letters >= 2 { longest = max(longest, run) }
            run = 0
            digits = 0
            letters = 0
        }
        for byte in name {
            switch byte {
            case 48...57: run += 1; digits += 1
            case 97...102, 65...70: run += 1; letters += 1
            default: finish()
            }
        }
        finish()
        if longest >= 16 { return 400 }
        if longest >= 8 { return 200 }
        return 0
    }

    /// Files macOS has opened recently (it records the time on the file) rise to the top.
    private static func lastUsedBonus(_ path: String, now: Date) -> Int {
        var value = timespec()
        let size = getxattr(path, "com.apple.lastuseddate#PS", &value, MemoryLayout<timespec>.size, 0, XATTR_NOFOLLOW)
        guard size == MemoryLayout<timespec>.size else { return 0 }
        let age = now.timeIntervalSince1970 - Double(value.tv_sec)
        if age < 86_400 { return 120 }
        if age < 7 * 86_400 { return 70 }
        if age < 30 * 86_400 { return 35 }
        if age < 365 * 86_400 { return 10 }
        return 0
    }

    private static func sliceRange(_ slice: Int, of slices: Int, from start: Int, to end: Int) -> Range<Int> {
        let size = (end - start + slices - 1) / slices
        let lower = start + slice * size
        return lower..<min(end, lower + size)
    }

    /// Calls `body` with an entry's folded name and its name as stored (the same bytes for
    /// names that aren't ASCII).
    private static func withFolded<T>(_ index: Int32, storage: Storage, names: UnsafeBufferPointer<UInt8>,
                                      scratch: inout [UInt8], _ body: (UnsafeBufferPointer<UInt8>, UnsafeBufferPointer<UInt8>) -> T) -> T {
        let i = Int(index)
        if storage.flags[i].contains(.nonASCII), let folded = storage.folded[index] {
            return folded.withUnsafeBufferPointer { body($0, $0) }
        }
        let start = Int(storage.nameStart[i])
        let length = Int(storage.nameLength[i])
        let original = UnsafeBufferPointer(rebasing: names[start..<start + length])
        return scratch.withUnsafeMutableBufferPointer { scratch in
            for k in 0..<length {
                let byte = original[k]
                scratch[k] = byte >= 65 && byte <= 90 ? byte + 32 : byte
            }
            return body(UnsafeBufferPointer(rebasing: scratch[0..<length]), original)
        }
    }
}
