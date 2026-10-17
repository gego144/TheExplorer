import Foundation

/// A CSV or TSV file read for the table preview: the first rows in full, and a count of the
/// rest. Quoted fields (with commas, doubled quotes and line breaks inside) follow RFC 4180, and
/// the delimiter is sniffed for .csv files, since plenty of them use semicolons or tabs.
struct DelimitedTable: Sendable, Equatable {
    var header: [String]
    var rows: [[String]]
    /// Data rows in the whole file, not counting the header.
    var totalRows: Int
    var delimiter: UInt8
    /// Columns that are (almost) all numbers, which line up on the right.
    var numeric: [Bool]
    /// The longest text in each column, in characters, capped, for sizing columns.
    var widths: [Int]
    /// Whether only the start of a huge file was counted.
    var partial = false

    var columns: Int { header.count }

    static let maxColumns = 200

    /// Parses `data`; `delimiter` is sniffed when nil. Only `maxRows` rows are kept, but every
    /// row is counted.
    init(_ data: Data, delimiter: UInt8? = nil, maxRows: Int = 1000) {
        var bytes = data[...]
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        let delimiter = delimiter ?? Self.sniff(bytes)
        // Non-UTF-8 files are usually Windows Latin-1 exports from spreadsheets.
        var head = bytes.prefix(65_536)
        if head.count < bytes.count, let newline = head.lastIndex(of: 0x0A) { head = head[..<newline] }
        let utf8 = String(data: Data(head), encoding: .utf8) != nil
        var records: [[String]] = []
        var total = 0
        bytes.withUnsafeBytes { raw in
            let buffer = raw.bindMemory(to: UInt8.self)
            var index = 0
            let end = buffer.count
            var record: [String] = []
            var field: [UInt8] = []
            var quoted = false
            var keeping = true
            // Once enough rows are kept, the rest are only counted, so fields aren't stored.
            var fields = 0
            var filled = false

            func endField() {
                if keeping && record.count < Self.maxColumns {
                    record.append(utf8 ? String(decoding: field, as: UTF8.self) : (String(bytes: field, encoding: .windowsCP1252) ?? ""))
                }
                field.removeAll(keepingCapacity: true)
                fields += 1
            }
            func endRecord() {
                endField()
                // Blank lines aren't rows.
                if fields > 1 || filled {
                    total += 1
                    if keeping { records.append(record) }
                    if records.count > maxRows { keeping = false }
                }
                record.removeAll(keepingCapacity: true)
                fields = 0
                filled = false
            }

            while index < end {
                let byte = buffer[index]
                index += 1
                if quoted {
                    if byte == 0x22 {
                        if index < end && buffer[index] == 0x22 {
                            if keeping { field.append(0x22) }
                            index += 1
                        } else {
                            quoted = false
                        }
                    } else if keeping {
                        field.append(byte)
                    }
                } else if byte == 0x22 && field.isEmpty {
                    quoted = true
                    filled = true
                } else if byte == delimiter {
                    endField()
                } else if byte == 0x0A || byte == 0x0D {
                    if byte == 0x0D && index < end && buffer[index] == 0x0A { index += 1 }
                    endRecord()
                } else {
                    filled = true
                    if keeping { field.append(byte) }
                }
            }
            if filled || fields > 0 || !record.isEmpty { endRecord() }
        }

        header = records.first ?? []
        let body = Array(records.dropFirst().prefix(maxRows))
        let columns = max(header.count, body.map(\.count).max() ?? 0)
        header += Array(repeating: "", count: columns - header.count)
        rows = body.map { $0.count < columns ? $0 + Array(repeating: "", count: columns - $0.count) : $0 }
        totalRows = max(0, total - 1)
        self.delimiter = delimiter

        var numeric = Array(repeating: false, count: columns)
        var widths = header.map { min($0.count, 40) }
        let sample = rows.prefix(300)
        for column in 0..<columns {
            var numbers = 0, filled = 0
            for row in sample {
                let cell = row[column]
                widths[column] = max(widths[column], min(cell.count, 40))
                guard !cell.isEmpty else { continue }
                filled += 1
                if Self.isNumber(cell) { numbers += 1 }
            }
            numeric[column] = filled > 0 && numbers * 10 >= filled * 9
        }
        self.numeric = numeric
        self.widths = widths
    }

    /// The delimiter that splits the first lines most consistently: comma, tab, semicolon or pipe.
    static func sniff(_ bytes: Data) -> UInt8 {
        let candidates: [UInt8] = [0x2C, 0x09, 0x3B, 0x7C]
        var counts = Array(repeating: [Int](), count: candidates.count)
        var line = Array(repeating: 0, count: candidates.count)
        var quoted = false
        var lines = 0
        for byte in bytes.prefix(32_768) {
            if byte == 0x22 { quoted.toggle() }
            if quoted { continue }
            if byte == 0x0A {
                for i in candidates.indices { counts[i].append(line[i]) }
                line = Array(repeating: 0, count: candidates.count)
                lines += 1
                if lines == 20 { break }
            } else if let i = candidates.firstIndex(of: byte) {
                line[i] += 1
            }
        }
        if lines < 20 { for i in candidates.indices { counts[i].append(line[i]) } }
        // The fewest per line is what every line has; a delimiter in only some lines loses.
        let best = candidates.indices.max { (counts[$0].min() ?? 0, counts[$0].first ?? 0) < (counts[$1].min() ?? 0, counts[$1].first ?? 0) }
        guard let best, (counts[best].first ?? 0) > 0 else { return 0x2C }
        return candidates[best]
    }

    /// Numbers as spreadsheets write them: 1,234.5, $12, 40%, -3e5.
    static func isNumber(_ text: String) -> Bool {
        var value = text.trimmingCharacters(in: .whitespaces)
        if let first = value.first, "$€£¥".contains(first) { value.removeFirst() }
        if value.hasSuffix("%") { value.removeLast() }
        value.removeAll { $0 == "," || $0 == "_" }
        return !value.isEmpty && Double(value) != nil
    }
}
