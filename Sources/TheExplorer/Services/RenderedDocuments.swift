import CoreText
import Foundation
import UniformTypeIdentifiers

/// The files the inspector draws itself instead of handing to Quick Look, which shows Markdown
/// and JSON as plain text.
enum RenderedKind: Sendable, Equatable {
    case markdown, table, json, font

    init?(url: URL, type: UTType?) {
        switch url.pathExtension.lowercased() {
        case "md", "markdown", "mdown", "mkd", "mkdn", "mdx": self = .markdown
        case "csv", "tsv": self = .table
        case "json", "jsonc", "jsonl", "ndjson", "geojson", "webmanifest", "har": self = .json
        default:
            guard let type else { return nil }
            if type.conforms(to: .font) { self = .font }
            else if type.identifier == "net.daringfireball.markdown" { self = .markdown }
            else if type.conforms(to: .commaSeparatedText) || type.conforms(to: .tabSeparatedText) { self = .table }
            else if type.conforms(to: .json) { self = .json }
            else { return nil }
        }
    }

    /// For a file on disk, when it's small enough to render.
    init?(file url: URL) {
        guard url.isFileURL, let item = FileItem(url: url), !item.isFolder, !item.isPackage,
              let kind = RenderedKind(url: url, type: item.contentType), (item.fileSize ?? 0) <= kind.maxBytes else { return nil }
        self = kind
    }

    /// Bigger files go to Quick Look. Tables only ever read their first rows, so any size works.
    var maxBytes: Int64 {
        switch self {
        case .markdown: 4_000_000
        case .json: 24_000_000
        case .table: .max
        case .font: 500_000_000
        }
    }
}

enum RenderedContent: Sendable {
    case markdown(MarkdownDocument)
    case table(DelimitedTable)
    case json(JSONTree)
    case font(FontFaces)
    case failed(String)

    /// A short description: "1,204 rows · 8 columns", "Object · 12 keys"…
    var summary: String? {
        switch self {
        case .markdown, .failed: return nil
        case .table(let table):
            let rows = table.totalRows.formatted() + (table.partial ? "+" : "")
            return "\(rows) \(table.totalRows == 1 ? "row" : "rows") · \(table.columns) \(table.columns == 1 ? "column" : "columns")"
        case .json(let tree):
            guard let root = tree.nodes.first else { return nil }
            let count = Int(root.count)
            switch root.kind {
            case _ where tree.isLines: return "\(count.formatted()) \(count == 1 ? "line" : "lines")"
            case .object: return "Object · \(count.formatted()) \(count == 1 ? "key" : "keys")"
            case .array: return "Array · \(count.formatted()) \(count == 1 ? "item" : "items")"
            default: return "A single value"
            }
        case .font(let faces):
            return faces.faces.count == 1 ? faces.faces[0].style : "\(faces.faces.count) styles"
        }
    }
}

/// The faces in a font file. Fonts are used straight from the file, never installed.
struct FontFaces: @unchecked Sendable {
    struct Face: @unchecked Sendable {
        let descriptor: CTFontDescriptor
        let family: String
        let style: String
    }

    let faces: [Face]
    /// What to show when the font has no Latin letters (symbols, CJK, emoji…): its own
    /// characters, so the preview never falls back to another font.
    let sample: String?

    init?(url: URL) {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              !descriptors.isEmpty else { return nil }
        faces = descriptors.map { descriptor in
            Face(descriptor: descriptor,
                 family: CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String ?? url.deletingPathExtension().lastPathComponent,
                 style: CTFontDescriptorCopyAttribute(descriptor, kCTFontStyleNameAttribute) as? String ?? "Regular")
        }
        let font = CTFontCreateWithFontDescriptor(descriptors[0], 12, nil)
        let characters = CTFontCopyCharacterSet(font)
        if CFCharacterSetIsLongCharacterMember(characters, 0x41) && CFCharacterSetIsLongCharacterMember(characters, 0x61) {
            sample = nil
        } else {
            var found = ""
            var count = 0
            var scalar: UInt32 = 0x21
            while count < 48 && scalar < 0x30000 {
                if CFCharacterSetIsLongCharacterMember(characters, scalar), let value = Unicode.Scalar(scalar),
                   !value.properties.isWhitespace, value.properties.generalCategory != .control, value.properties.generalCategory != .format {
                    found.unicodeScalars.append(value)
                    count += 1
                }
                scalar += 1
            }
            sample = found
        }
    }

    func font(_ face: Int, size: CGFloat) -> CTFont {
        CTFontCreateWithFontDescriptor(faces[min(face, faces.count - 1)].descriptor, size, nil)
    }
}

/// Reads and parses files for the rendered previews off the main thread, keeping the last few,
/// so stepping back to a file (or expanding its preview) is instant.
@MainActor
enum RenderedDocuments {
    private struct Key: Hashable {
        let path: String
        let modified: Date?
        let size: Int64?
    }

    private static var cache: [Key: RenderedContent] = [:]
    private static var order: [Key] = []

    /// Counting a table's rows stops after this much; bigger files say "+".
    nonisolated static let tableScanLimit = 512_000_000

    static func cached(_ url: URL, modified: Date?, size: Int64?) -> RenderedContent? {
        cache[Key(path: url.path, modified: modified, size: size)]
    }

    static func load(_ kind: RenderedKind, url: URL, modified: Date?, size: Int64?) async -> RenderedContent {
        let key = Key(path: url.path, modified: modified, size: size)
        if let hit = cache[key] { return hit }
        let content = await Task.detached(priority: .userInitiated) { read(kind, url: url) }.value
        if cache.updateValue(content, forKey: key) == nil { order.append(key) }
        if order.count > 12 { cache[order.removeFirst()] = nil }
        return content
    }

    nonisolated static func read(_ kind: RenderedKind, url: URL) -> RenderedContent {
        if kind == .font {
            return FontFaces(url: url).map(RenderedContent.font) ?? .failed("This font couldn't be read.")
        }
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return .failed("This file couldn't be read.") }
        switch kind {
        case .markdown:
            let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) ?? ""
            return .markdown(MarkdownDocument(text))
        case .table:
            let ext = url.pathExtension.lowercased()
            var table = DelimitedTable(data.count > tableScanLimit ? data.prefix(tableScanLimit) : data,
                                       delimiter: ext == "tsv" ? 0x09 : nil)
            table.partial = data.count > tableScanLimit
            return .table(table)
        case .json:
            let ext = url.pathExtension.lowercased()
            do {
                return .json(try JSONTree(data, lines: ext == "jsonl" || ext == "ndjson"))
            } catch {
                return .failed("Not valid JSON. " + ((error as? LocalizedError)?.errorDescription ?? ""))
            }
        case .font:
            return .failed("")
        }
    }
}
