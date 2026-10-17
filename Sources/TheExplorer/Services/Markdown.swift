import Foundation

/// A Markdown file split into blocks for the rendered preview: headings, paragraphs, lists
/// (with task boxes), code, quotes, rules, GitHub tables and images. Blocks are parsed here;
/// the text inside them (emphasis, code spans, links) is Foundation's Markdown parser.
/// HTML is mostly dropped, except `<img>` tags and the text between tags, which READMEs use a lot.
struct MarkdownDocument: Sendable, Equatable {
    enum Block: Sendable, Equatable {
        case heading(level: Int, text: AttributedString, anchor: String)
        case paragraph(AttributedString)
        case listItem(depth: Int, marker: Marker, text: AttributedString)
        case code(language: String?, text: String)
        case quote([Block])
        case rule
        case table(Table)
        case images([Image])
    }

    enum Marker: Sendable, Equatable {
        case bullet
        case number(Int)
        case task(done: Bool)
    }

    enum Alignment: Sendable, Equatable { case leading, center, trailing }

    struct Table: Sendable, Equatable {
        var alignments: [Alignment]
        var header: [AttributedString]
        var rows: [[AttributedString]]
    }

    struct Image: Sendable, Equatable {
        var alt: String
        var source: String
        /// From an `<img width=…>` tag.
        var width: Double?
    }

    let blocks: [Block]
    /// Heading anchors (GitHub's `#section-name` links) to the index of their block.
    let anchors: [String: Int]

    init(_ source: String) {
        var lines = source.split(separator: "\n", omittingEmptySubsequences: false).map {
            $0.hasSuffix("\r") ? $0.dropLast() : $0
        }
        var front: [Block] = []
        // YAML front matter shows as a code block rather than a rule and a jumble of text.
        if lines.first.map({ $0.trimmingCharacters(in: .whitespaces) == "---" }) == true,
           let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" || $0 == "..." }) {
            front = [.code(language: "yaml", text: lines[1..<end].joined(separator: "\n"))]
            lines.removeSubrange(0...end)
        }
        var parser = BlockParser()
        blocks = front + parser.parse(lines[...])
        var anchors: [String: Int] = [:]
        var used: [String: Int] = [:]
        for (index, block) in blocks.enumerated() {
            guard case .heading(_, _, let anchor) = block else { continue }
            // Like GitHub: repeated headings get -1, -2…
            let count = used[anchor, default: 0]
            used[anchor] = count + 1
            anchors[count == 0 ? anchor : "\(anchor)-\(count)"] = index
        }
        self.anchors = anchors
    }

    /// GitHub's heading anchor: lowercased, punctuation dropped, spaces as hyphens.
    static func anchor(for heading: String) -> String {
        var result = ""
        for character in heading.lowercased() {
            if character.isLetter || character.isNumber || character == "-" || character == "_" {
                result.append(character)
            } else if character == " " {
                result.append("-")
            }
        }
        return result
    }

    /// Inline Markdown: emphasis, code spans, links, with HTML tags stripped out.
    static func inline(_ text: String) -> AttributedString {
        let cleaned = stripTags(text)
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: cleaned, options: options)) ?? AttributedString(cleaned)
    }

    /// Drops HTML tags and comments outside code spans; `<br>` becomes a line break.
    static func stripTags(_ text: String) -> String {
        guard text.contains("<") else { return text }
        var result = ""
        var inCode = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "`" { inCode.toggle() }
            if !inCode, character == "<", let close = tagEnd(in: text, from: index) {
                let tag = text[index..<close].lowercased()
                if tag.hasPrefix("<br") { result.append("\n") }
                index = close
                continue
            }
            result.append(character)
            index = text.index(after: index)
        }
        return result
    }

    /// Where an HTML tag or comment starting at `start` ends, or nil when `<` isn't a tag.
    private static func tagEnd(in text: String, from start: String.Index) -> String.Index? {
        let rest = text[start...]
        if rest.hasPrefix("<!--") {
            guard let end = rest.range(of: "-->") else { return text.endIndex }
            return end.upperBound
        }
        let next = text.index(after: start)
        guard next < text.endIndex, text[next].isLetter || text[next] == "/" else { return nil }
        guard let close = rest.firstIndex(of: ">") else { return nil }
        // Autolinks like <https://example.com> aren't tags.
        let inner = text[next..<close]
        if inner.contains("://") || inner.hasPrefix("mailto:") || (inner.contains("@") && !inner.contains(" ")) { return nil }
        return text.index(after: close)
    }

    /// The `<img>` tags on a line of HTML.
    static func htmlImages(in line: Substring) -> [Image] {
        var images: [Image] = []
        var rest = line[...]
        while let open = rest.range(of: "<img", options: .caseInsensitive) {
            guard let close = rest[open.upperBound...].firstIndex(of: ">") else { break }
            let tag = rest[open.upperBound..<close]
            if let source = attribute("src", in: tag) {
                images.append(Image(alt: attribute("alt", in: tag) ?? "", source: source,
                                    width: attribute("width", in: tag).flatMap { Double($0) }))
            }
            rest = rest[rest.index(after: close)...]
        }
        return images
    }

    private static func attribute(_ name: String, in tag: Substring) -> String? {
        var search = tag[...]
        while let range = search.range(of: name + "=", options: .caseInsensitive) {
            // Only a whole attribute name ("src", not "data-src").
            let before = range.lowerBound == search.startIndex ? " " : search[search.index(before: range.lowerBound)]
            search = search[range.upperBound...]
            guard before.isWhitespace else { continue }
            guard let quote = search.first else { return nil }
            if quote == "\"" || quote == "'" {
                let value = search.dropFirst()
                guard let end = value.firstIndex(of: quote) else { return nil }
                return String(value[..<end])
            }
            return String(search.prefix { !$0.isWhitespace && $0 != ">" && $0 != "/" })
        }
        return nil
    }

    /// `![alt](source)` images, when they're all a line has (badges, screenshots), optionally
    /// each wrapped in a link.
    static func markdownImages(in line: Substring) -> [Image]? {
        var images: [Image] = []
        var rest = line.drop { $0.isWhitespace }
        while !rest.isEmpty {
            var linked = false
            if rest.hasPrefix("[![") {
                linked = true
                rest = rest.dropFirst()
            }
            guard rest.hasPrefix("!["), let altEnd = rest.firstIndex(of: "]") else { return nil }
            let alt = rest[rest.index(rest.startIndex, offsetBy: 2)..<altEnd]
            rest = rest[rest.index(after: altEnd)...]
            guard rest.first == "(", let close = rest.firstIndex(of: ")") else { return nil }
            var target = rest[rest.index(after: rest.startIndex)..<close].trimmingCharacters(in: .whitespaces)
            if let space = target.firstIndex(of: " ") { target = String(target[..<space]) } // drops a "title"
            if target.hasPrefix("<") && target.hasSuffix(">") { target = String(target.dropFirst().dropLast()) }
            images.append(Image(alt: String(alt), source: target, width: nil))
            rest = rest[rest.index(after: close)...]
            if linked {
                guard rest.hasPrefix("]("), let end = rest.firstIndex(of: ")") else { return nil }
                rest = rest[rest.index(after: end)...]
            }
            rest = rest.drop { $0.isWhitespace }
        }
        return images.isEmpty ? nil : images
    }
}

// MARK: - Blocks

private struct BlockParser {
    /// The indents of the list items above, for working out how deep the next one is.
    private var listIndents: [Int] = []

    mutating func parse(_ lines: ArraySlice<Substring>) -> [MarkdownDocument.Block] {
        var blocks: [MarkdownDocument.Block] = []
        var paragraph: [Substring] = []
        /// Whether the previous line was images, so a run of badges shares one row.
        var lastWasImages = false
        var inComment = false
        var index = lines.startIndex

        func flush() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(MarkdownDocument.inline(Self.join(paragraph))))
            paragraph = []
        }

        while index < lines.endIndex {
            let line = lines[index]
            let indent = Self.indent(of: line)
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            index += 1
            if inComment {
                if trimmed.contains("-->") { inComment = false }
                continue
            }
            if trimmed.allSatisfy(\.isWhitespace) {
                flush()
                lastWasImages = false
                continue
            }
            let wasImages = lastWasImages
            lastWasImages = false

            // Fenced code.
            if let fence = Self.fence(trimmed) {
                flush()
                listIndents = []
                var body: [Substring] = []
                while index < lines.endIndex {
                    let next = lines[index]
                    index += 1
                    let content = next.drop { $0 == " " }
                    if content.hasPrefix(fence.marker), content.drop(while: { $0 == fence.marker.first }).allSatisfy(\.isWhitespace) { break }
                    body.append(Self.dropIndent(next, upTo: indent))
                }
                blocks.append(.code(language: fence.language, text: body.joined(separator: "\n")))
                continue
            }
            // Indented code, outside lists and paragraphs.
            if indent >= 4, paragraph.isEmpty, listIndents.isEmpty {
                var body = [Self.dropIndent(line, upTo: 4)]
                while index < lines.endIndex, Self.indent(of: lines[index]) >= 4 || lines[index].allSatisfy(\.isWhitespace) {
                    body.append(Self.dropIndent(lines[index], upTo: 4))
                    index += 1
                }
                while body.last?.allSatisfy(\.isWhitespace) == true { body.removeLast() }
                blocks.append(.code(language: nil, text: body.joined(separator: "\n")))
                continue
            }
            if let (level, text) = Self.atxHeading(trimmed) {
                flush()
                listIndents = []
                blocks.append(.heading(level: level, text: MarkdownDocument.inline(text), anchor: Self.anchor(text)))
                continue
            }
            // A line of === or --- under a paragraph makes it a heading.
            if !paragraph.isEmpty, let level = Self.setextLevel(trimmed) {
                let text = Self.join(paragraph)
                paragraph = []
                blocks.append(.heading(level: level, text: MarkdownDocument.inline(text), anchor: Self.anchor(text)))
                continue
            }
            if Self.isRule(trimmed) {
                flush()
                listIndents = []
                blocks.append(.rule)
                continue
            }
            if trimmed.hasPrefix(">") {
                flush()
                listIndents = []
                var quoted = [Self.unquote(trimmed)]
                while index < lines.endIndex {
                    let next = lines[index].drop { $0 == " " }
                    guard next.hasPrefix(">") else { break }
                    quoted.append(Self.unquote(next))
                    index += 1
                }
                var inner = BlockParser()
                blocks.append(.quote(inner.parse(quoted[...])))
                continue
            }
            if let item = Self.listItem(trimmed) {
                flush()
                var text = [item.text]
                while index < lines.endIndex {
                    let next = lines[index]
                    let nextTrimmed = next.drop { $0 == " " || $0 == "\t" }
                    if nextTrimmed.allSatisfy(\.isWhitespace) || Self.listItem(nextTrimmed) != nil || Self.startsBlock(nextTrimmed) { break }
                    text.append(nextTrimmed)
                    index += 1
                }
                blocks.append(.listItem(depth: depth(for: indent), marker: item.marker, text: MarkdownDocument.inline(Self.join(text))))
                continue
            }
            if trimmed.contains("|"), index < lines.endIndex, let alignments = Self.tableDelimiter(lines[index]) {
                flush()
                listIndents = []
                index += 1
                let header = Self.cells(trimmed)
                var rows: [[AttributedString]] = []
                while index < lines.endIndex, lines[index].contains("|"), !lines[index].allSatisfy(\.isWhitespace) {
                    var cells = Self.cells(lines[index]).map(MarkdownDocument.inline)
                    cells = Array(cells.prefix(header.count)) + Array(repeating: AttributedString(), count: max(0, header.count - cells.count))
                    rows.append(cells)
                    index += 1
                }
                let aligned = Array(alignments.prefix(header.count)) + Array(repeating: .leading, count: max(0, header.count - alignments.count))
                blocks.append(.table(.init(alignments: aligned, header: header.map(MarkdownDocument.inline), rows: rows)))
                continue
            }
            if trimmed.hasPrefix("<") {
                if trimmed.hasPrefix("<!--"), !trimmed.contains("-->") {
                    inComment = true
                    continue
                }
                let images = MarkdownDocument.htmlImages(in: trimmed)
                if !images.isEmpty {
                    flush()
                    append(images, to: &blocks, merging: wasImages)
                    lastWasImages = true
                }
                let text = MarkdownDocument.stripTags(String(trimmed)).trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { paragraph.append(Substring(text)) }
                continue
            }
            if let images = MarkdownDocument.markdownImages(in: trimmed) {
                flush()
                append(images, to: &blocks, merging: wasImages)
                lastWasImages = true
                continue
            }
            if paragraph.isEmpty { listIndents = [] }
            paragraph.append(line.hasSuffix("  ") ? line.drop { $0 == " " } : trimmed)
        }
        flush()
        return blocks
    }

    private func append(_ images: [MarkdownDocument.Image], to blocks: inout [MarkdownDocument.Block], merging: Bool) {
        if merging, case .images(let previous) = blocks.last {
            blocks[blocks.count - 1] = .images(previous + images)
        } else {
            blocks.append(.images(images))
        }
    }

    /// How deep a list item is, from its indent relative to the items above it.
    private mutating func depth(for indent: Int) -> Int {
        while let last = listIndents.last, last > indent { listIndents.removeLast() }
        if listIndents.last != indent { listIndents.append(indent) }
        return listIndents.count - 1
    }

    /// Joins paragraph lines: a soft break is a space; two trailing spaces or a backslash make a
    /// hard one.
    private static func join(_ lines: [Substring]) -> String {
        var result = ""
        for (index, line) in lines.enumerated() {
            let last = index == lines.count - 1
            if line.hasSuffix("  ") {
                result += line.trimmingCharacters(in: .whitespaces) + (last ? "" : "\n")
            } else if line.hasSuffix("\\") && !last {
                result += line.dropLast() + "\n"
            } else {
                result += line.trimmingCharacters(in: .whitespaces) + (last ? "" : " ")
            }
        }
        return result
    }

    private static func indent(of line: Substring) -> Int {
        var width = 0
        for character in line {
            if character == " " { width += 1 } else if character == "\t" { width += 4 - width % 4 } else { break }
        }
        return width
    }

    private static func dropIndent(_ line: Substring, upTo count: Int) -> Substring {
        var dropped = 0
        return line.drop { character in
            guard dropped < count, character == " " || character == "\t" else { return false }
            dropped += character == "\t" ? 4 : 1
            return true
        }
    }

    private static func anchor(_ text: String) -> String {
        MarkdownDocument.anchor(for: String(MarkdownDocument.inline(text).characters))
    }

    private static func fence(_ line: Substring) -> (marker: String, language: String?)? {
        guard let first = line.first, first == "`" || first == "~" else { return nil }
        let run = line.prefix { $0 == first }
        guard run.count >= 3 else { return nil }
        let info = line.dropFirst(run.count).trimmingCharacters(in: .whitespaces)
        if first == "`" && info.contains("`") { return nil }
        let language = info.split(separator: " ").first.map(String.init)
        return (String(run), language?.isEmpty == false ? language : nil)
    }

    private static func atxHeading(_ line: Substring) -> (Int, String)? {
        let hashes = line.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = line.dropFirst(hashes.count)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // Closing hashes: "## Title ##".
        if let range = text.range(of: #"\s+#+$"#, options: .regularExpression) { text.removeSubrange(range) }
        if text.allSatisfy({ $0 == "#" }) { text = "" }
        return (hashes.count, text)
    }

    private static func setextLevel(_ line: Substring) -> Int? {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard let first = text.first, first == "=" || first == "-", text.allSatisfy({ $0 == first }) else { return nil }
        return first == "=" ? 1 : 2
    }

    private static func isRule(_ line: Substring) -> Bool {
        let marks = line.filter { !$0.isWhitespace }
        guard marks.count >= 3, let first = marks.first, "-*_".contains(first) else { return false }
        return marks.allSatisfy { $0 == first }
    }

    private static func unquote(_ line: Substring) -> Substring {
        var rest = line.dropFirst()
        if rest.first == " " { rest = rest.dropFirst() }
        return rest
    }

    private static func listItem(_ line: Substring) -> (marker: MarkdownDocument.Marker, text: Substring)? {
        var marker = MarkdownDocument.Marker.bullet
        var rest: Substring
        if let first = line.first, "-*+".contains(first) {
            rest = line.dropFirst()
        } else {
            let digits = line.prefix(while: \.isNumber)
            guard (1...9).contains(digits.count), let number = Int(digits) else { return nil }
            rest = line.dropFirst(digits.count)
            guard let dot = rest.first, dot == "." || dot == ")" else { return nil }
            rest = rest.dropFirst()
            marker = .number(number)
        }
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        rest = rest.drop { $0 == " " || $0 == "\t" }
        if marker == .bullet, rest.count >= 3, rest.hasPrefix("[") {
            let box = rest.prefix(3)
            if box == "[ ]" || box.lowercased() == "[x]", rest.count == 3 || rest.dropFirst(3).first == " " {
                marker = .task(done: box != "[ ]")
                rest = rest.dropFirst(3).drop { $0 == " " }
            }
        }
        return (marker, rest)
    }

    /// Lines that end a list item's text instead of continuing it.
    private static func startsBlock(_ line: Substring) -> Bool {
        line.hasPrefix(">") || line.hasPrefix("#") || fence(line) != nil || isRule(line) || line.hasPrefix("<")
    }

    /// GitHub's table delimiter row, `| --- | :---: | ---: |`, as column alignments.
    private static func tableDelimiter(_ line: Substring) -> [MarkdownDocument.Alignment]? {
        let cells = cells(line)
        guard !cells.isEmpty, line.contains("-") else { return nil }
        var alignments: [MarkdownDocument.Alignment] = []
        for cell in cells {
            let text = cell.trimmingCharacters(in: .whitespaces)
            let left = text.hasPrefix(":"), right = text.hasSuffix(":")
            let dashes = text.dropFirst(left ? 1 : 0).dropLast(right && text.count > 1 ? 1 : 0)
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            alignments.append(left && right ? .center : (right ? .trailing : .leading))
        }
        return alignments
    }

    /// A table row's cells, split on pipes outside code spans (`\|` is a literal pipe).
    private static func cells(_ line: Substring) -> [String] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|") && !text.hasSuffix("\\|") { text.removeLast() }
        var cells: [String] = []
        var current = ""
        var inCode = false
        var escaped = false
        for character in text {
            if escaped {
                if character != "|" { current.append("\\") }
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "`" {
                inCode.toggle()
                current.append(character)
            } else if character == "|" && !inCode {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }
}
