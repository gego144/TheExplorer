import Foundation

/// A JSON file as a flat tree for the collapsible preview. Nodes are stored in document order,
/// each with the index just past its subtree, so walking children skips whole subtrees. Keys
/// keep the file's order, numbers keep their original text, and the parser is lenient where
/// config files are: comments and trailing commas are fine (tsconfig.json, .jsonc). JSON Lines
/// files (one value per line) become a list of their lines.
struct JSONTree: Sendable, Equatable {
    enum Kind: UInt8, Sendable { case object, array, string, number, bool, null }

    struct Node: Sendable, Equatable {
        var kind: Kind
        /// The member name, for values in an object.
        var key: String?
        /// The text of a scalar: a string's contents, or a number, true, false or null as written.
        var value: String
        var count: Int32
        /// The index just past this node and everything inside it.
        var end: Int32
        var parent: Int32

        var isContainer: Bool { kind == .object || kind == .array }
    }

    struct ParseError: LocalizedError, Equatable {
        var line: Int
        var column: Int
        var message: String
        /// Text after a complete value, which may mean the file is JSON Lines.
        var trailing = false

        var errorDescription: String? { "Line \(line), column \(column): \(message)" }
    }

    var nodes: [Node]
    /// Whether this is JSON Lines, where the root is the list of lines.
    var isLines: Bool

    init(_ data: Data, lines: Bool = false) throws {
        do {
            nodes = try Self.parse(data, lines: lines)
            isLines = lines
        } catch let error as ParseError where error.trailing && !lines {
            // Several values one after another: JSON Lines with a .json name.
            guard let nodes = try? Self.parse(data, lines: true) else { throw error }
            self.nodes = nodes
            isLines = true
        }
    }

    private static func parse(_ data: Data, lines: Bool) throws -> [Node] {
        try data.withUnsafeBytes { raw in
            var parser = Parser(bytes: raw.bindMemory(to: UInt8.self))
            if parser.bytes.starts(with: [0xEF, 0xBB, 0xBF]) { parser.pos = 3 }
            if lines {
                try parser.lines()
            } else {
                try parser.value(parent: -1)
                try parser.skip()
                if parser.pos < parser.bytes.count {
                    var error = parser.error("Unexpected text after the end of the JSON")
                    error.trailing = true
                    throw error
                }
            }
            return parser.nodes
        }
    }

    /// The indices of a node's children, in order.
    func children(of index: Int) -> [Int] {
        var result: [Int] = []
        result.reserveCapacity(Int(nodes[index].count))
        var child = index + 1
        while child < Int(nodes[index].end) {
            result.append(child)
            child = Int(nodes[child].end)
        }
        return result
    }

    /// A jq-style path to a node: `.users[3].name`, or `.` for the root.
    func path(to index: Int) -> String {
        var parts: [String] = []
        var current = index
        while nodes[current].parent >= 0 {
            let parent = Int(nodes[current].parent)
            if nodes[parent].kind == .array {
                let position = children(of: parent).firstIndex(of: current) ?? 0
                parts.append("[\(position)]")
            } else if let key = nodes[current].key {
                let plain = !key.isEmpty && key.first?.isNumber == false
                    && key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
                parts.append(plain ? "." + key : "[\(Self.quoted(key))]")
            }
            current = parent
        }
        let path = parts.reversed().joined()
        return path.isEmpty ? "." : (path.hasPrefix("[") ? "." + path : path)
    }

    /// A node as JSON text, indented. Strings on their own come back without quotes, which is
    /// what you want when copying one.
    func text(at index: Int) -> String {
        let node = nodes[index]
        if node.kind == .string { return node.value }
        var output = ""
        write(index, indent: "", into: &output)
        return output
    }

    private func write(_ index: Int, indent: String, into output: inout String) {
        let node = nodes[index]
        switch node.kind {
        case .string: output += Self.quoted(node.value)
        case .number, .bool, .null: output += node.value
        case .object, .array:
            let open = node.kind == .object ? "{" : "[", close = node.kind == .object ? "}" : "]"
            let children = children(of: index)
            guard !children.isEmpty else { output += open + close; return }
            output += open + "\n"
            let inner = indent + "  "
            for (position, child) in children.enumerated() {
                output += inner
                if node.kind == .object { output += Self.quoted(nodes[child].key ?? "") + ": " }
                write(child, indent: inner, into: &output)
                output += position == children.count - 1 ? "\n" : ",\n"
            }
            output += indent + close
        }
    }

    static func quoted(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case _ where scalar.value < 0x20: result += String(format: "\\u%04x", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
}

private struct Parser {
    let bytes: UnsafeBufferPointer<UInt8>
    var pos = 0
    var nodes: [JSONTree.Node] = []

    init(bytes: UnsafeBufferPointer<UInt8>) {
        self.bytes = bytes
    }

    private var peek: UInt8? { pos < bytes.count ? bytes[pos] : nil }

    /// Whitespace and comments.
    mutating func skip() throws {
        while pos < bytes.count {
            let byte = bytes[pos]
            if byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 {
                pos += 1
            } else if byte == 0x2F, pos + 1 < bytes.count, bytes[pos + 1] == 0x2F {
                while pos < bytes.count && bytes[pos] != 0x0A { pos += 1 }
            } else if byte == 0x2F, pos + 1 < bytes.count, bytes[pos + 1] == 0x2A {
                let start = pos
                pos += 2
                while pos + 1 < bytes.count && !(bytes[pos] == 0x2A && bytes[pos + 1] == 0x2F) { pos += 1 }
                guard pos + 1 < bytes.count else { pos = start; throw error("A /* comment is never closed") }
                pos += 2
            } else {
                return
            }
        }
    }

    /// JSON Lines: values one after another, as the children of a list.
    mutating func lines() throws {
        nodes.append(.init(kind: .array, key: nil, value: "", count: 0, end: 0, parent: -1))
        var count: Int32 = 0
        while true {
            try skip()
            guard pos < bytes.count else { break }
            try value(parent: 0)
            count += 1
        }
        nodes[0].count = count
        nodes[0].end = Int32(nodes.count)
    }

    /// One value, with everything inside it. Containers are tracked on a stack rather than by
    /// recursing, so deeply nested files can't overflow a thread's stack.
    mutating func value(parent base: Int32) throws {
        var stack: [(index: Int, close: UInt8, count: Int32)] = []
        var key: String?
        while true {
            try skip()
            guard let byte = peek else { throw error("The JSON ends too soon") }
            let parent = stack.last.map { Int32($0.index) } ?? base
            switch byte {
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                let object = byte == UInt8(ascii: "{")
                nodes.append(.init(kind: object ? .object : .array, key: key, value: "", count: 0, end: 0, parent: parent))
                pos += 1
                let close = UInt8(ascii: object ? "}" : "]")
                stack.append((nodes.count - 1, close, 0))
                try skip()
                if peek == close {
                    pos += 1
                    finish(&stack)
                } else {
                    key = object ? try member() : nil
                    continue
                }
            case UInt8(ascii: "\""): scalar(.string, try string(), key: key, parent: parent)
            case UInt8(ascii: "t"): try literal("true", .bool, key: key, parent: parent)
            case UInt8(ascii: "f"): try literal("false", .bool, key: key, parent: parent)
            case UInt8(ascii: "n"): try literal("null", .null, key: key, parent: parent)
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): scalar(.number, try number(), key: key, parent: parent)
            default: throw error("Unexpected “\(Character(Unicode.Scalar(byte)))”")
            }
            key = nil
            // A value just ended: move on to the next one, closing every container it finishes.
            var next = false
            while !next, !stack.isEmpty {
                stack[stack.count - 1].count += 1
                try skip()
                let top = stack[stack.count - 1]
                let closing = Character(Unicode.Scalar(top.close))
                guard let byte = peek else { throw error("The JSON ends before a closing “\(closing)”") }
                if byte == UInt8(ascii: ",") {
                    pos += 1
                    try skip()
                    if peek == top.close {
                        // A trailing comma, as config files often have.
                        pos += 1
                        finish(&stack)
                    } else {
                        if nodes[top.index].kind == .object { key = try member() }
                        next = true
                    }
                } else if byte == top.close {
                    pos += 1
                    finish(&stack)
                } else {
                    throw error("Expected “,” or “\(closing)”")
                }
            }
            if stack.isEmpty { return }
        }
    }

    private mutating func finish(_ stack: inout [(index: Int, close: UInt8, count: Int32)]) {
        let top = stack.removeLast()
        nodes[top.index].count = top.count
        nodes[top.index].end = Int32(nodes.count)
    }

    /// An object member's name and its colon.
    private mutating func member() throws -> String {
        try skip()
        guard peek == UInt8(ascii: "\"") else { throw error("Expected a key in double quotes") }
        let key = try string()
        try skip()
        guard peek == UInt8(ascii: ":") else { throw error("Expected “:” after the key") }
        pos += 1
        return key
    }

    private mutating func scalar(_ kind: JSONTree.Kind, _ value: String, key: String?, parent: Int32) {
        nodes.append(.init(kind: kind, key: key, value: value, count: 0, end: Int32(nodes.count + 1), parent: parent))
    }

    private mutating func literal(_ word: String, _ kind: JSONTree.Kind, key: String?, parent: Int32) throws {
        let utf8 = Array(word.utf8)
        guard pos + utf8.count <= bytes.count, Array(bytes[pos..<pos + utf8.count]) == utf8 else {
            throw error("Unexpected text; expected a value")
        }
        pos += utf8.count
        scalar(kind, word, key: key, parent: parent)
    }

    private mutating func number() throws -> String {
        let start = pos
        while pos < bytes.count {
            let byte = bytes[pos]
            guard (0x30...0x39).contains(byte) || byte == 0x2D || byte == 0x2B || byte == 0x2E || byte == 0x65 || byte == 0x45 else { break }
            pos += 1
        }
        let text = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<pos]), as: UTF8.self)
        guard Double(text) != nil else { pos = start; throw error("“\(text)” isn't a number") }
        return text
    }

    private mutating func string() throws -> String {
        let quote = pos
        pos += 1
        let start = pos
        // Most strings have no escapes and are copied straight out.
        while pos < bytes.count && bytes[pos] != 0x22 && bytes[pos] != 0x5C { pos += 1 }
        if pos < bytes.count && bytes[pos] == 0x22 {
            pos += 1
            return String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<pos - 1]), as: UTF8.self)
        }
        var output = Array(bytes[start..<pos])
        while pos < bytes.count {
            let byte = bytes[pos]
            pos += 1
            if byte == 0x22 { return String(decoding: output, as: UTF8.self) }
            guard byte == 0x5C else { output.append(byte); continue }
            guard pos < bytes.count else { break }
            let escape = bytes[pos]
            pos += 1
            switch escape {
            case UInt8(ascii: "n"): output.append(0x0A)
            case UInt8(ascii: "t"): output.append(0x09)
            case UInt8(ascii: "r"): output.append(0x0D)
            case UInt8(ascii: "b"): output.append(0x08)
            case UInt8(ascii: "f"): output.append(0x0C)
            case UInt8(ascii: "u"):
                var scalar = try hex()
                // A surrogate pair: 😀.
                if (0xD800...0xDBFF).contains(scalar), pos + 1 < bytes.count, bytes[pos] == 0x5C, bytes[pos + 1] == UInt8(ascii: "u") {
                    pos += 2
                    let low = try hex()
                    scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low &- 0xDC00)
                }
                output.append(contentsOf: Array(String(Unicode.Scalar(scalar).map(Character.init) ?? "\u{FFFD}").utf8))
            default: output.append(escape) // \" \\ \/ and anything else as itself
            }
        }
        pos = quote
        throw error("A string is never closed")
    }

    private mutating func hex() throws -> UInt32 {
        guard pos + 4 <= bytes.count,
              let value = UInt32(String(decoding: UnsafeBufferPointer(rebasing: bytes[pos..<pos + 4]), as: UTF8.self), radix: 16) else {
            throw error("Bad \\u escape")
        }
        pos += 4
        return value
    }

    func error(_ message: String) -> JSONTree.ParseError {
        var line = 1, column = 1
        for byte in bytes[..<min(pos, bytes.count)] {
            if byte == 0x0A { line += 1; column = 1 } else if byte & 0xC0 != 0x80 { column += 1 }
        }
        return JSONTree.ParseError(line: line, column: column, message: message)
    }
}
