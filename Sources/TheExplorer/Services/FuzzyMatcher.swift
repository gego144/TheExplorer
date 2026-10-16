import Foundation

/// Scores how well a typed word matches a file name, the way launchers like Raycast do: whole
/// names beat prefixes, prefixes beat word starts ("report" in "q3-report.pdf"), those beat
/// matches mid-word, and below that the letters can be spread out ("tex" finds "TheExplorer",
/// "qrp" finds "q3-report.pdf") as long as they land on word starts rather than anywhere.
/// Typos are forgiven too: "audit" finds "audting.mp4" and "reciept" finds "receipt.pdf".
///
/// Everything works on lowercased, accent-free UTF-8 bytes, so it's fast enough to run over
/// every name in the index on each keystroke.
enum FuzzyMatcher {
    static let exact = 1000
    static let stem = 950
    static let prefix = 800
    static let wordStart = 650
    static let substring = 450
    static let fuzzyBase = 300
    /// A word with a typo in it, at the start of the name or of a later word.
    static let typoAtStart = 520
    static let typoInWord = 420

    /// Lowercased, accent-free, precomposed UTF-8, for matching.
    static func fold(_ text: String) -> [UInt8] {
        Array(text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .precomposedStringWithCanonicalMapping.utf8)
    }

    /// The words of a query, folded. Empty when there's nothing to search for.
    static func tokens(_ query: String) -> [[UInt8]] {
        query.split(whereSeparator: \.isWhitespace).map { fold(String($0)) }.filter { !$0.isEmpty }
    }

    /// The total score of every word against a name, or nil unless they all match. For names
    /// that aren't in the index (the folder walk); the index matches its stored names directly.
    static func score(_ tokens: [[UInt8]], name: String) -> Int? {
        let folded = fold(name)
        var stored = Array(name.utf8)
        if stored.count != folded.count { stored = folded }
        return folded.withUnsafeBufferPointer { folded in
            stored.withUnsafeBufferPointer { original in
                var total = 0
                for token in tokens {
                    guard let score = token.withUnsafeBufferPointer({ score($0, name: folded, original: original) }) else { return nil }
                    total += score
                }
                return total
            }
        }
    }

    /// How well `token` matches a name, or nil if it doesn't. `name` is the folded name;
    /// `original` the name as stored (for spotting camelCase word starts), same length.
    static func score(_ token: UnsafeBufferPointer<UInt8>, name: UnsafeBufferPointer<UInt8>, original: UnsafeBufferPointer<UInt8>) -> Int? {
        let m = token.count
        let n = name.count
        guard m > 0 else { return nil }
        guard m <= n else { return typo(token, name: name, original: original) }
        // Longer names rank a little lower for the same kind of match.
        let lengthPenalty = min(60, n - m)

        if let at = firstOccurrence(token, in: name, from: 0) {
            if at == 0 {
                if m == n { return exact }
                if name[m] == UInt8(ascii: "."), !name[(m + 1)...].contains(UInt8(ascii: ".")) { return stem }
                return prefix - lengthPenalty
            }
            // The best occurrence: one at a word start beats one mid-word.
            var occurrence: Int? = at
            while let position = occurrence {
                if isBoundary(position, name: name, original: original) { return wordStart - lengthPenalty }
                occurrence = firstOccurrence(token, in: name, from: position + 1)
            }
            return substring - lengthPenalty
        }
        guard m >= 2 else { return nil }
        let spread = fuzzy(token, name: name, original: original)
        guard let typo = typo(token, name: name, original: original) else { return spread }
        return max(spread ?? 0, typo)
    }

    /// A word typed with a slip: two letters swapped, one missing, one extra or one wrong (two
    /// slips in words of eight letters or more). The match has to start at a word start with the
    /// right first letter, which people rarely get wrong, so this finds "audting" for "audit"
    /// without turning every short query into noise. Words under four letters must be exact.
    private static func typo(_ token: UnsafeBufferPointer<UInt8>, name: UnsafeBufferPointer<UInt8>, original: UnsafeBufferPointer<UInt8>) -> Int? {
        let m = token.count
        let n = name.count
        guard m >= 4, m <= 32 else { return nil }
        let allowed = m >= 8 ? 2 : 1
        var best = allowed + 1
        var bestStart = 0
        for start in 0..<n where name[start] == token[0] && isBoundary(start, name: name, original: original) {
            let width = min(n - start, m + allowed)
            guard width >= m - allowed else { continue }
            let edits = slips(token, name: name, from: start, width: width, limit: allowed)
            if edits < best {
                best = edits
                bestStart = start
                if edits <= 1 && start == 0 { break }
            }
        }
        guard best <= allowed else { return nil }
        let base = bestStart == 0 ? typoAtStart : typoInWord
        return base - 120 * (max(1, best) - 1) - min(60, max(0, n - bestStart - m))
    }

    /// The fewest edits (swapping neighbours counts as one) turning `token` into the start of
    /// `name` from `start`, looking at most `width` letters in; more than `limit` if it's further.
    private static func slips(_ token: UnsafeBufferPointer<UInt8>, name: UnsafeBufferPointer<UInt8>,
                              from start: Int, width: Int, limit: Int) -> Int {
        let m = token.count
        let columns = width + 1
        return withUnsafeTemporaryAllocation(of: Int.self, capacity: 3 * columns) { rows in
            // Three rows of the edit-distance table: two back (for swaps), the last, and this one.
            var older = 0
            var previous = columns
            var current = 2 * columns
            for j in 0..<columns { rows[previous + j] = j }
            for i in 1...m {
                rows[current] = i
                var rowBest = i
                for j in 1..<columns {
                    let same = token[i - 1] == name[start + j - 1]
                    var value = min(rows[previous + j] + 1, rows[current + j - 1] + 1, rows[previous + j - 1] + (same ? 0 : 1))
                    if i > 1 && j > 1 && token[i - 1] == name[start + j - 2] && token[i - 2] == name[start + j - 1] {
                        value = min(value, rows[older + j - 2] + 1)
                    }
                    rows[current + j] = value
                    rowBest = min(rowBest, value)
                }
                if rowBest > limit { return limit + 1 }
                (older, previous, current) = (previous, current, older)
            }
            // The token can end anywhere: the rest of the word doesn't count against it.
            var best = limit + 1
            for j in max(0, m - limit)..<columns { best = min(best, rows[previous + j]) }
            return best
        }
    }

    /// Letters in order but not together. Each letter continues the current run if it can,
    /// else jumps to the next word start that still leaves room for the rest, else takes the
    /// next occurrence; then the match is scored on how word-like its pieces are.
    private static func fuzzy(_ token: UnsafeBufferPointer<UInt8>, name: UnsafeBufferPointer<UInt8>, original: UnsafeBufferPointer<UInt8>) -> Int? {
        let m = token.count
        let n = name.count
        var segments = 0
        var boundaryStarts = 0
        var badStarts = 0
        var first = -1
        var previous = -2
        for t in 0..<m {
            let letter = token[t]
            var chosen = -1
            if previous + 1 < n && previous >= 0 && name[previous + 1] == letter {
                chosen = previous + 1
            } else {
                var earliest = -1
                var i = max(0, previous + 1)
                while i < n {
                    if name[i] == letter {
                        if earliest < 0 { earliest = i }
                        if isBoundary(i, name: name, original: original), isSubsequence(token, from: t + 1, of: name, after: i) {
                            chosen = i
                            break
                        }
                    }
                    i += 1
                }
                if chosen < 0 { chosen = earliest }
            }
            guard chosen >= 0 else { return nil }
            if chosen != previous + 1 {
                segments += 1
                if isBoundary(chosen, name: name, original: original) {
                    boundaryStarts += 1
                } else {
                    badStarts += 1
                }
            }
            if first < 0 { first = chosen }
            previous = chosen
        }
        // Pieces starting mid-word are what make fuzzy matches feel random; allow very few.
        guard badStarts <= m / 4 else { return nil }
        let gaps = (previous - first + 1) - m
        let score = fuzzyBase + 25 * boundaryStarts - 30 * (segments - 1) - 2 * gaps + (first == 0 ? 30 : 0)
        return max(50, min(fuzzyBase + 100, score))
    }

    private static func isSubsequence(_ token: UnsafeBufferPointer<UInt8>, from start: Int, of name: UnsafeBufferPointer<UInt8>, after position: Int) -> Bool {
        var t = start
        var i = position + 1
        while t < token.count && i < name.count {
            if name[i] == token[t] { t += 1 }
            i += 1
        }
        return t == token.count
    }

    /// Whether `token` appears in `name` as is (used for folder names in a path).
    static func contains(_ token: UnsafeBufferPointer<UInt8>, in name: UnsafeBufferPointer<UInt8>) -> Bool {
        firstOccurrence(token, in: name, from: 0) != nil
    }

    private static func firstOccurrence(_ token: UnsafeBufferPointer<UInt8>, in name: UnsafeBufferPointer<UInt8>, from: Int) -> Int? {
        let m = token.count
        let n = name.count
        guard m > 0, from + m <= n else { return nil }
        let first = token[0]
        var i = from
        while i + m <= n {
            if name[i] == first {
                var k = 1
                while k < m && name[i + k] == token[k] { k += 1 }
                if k == m { return i }
            }
            i += 1
        }
        return nil
    }

    /// The start of a word: after a separator, a lower-to-upper case change, or a switch
    /// between letters and digits.
    static func isBoundary(_ i: Int, name: UnsafeBufferPointer<UInt8>, original: UnsafeBufferPointer<UInt8>) -> Bool {
        guard i > 0 else { return true }
        let before = name[i - 1]
        switch before {
        case UInt8(ascii: " "), UInt8(ascii: "_"), UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "("),
             UInt8(ascii: ")"), UInt8(ascii: "["), UInt8(ascii: "]"), UInt8(ascii: "+"), UInt8(ascii: ","),
             UInt8(ascii: "@"), UInt8(ascii: "/"):
            return true
        default:
            break
        }
        let current = original[i]
        let previous = original[i - 1]
        if isUpper(current) && isLower(previous) { return true }
        return isDigit(current) != isDigit(name[i - 1]) && isAlphanumeric(current) && isAlphanumeric(previous)
    }

    private static func isUpper(_ byte: UInt8) -> Bool { byte >= 65 && byte <= 90 }
    private static func isLower(_ byte: UInt8) -> Bool { byte >= 97 && byte <= 122 }
    private static func isDigit(_ byte: UInt8) -> Bool { byte >= 48 && byte <= 57 }
    private static func isAlphanumeric(_ byte: UInt8) -> Bool { isUpper(byte) || isLower(byte) || isDigit(byte) }
}
