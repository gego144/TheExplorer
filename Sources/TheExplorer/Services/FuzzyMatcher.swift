import Foundation

/// Scores how well a typed word matches a file name, the way launchers like Raycast do: whole
/// names beat prefixes, prefixes beat word starts ("report" in "q3-report.pdf"), those beat
/// matches mid-word, and below that the letters can be spread out ("tex" finds "TheExplorer",
/// "qrp" finds "q3-report.pdf") as long as they land on word starts rather than anywhere.
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

    /// Lowercased, accent-free, precomposed UTF-8, for matching.
    static func fold(_ text: String) -> [UInt8] {
        Array(text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .precomposedStringWithCanonicalMapping.utf8)
    }

    /// The words of a query, folded. Empty when there's nothing to search for.
    static func tokens(_ query: String) -> [[UInt8]] {
        query.split(whereSeparator: \.isWhitespace).map { fold(String($0)) }.filter { !$0.isEmpty }
    }

    /// How well `token` matches a name, or nil if it doesn't. `name` is the folded name;
    /// `original` the name as stored (for spotting camelCase word starts), same length.
    static func score(_ token: UnsafeBufferPointer<UInt8>, name: UnsafeBufferPointer<UInt8>, original: UnsafeBufferPointer<UInt8>) -> Int? {
        let m = token.count
        let n = name.count
        guard m > 0, m <= n else { return nil }
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
        return fuzzy(token, name: name, original: original)
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
