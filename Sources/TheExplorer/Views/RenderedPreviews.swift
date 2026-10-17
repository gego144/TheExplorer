import ImageIO
import SwiftUI

/// Colors for rendered previews: links, and JSON's keys and value types.
private enum Ink {
    static var link: Color { Theme.blue }
    static var key: Color { Theme.purple }
    static var string: Color { Theme.green }
    static var number: Color { Theme.blue }
    static var bool: Color { Theme.pink }
    static var body: Color { Theme.body }
}

/// The inspector's preview for Markdown, CSV, JSON and fonts, drawn by TheExplorer instead of
/// Quick Look. The code button flips to the file's source; expand opens it large.
struct RenderedPreview: View {
    let kind: RenderedKind
    let item: FileItem
    let model: BrowserModel
    @State private var content: RenderedContent?
    @State private var showSource = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Theme.field)
            if showSource {
                QuickLookRepresentable(url: item.url)
                    .clipShape(.rect(cornerRadius: 8))
            } else if let content {
                RenderedContentView(content: content, url: item.url, compact: true) { RenderedLinks.open($0, model: model) }
                    .clipShape(.rect(cornerRadius: 8))
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(height: kind == .font ? 210 : 270)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
        .overlay(alignment: .bottomLeading) {
            if !showSource, let summary = content?.summary, kind != .font {
                Text(summary)
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 6)
                    .frame(height: 22)
                    .background(Theme.raised.opacity(0.94), in: .rect(cornerRadius: Theme.chipRadius))
                    .overlay(RoundedRectangle(cornerRadius: Theme.chipRadius).strokeBorder(Theme.fieldBorder))
                    .padding(6)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            HStack(spacing: 4) {
                if kind != .font {
                    Button { showSource.toggle() } label: {
                        Image(systemName: showSource ? "doc.richtext" : "chevron.left.forwardslash.chevron.right")
                            .font(.system(size: 9.5, weight: .bold))
                    }
                    .buttonStyle(FloatingIconStyle())
                    .help(showSource ? "Show Preview" : "Show Source")
                }
                Button { model.quickLook([item.url]) } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(FloatingIconStyle())
                .help("Expand")
            }
            .padding(6)
        }
        // Keyed on the date and size too, so an edited file shows its changes.
        .task(id: [item.url.path, "\(item.modified?.timeIntervalSince1970 ?? 0)", "\(item.fileSize ?? 0)"]) {
            if let hit = RenderedDocuments.cached(item.url, modified: item.modified, size: item.fileSize) {
                content = hit
                return
            }
            content = nil
            // Arrowing through a folder shouldn't parse every file on the way.
            try? await Task.sleep(for: .milliseconds(70))
            guard !Task.isCancelled else { return }
            let loaded = await RenderedDocuments.load(kind, url: item.url, modified: item.modified, size: item.fileSize)
            guard !Task.isCancelled else { return }
            content = loaded
        }
    }
}

/// A rendered preview over the window (Esc or a click outside closes it), with links to other
/// Markdown, CSV, JSON and font files followed in place and Back to return. An overlay rather than a sheet, so it
/// opens and closes instantly.
struct ExpandedPreview: View {
    let model: BrowserModel
    @State private var history: [URL]
    @State private var content: RenderedContent?
    @State private var showSource = false
    @FocusState private var focused: Bool

    init(url: URL, model: BrowserModel) {
        self.model = model
        _history = State(initialValue: [url])
    }

    private var url: URL { history[history.count - 1] }

    var body: some View {
        let item = FileItem(url: url)
        let kind = item.flatMap { RenderedKind(url: url, type: $0.contentType) }
        ZStack {
            Theme.scrim
                .contentShape(.rect)
                .onTapGesture(perform: close)
            VStack(spacing: 0) {
                header(item: item, kind: kind)
                Rectangle().fill(Theme.border).frame(height: 1)
                ZStack {
                    Theme.field
                    if showSource {
                        QuickLookRepresentable(url: url)
                    } else if let content {
                        RenderedContentView(content: content, url: url, compact: false) { linked in
                            if !linked.hasDirectoryPath, RenderedKind(url: linked, type: FileItem(url: linked)?.contentType) != nil,
                               FileManager.default.fileExists(atPath: linked.path) {
                                showSource = false
                                history.append(linked)
                            } else {
                                close()
                                RenderedLinks.open(linked, model: model)
                            }
                        }
                        .id(url)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .background(Theme.background)
            .clipShape(.rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.fieldBorder))
            .shadow(color: .black.opacity(0.5), radius: 30, y: 10)
            .frame(maxWidth: 1180, maxHeight: 980)
            .padding(.horizontal, 36)
            .padding(.vertical, 28)
        }
        // Keys come here rather than to the list underneath.
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.escape) { close(); return .handled }
        .onKeyPress(.space) { close(); return .handled }
        .onKeyPress(.downArrow) { model.stepExpandedPreview(by: 1); return .handled }
        .onKeyPress(.upArrow) { model.stepExpandedPreview(by: -1); return .handled }
        .onAppear { focused = true }
        .task(id: url) {
            guard let item, let kind else { content = .failed("This file can't be previewed."); return }
            content = RenderedDocuments.cached(url, modified: item.modified, size: item.fileSize)
            if content == nil {
                content = await RenderedDocuments.load(kind, url: url, modified: item.modified, size: item.fileSize)
            }
        }
    }

    private func header(item: FileItem?, kind: RenderedKind?) -> some View {
        HStack(spacing: 10) {
            if history.count > 1 {
                Button { history.removeLast() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold)).frame(width: 18, height: 18)
                }
                .buttonStyle(GhostButtonStyle(padding: 3, tint: Theme.textSecondary))
                .keyboardShortcut("[", modifiers: .command)
                .help("Back")
            }
            if let item { ItemPreview(item: item, side: 30) }
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(content?.summary ?? item?.kindDescription ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            if kind != .font {
                Segmented(selection: $showSource, options: [(false, "Preview"), (true, "Source")])
            }
            Button("Open") { FileOpener.open([url]) }
                .buttonStyle(SubtleButtonStyle())
            Button("Done", action: close)
                .buttonStyle(SubtleButtonStyle())
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .frame(height: 54)
    }

    private func close() {
        model.expandedPreview = nil
        model.listFocusRequest += 1
    }
}

/// Opens a local link from a preview: folders in the list, files TheExplorer renders in the
/// large preview, anything else selected in its folder.
@MainActor
enum RenderedLinks {
    static func open(_ url: URL, model: BrowserModel) {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { return }
        if isFolder.boolValue {
            model.navigate(to: url)
        } else if RenderedKind(file: url) != nil {
            model.showExpandedPreview(url)
        } else {
            model.reveal(url)
        }
    }
}

private struct RenderedContentView: View {
    let content: RenderedContent
    let url: URL
    let compact: Bool
    let openLocal: (URL) -> Void

    var body: some View {
        switch content {
        case .markdown(let document):
            MarkdownView(document: document, base: url.deletingLastPathComponent(), compact: compact, openLocal: openLocal)
        case .table(let table):
            DelimitedTableView(table: table, compact: compact)
        case .json(let tree):
            JSONTreeView(tree: tree, compact: compact)
        case .font(let faces):
            FontSpecimen(faces: faces, compact: compact)
        case .failed(let message):
            VStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.warning)
                Text(message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                Text("Show the source to see the file as it is.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Markdown

private struct MarkdownView: View {
    let document: MarkdownDocument
    let base: URL
    let compact: Bool
    let openLocal: (URL) -> Void

    var body: some View {
        let style = MarkdownStyle(compact: compact, base: base)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: style.blockSpacing) {
                    ForEach(document.blocks.indices, id: \.self) { index in
                        MarkdownBlockView(block: document.blocks[index], style: style)
                            .id(index)
                    }
                }
                .frame(maxWidth: compact ? .infinity : 800, alignment: .leading)
                .padding(compact ? 12 : 32)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(compact ? .never : .automatic)
            // No text selection here: links in selectable text don't reliably open. Code blocks
            // are selectable, for copying commands.
            .tint(Ink.link)
            .environment(\.openURL, OpenURLAction { url in
                if url.scheme == "http" || url.scheme == "https" || url.scheme == "mailto" { return .systemAction }
                // "#section" jumps to a heading; "GUIDE.md" is next to this file.
                if url.scheme == nil, url.path.isEmpty, let fragment = url.fragment {
                    if let index = document.anchors[fragment.lowercased()] {
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(index, anchor: .top) }
                    }
                    return .handled
                }
                guard url.scheme == nil || url.isFileURL else { return .systemAction }
                let path = url.isFileURL ? url.path : (url.path.removingPercentEncoding ?? url.path)
                let target = path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path)
                openLocal(target.standardizedFileURL)
                return .handled
            })
        }
    }
}

private struct MarkdownStyle {
    let compact: Bool
    let base: URL

    var bodySize: CGFloat { compact ? 11.5 : 14 }
    var blockSpacing: CGFloat { compact ? 8 : 14 }

    func headingSize(_ level: Int) -> CGFloat {
        let scale: [CGFloat] = [1.75, 1.4, 1.2, 1.05, 1, 0.92]
        return bodySize * scale[min(max(level, 1), 6) - 1]
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownDocument.Block
    let style: MarkdownStyle

    var body: some View {
        switch block {
        case .heading(let level, let text, _):
            VStack(alignment: .leading, spacing: style.compact ? 4 : 6) {
                Text(text)
                    .font(.system(size: style.headingSize(level), weight: level <= 2 ? .bold : .semibold))
                    .foregroundStyle(level >= 6 ? Theme.textSecondary : Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                if level <= 2 { Rectangle().fill(Theme.border).frame(height: 1) }
            }
            .padding(.top, level <= 2 ? (style.compact ? 4 : 10) : 2)
        case .paragraph(let text):
            Text(text)
                .font(.system(size: style.bodySize))
                .foregroundStyle(Ink.body)
                .lineSpacing(style.compact ? 1.5 : 3)
                .fixedSize(horizontal: false, vertical: true)
        case .listItem(let depth, let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                markerView(marker, depth: depth)
                    .frame(minWidth: style.compact ? 12 : 16, alignment: .trailing)
                Text(text)
                    .font(.system(size: style.bodySize))
                    .foregroundStyle(marker == .task(done: true) ? Theme.textTertiary : Ink.body)
                    .strikethrough(marker == .task(done: true), color: Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(depth) * (style.compact ? 12 : 20))
        case .code(let language, let text):
            ScrollView(.horizontal) {
                Text(text)
                    .font(.system(size: style.bodySize - 1, design: .monospaced))
                    .foregroundStyle(Ink.body)
                    .fixedSize()
                    .textSelection(.enabled)
                    .padding(style.compact ? 8 : 12)
            }
            .scrollIndicators(.never)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: .rect(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
            .overlay(alignment: .topTrailing) {
                if let language, !style.compact {
                    Text(language)
                        .font(Theme.monoSmall)
                        .foregroundStyle(Theme.textTertiary)
                        .padding(6)
                }
            }
        case .quote(let blocks):
            HStack(alignment: .top, spacing: style.compact ? 8 : 12) {
                RoundedRectangle(cornerRadius: 1.5).fill(Theme.accentStrong).frame(width: 3)
                VStack(alignment: .leading, spacing: style.blockSpacing) {
                    ForEach(blocks.indices, id: \.self) { MarkdownBlockView(block: blocks[$0], style: style) }
                }
                .foregroundStyle(Theme.textSecondary)
                .opacity(0.85)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .rule:
            Rectangle().fill(Theme.border).frame(height: 1).padding(.vertical, 4)
        case .table(let table):
            MarkdownTableView(table: table, style: style)
        case .images(let images):
            FlowLayout(spacing: 6) {
                ForEach(images.indices, id: \.self) { MarkdownImageView(image: images[$0], style: style) }
            }
        }
    }

    @ViewBuilder
    private func markerView(_ marker: MarkdownDocument.Marker, depth: Int) -> some View {
        switch marker {
        case .bullet:
            Text(["•", "◦", "▪"][depth % 3])
                .font(.system(size: style.bodySize))
                .foregroundStyle(Theme.textTertiary)
        case .number(let number):
            Text("\(number).")
                .font(.system(size: style.bodySize).monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
        case .task(let done):
            Image(systemName: done ? "checkmark.square.fill" : "square")
                .font(.system(size: style.bodySize - 1))
                .foregroundStyle(done ? Theme.accent : Theme.textTertiary)
        }
    }
}

private struct MarkdownTableView: View {
    let table: MarkdownDocument.Table
    let style: MarkdownStyle

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(table.header.indices, id: \.self) { column in
                        cell(table.header[column], column: column, header: true)
                    }
                }
                .background(Theme.raised)
                ForEach(table.rows.indices, id: \.self) { row in
                    GridRow {
                        ForEach(table.rows[row].indices, id: \.self) { column in
                            cell(table.rows[row][column], column: column, header: false)
                        }
                    }
                    .background(row.isMultiple(of: 2) ? Color.clear : Theme.surface.opacity(0.6))
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.border))
            .clipShape(.rect(cornerRadius: 4))
        }
        .scrollIndicators(.never)
    }

    private func cell(_ text: AttributedString, column: Int, header: Bool) -> some View {
        let alignment: Alignment = switch table.alignments[column] {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
        return Text(text)
            .font(.system(size: style.bodySize - (style.compact ? 0.5 : 1), weight: header ? .semibold : .regular))
            .foregroundStyle(header ? Theme.text : Ink.body)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: style.compact ? 180 : 320, alignment: alignment)
            .padding(.horizontal, style.compact ? 6 : 10)
            .padding(.vertical, style.compact ? 4 : 6)
            .gridCellAnchor(.init(x: alignment == .trailing ? 1 : (alignment == .center ? 0.5 : 0), y: 0.5))
            .overlay(alignment: .trailing) { Rectangle().fill(Theme.border).frame(width: 1) }
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}

/// An image in a Markdown file. Local images load from disk (scaled down); remote ones aren't
/// fetched, since a preview shouldn't tell a server you looked at a file, so they show as a
/// chip with their description.
private struct MarkdownImageView: View {
    let image: MarkdownDocument.Image
    let style: MarkdownStyle
    @State private var loaded: NSImage?
    @State private var failed = false

    private var localURL: URL? {
        let source = image.source
        if source.contains("://") && !source.hasPrefix("file://") { return nil }
        if source.hasPrefix("data:") { return nil }
        if source.hasPrefix("file://") { return URL(string: source) }
        let path = (source.split(separator: "#").first.map(String.init) ?? source).removingPercentEncoding ?? source
        return path.hasPrefix("/") ? URL(fileURLWithPath: path) : style.base.appendingPathComponent(path).standardizedFileURL
    }

    var body: some View {
        if let loaded {
            let width = image.width.map { CGFloat($0) } ?? loaded.size.width
            Image(nsImage: loaded)
                .resizable()
                .aspectRatio(loaded.size, contentMode: .fit)
                .frame(maxWidth: width)
                .clipShape(.rect(cornerRadius: 4))
                .help(image.alt)
        } else if localURL != nil && !failed {
            RoundedRectangle(cornerRadius: 4)
                .fill(Theme.surface)
                .frame(width: min(image.width.map { CGFloat($0) } ?? 160, 160), height: 60)
                .task(id: image.source) { await load() }
        } else {
            HStack(spacing: 4) {
                Image(systemName: failed ? "photo.badge.exclamationmark" : "photo")
                    .font(.system(size: 9.5))
                Text(image.alt.isEmpty ? (URL(string: image.source)?.host ?? "image") : image.alt)
                    .lineLimit(1)
            }
            .font(.system(size: style.compact ? 10 : 11, weight: .medium))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 6)
            .frame(height: style.compact ? 18 : 20)
            .background(Theme.raised, in: .rect(cornerRadius: Theme.chipRadius))
            .help(image.source)
        }
    }

    private func load() async {
        guard let url = localURL else { return }
        let maxPixels = style.compact ? 800 : 2400
        let result: NSImage? = await Task.detached(priority: .userInitiated) {
            // Downscaled through ImageIO; SVG and anything else ImageIO can't read go through NSImage.
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
               let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
               let height = properties[kCGImagePropertyPixelHeight] as? CGFloat,
               let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                   kCGImageSourceCreateThumbnailFromImageAlways: true,
                   kCGImageSourceCreateThumbnailWithTransform: true,
                   kCGImageSourceThumbnailMaxPixelSize: maxPixels,
               ] as CFDictionary) {
                // Shown at its pixel size in points, the way GitHub shows it.
                return NSImage(cgImage: image, size: CGSize(width: width, height: height))
            }
            return NSImage(contentsOf: url)
        }.value
        if let result { loaded = result } else { failed = true }
    }
}

/// Lays views out in rows, wrapping when a row is full (badges, screenshots side by side).
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
            if x > 0 && x + size.width > width {
                x = 0
                y += row + spacing
                row = 0
            }
            x += size.width + spacing
            row = max(row, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            if x > 0 && x + size.width > bounds.width {
                x = 0
                y += row + spacing
                row = 0
            }
            view.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}

// MARK: - CSV

private struct DelimitedTableView: View {
    let table: DelimitedTable
    let compact: Bool

    var body: some View {
        let charWidth: CGFloat = compact ? 6.9 : 7.6
        let widths = table.widths.map { min(max(CGFloat($0) * charWidth + 14, 40), compact ? 220 : 300) }
        let gutter = CGFloat(String(table.rows.count).count) * charWidth + 14
        let rowHeight: CGFloat = compact ? 20 : 24
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                Section {
                    ForEach(table.rows.indices, id: \.self) { index in
                        TableLine(number: "\(index + 1)", cells: table.rows[index], widths: widths, numeric: table.numeric,
                                  gutter: gutter, height: rowHeight, compact: compact, header: false)
                            .background(index.isMultiple(of: 2) ? Color.clear : Theme.surface.opacity(0.55))
                    }
                    if table.rows.count < table.totalRows {
                        Text("Showing the first \(table.rows.count.formatted()) of \(table.totalRows.formatted())\(table.partial ? "+" : "") rows.")
                            .font(.system(size: compact ? 10.5 : 11.5))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.horizontal, 10)
                            .padding(.top, 8)
                            .padding(.bottom, compact ? 34 : 12)
                    } else if compact {
                        Color.clear.frame(height: 30) // room for the summary and buttons
                    }
                } header: {
                    TableLine(number: "", cells: table.header, widths: widths, numeric: table.numeric,
                              gutter: gutter, height: rowHeight + 2, compact: compact, header: true)
                        .background(Theme.raised)
                        .overlay(alignment: .bottom) { Rectangle().fill(Theme.fieldBorder).frame(height: 1) }
                }
            }
        }
        .scrollIndicators(compact ? .never : .automatic)
    }
}

private struct TableLine: View {
    let number: String
    let cells: [String]
    let widths: [CGFloat]
    let numeric: [Bool]
    let gutter: CGFloat
    let height: CGFloat
    let compact: Bool
    let header: Bool

    var body: some View {
        HStack(spacing: 0) {
            Text(number)
                .font(.system(size: compact ? 9.5 : 10.5, design: .monospaced))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: gutter - 8, alignment: .trailing)
                .padding(.trailing, 8)
            ForEach(cells.indices, id: \.self) { column in
                Text(cells[column].replacingOccurrences(of: "\n", with: " ↵ "))
                    .font(.system(size: compact ? 11 : 12, weight: header ? .semibold : .regular).monospacedDigit())
                    .foregroundStyle(header ? Theme.text : Ink.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: widths[column] - 12, alignment: numeric[column] && !header ? .trailing : .leading)
                    .padding(.horizontal, 6)
                    .frame(height: height)
                    .overlay(alignment: .leading) { Rectangle().fill(Theme.border).frame(width: 1) }
            }
        }
    }
}

// MARK: - JSON

private struct JSONTreeView: View {
    let tree: JSONTree
    let compact: Bool
    @State private var expanded: Set<Int>
    @State private var selected: Int?
    @State private var limit = JSONTreeView.pageSize

    private static let pageSize = 400

    init(tree: JSONTree, compact: Bool) {
        self.tree = tree
        self.compact = compact
        // The top level is open, and so is a lone container inside it ({"data": {…}}).
        var open: Set<Int> = []
        if let root = tree.nodes.first, root.isContainer {
            open.insert(0)
            let children = tree.children(of: 0)
            if children.count == 1, tree.nodes[children[0]].isContainer { open.insert(children[0]) }
        }
        _expanded = State(initialValue: open)
    }

    private struct Line {
        let index: Int
        let depth: Int
        let label: String?
        let isIndex: Bool
    }

    var body: some View {
        let (lines, more) = flatten()
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(lines, id: \.index) { line in
                    JSONRow(node: tree.nodes[line.index], label: line.label, isIndex: line.isIndex, depth: line.depth,
                            isExpanded: expanded.contains(line.index), isSelected: selected == line.index, compact: compact) {
                        toggle(line.index)
                    }
                    .equatable()
                    .contentShape(.rect)
                    .onTapGesture {
                        selected = line.index
                        if tree.nodes[line.index].isContainer { toggle(line.index) }
                    }
                    .contextMenu { menu(for: line.index) }
                    // Drags the value out as text (also makes clicks register like the file list's).
                    .draggable(tree.text(at: line.index))
                    #if DEBUG
                    .debugRowFrame(named: "json-\(line.index)")
                    #endif
                }
                if more {
                    Button("Show \(Self.pageSize) more") { limit += Self.pageSize }
                        .buttonStyle(SubtleButtonStyle())
                        .padding(8)
                }
                if compact { Color.clear.frame(height: 30) }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, compact ? 4 : 12)
        }
        .scrollIndicators(compact ? .never : .automatic)
    }

    /// The rows on screen: only open containers are walked, and only up to the limit.
    private func flatten() -> ([Line], Bool) {
        var lines: [Line] = []
        guard let root = tree.nodes.first else { return ([], false) }
        guard root.isContainer else { return ([Line(index: 0, depth: 0, label: nil, isIndex: false)], false) }
        var more = false
        func visit(_ parent: Int, depth: Int) -> Bool {
            let isArray = tree.nodes[parent].kind == .array
            var child = parent + 1
            var position = 0
            while child < Int(tree.nodes[parent].end) {
                if lines.count >= limit { more = true; return false }
                let node = tree.nodes[child]
                let label = isArray ? String(tree.isLines && parent == 0 ? position + 1 : position) : node.key
                lines.append(Line(index: child, depth: depth, label: label, isIndex: isArray))
                if node.isContainer && expanded.contains(child) && !visit(child, depth: depth + 1) { return false }
                child = Int(node.end)
                position += 1
            }
            return true
        }
        _ = visit(0, depth: 0)
        return (lines, more)
    }

    private func toggle(_ index: Int) {
        guard tree.nodes[index].isContainer else { return }
        if NSEvent.modifierFlags.contains(.option) {
            expanded.contains(index) ? collapseAll(index) : expandAll(index)
        } else if expanded.contains(index) {
            expanded.remove(index)
        } else {
            expanded.insert(index)
        }
    }

    /// Opens everything inside, up to a few thousand containers.
    private func expandAll(_ index: Int) {
        var opened = 0
        for child in index..<Int(tree.nodes[index].end) where tree.nodes[child].isContainer {
            expanded.insert(child)
            opened += 1
            if opened >= 5000 { break }
        }
    }

    private func collapseAll(_ index: Int) {
        let end = tree.nodes[index].end
        expanded = expanded.filter { $0 < index || $0 >= Int(end) }
    }

    @ViewBuilder
    private func menu(for index: Int) -> some View {
        let node = tree.nodes[index]
        Button(node.isContainer ? "Copy JSON" : "Copy Value") { copy(tree.text(at: index)) }
        Button("Copy Path") { copy(tree.path(to: index)) }
        if let key = node.key { Button("Copy Key") { copy(key) } }
        if node.isContainer {
            Divider()
            Button("Expand All") { expandAll(index) }
            Button("Collapse All") { collapseAll(index) }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct JSONRow: View, Equatable {
    let node: JSONTree.Node
    let label: String?
    let isIndex: Bool
    let depth: Int
    let isExpanded: Bool
    let isSelected: Bool
    let compact: Bool
    let onToggle: () -> Void
    @State private var hovering = HoverPreview.on

    static func == (a: Self, b: Self) -> Bool {
        a.node == b.node && a.label == b.label && a.depth == b.depth && a.isExpanded == b.isExpanded && a.isSelected == b.isSelected
    }

    var body: some View {
        HStack(spacing: 4) {
            if node.isContainer && node.count > 0 {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 12, height: 16)
                    .contentShape(.rect)
                    .highPriorityGesture(TapGesture().onEnded(onToggle))
            } else {
                Color.clear.frame(width: 12, height: 16)
            }
            if let label {
                HStack(spacing: 0) {
                    Text(label).foregroundStyle(isIndex ? Theme.textTertiary : Ink.key)
                    Text(":").foregroundStyle(Theme.textTertiary)
                }
                .lineLimit(1)
                .layoutPriority(1)
            }
            value
            Spacer(minLength: 0)
        }
        .font(.system(size: compact ? 11 : 12, design: .monospaced))
        .padding(.leading, CGFloat(depth) * (compact ? 12 : 16) + 2)
        .padding(.trailing, 6)
        .frame(height: compact ? 20 : 22)
        .background(isSelected ? Theme.accentSoft : (hovering ? Theme.hoverFill : .clear), in: .rect(cornerRadius: Theme.chipRadius))
        .hoverTracking { hovering = $0 }
        .help(node.kind == .string && node.value.count > 40 ? String(node.value.prefix(2000)) : "")
    }

    @ViewBuilder private var value: some View {
        switch node.kind {
        case .string:
            Text("\"" + String(node.value.prefix(400)).replacingOccurrences(of: "\n", with: "↵") + "\"")
                .foregroundStyle(Ink.string)
                .lineLimit(1)
                .truncationMode(.tail)
        case .number:
            Text(node.value).foregroundStyle(Ink.number).lineLimit(1)
        case .bool:
            Text(node.value).foregroundStyle(Ink.bool)
        case .null:
            Text("null").foregroundStyle(Theme.textTertiary).italic()
        case .object, .array:
            let object = node.kind == .object
            HStack(spacing: 5) {
                Text(node.count == 0 ? (object ? "{}" : "[]") : (object ? "{…}" : "[…]"))
                    .foregroundStyle(Theme.textSecondary)
                if node.count > 0 {
                    Text("\(Int(node.count).formatted()) \(object ? (node.count == 1 ? "key" : "keys") : (node.count == 1 ? "item" : "items"))")
                        .font(.system(size: compact ? 10 : 11))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .lineLimit(1)
        }
    }
}

// MARK: - Fonts

private struct FontSpecimen: View {
    let faces: FontFaces
    let compact: Bool
    @State private var face = 0
    @State private var custom = ""

    private static let pangram = "The quick brown fox jumps over the lazy dog"
    private static let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ\nabcdefghijklmnopqrstuvwxyz\n0123456789 &@?!%(.,;:)"

    var body: some View {
        let current = faces.faces[min(face, faces.faces.count - 1)]
        let line = custom.isEmpty ? (faces.sample ?? Self.pangram) : custom
        ScrollView {
            VStack(alignment: .leading, spacing: compact ? 6 : 18) {
                HStack(spacing: 8) {
                    Text(current.family)
                        .font(.system(size: compact ? 11.5 : 13, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if faces.faces.count > 1 {
                        ChromeMenu {
                            ForEach(faces.faces.indices, id: \.self) { index in
                                Button(faces.faces[index].style) { face = index }
                            }
                        } label: {
                            Text(current.style).font(.system(size: 11))
                        }
                    } else {
                        Text(current.style)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                Text(faces.sample.map { String($0.prefix(2)) } ?? "Aa")
                    .font(Font(faces.font(face, size: compact ? 60 : 140)))
                    .lineLimit(1)
                    .minimumScaleFactor(0.3)
                Text(faces.sample ?? Self.alphabet)
                    .font(Font(faces.font(face, size: compact ? 13 : 24)))
                    .foregroundStyle(Ink.body)
                    .fixedSize(horizontal: false, vertical: true)
                if !compact {
                    TextField("", text: $custom, prompt: Text("Type to try your own text").foregroundStyle(Theme.textTertiary))
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .formField()
                        .frame(maxWidth: 360)
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach([12, 16, 24, 36, 48, 72], id: \.self) { size in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text("\(size)")
                                    .font(Theme.monoSmall)
                                    .foregroundStyle(Theme.textTertiary)
                                    .frame(width: 22, alignment: .trailing)
                                Text(line)
                                    .font(Font(faces.font(face, size: CGFloat(size))))
                                    .lineLimit(1)
                            }
                        }
                    }
                    if faces.faces.count > 1 {
                        Rectangle().fill(Theme.border).frame(height: 1)
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(faces.faces.indices, id: \.self) { index in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(faces.faces[index].style)
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(Theme.textTertiary)
                                    Text(line)
                                        .font(Font(faces.font(index, size: 26)))
                                        .lineLimit(1)
                                }
                                .contentShape(.rect)
                                .onTapGesture { face = index }
                            }
                        }
                    }
                }
            }
            .padding(compact ? 12 : 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(compact ? .never : .automatic)
    }
}
