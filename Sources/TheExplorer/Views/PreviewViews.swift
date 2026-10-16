import Quartz
import SwiftUI
import UniformTypeIdentifiers

/// The large preview at the top of the inspector: the file itself for documents, images,
/// media and text, or the table of contents for zip archives.
struct FilePreview: View {
    enum Kind { case quickLook, archive }

    let item: FileItem
    let model: BrowserModel

    static func kind(for item: FileItem) -> Kind? {
        guard !item.isFolder, !item.isPackage, let type = item.contentType else { return nil }
        if type.conforms(to: .zip) { return .archive }
        if type.conforms(to: .application) || type.conforms(to: .archive) || type.conforms(to: .diskImage) { return nil }
        if type.conforms(to: .content) || type.conforms(to: .text) || type.conforms(to: .sourceCode)
            || type.conforms(to: .json) || type.conforms(to: .propertyList) || type.conforms(to: .threeDContent) {
            return .quickLook
        }
        return nil
    }

    var body: some View {
        switch Self.kind(for: item) {
        case .quickLook: InlineQuickLook(url: item.url, onExpand: { model.quickLook([item.url]) })
        case .archive: ArchiveContentsView(url: item.url, archiveSize: item.fileSize, model: model)
        case nil: EmptyView()
        }
    }
}

/// A live Quick Look preview (text, code, PDFs, images, video, Office documents…). It mounts
/// after a short pause, so arrowing through a folder doesn't render every file on the way.
private struct InlineQuickLook: View {
    let url: URL
    let onExpand: () -> Void
    @State private var ready = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Theme.field)
            if ready {
                QuickLookRepresentable(url: url)
                    .clipShape(.rect(cornerRadius: 8))
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(height: 200)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
        .overlay(alignment: .bottomTrailing) {
            // Always shown: the preview is an AppKit view, which swallows hover, so a
            // hover-only button would rarely appear.
            Button(action: onExpand) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(FloatingIconStyle())
            .padding(6)
            .help("Quick Look (Space)")
        }
        .task(id: url) {
            ready = false
            try? await Task.sleep(for: .milliseconds(140))
            ready = !Task.isCancelled
        }
    }
}

private struct QuickLookRepresentable: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .compact) ?? QLPreviewView()
        view.autostarts = false
        view.shouldCloseWithWindow = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) as URL? != url {
            view.previewItem = url as NSURL
        }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.close()
    }
}

// MARK: - Zip contents

/// What's inside a zip, as an expandable tree, without unpacking it. Double-click a file to
/// preview it.
private struct ArchiveContentsView: View {
    let url: URL
    let archiveSize: Int64?
    let model: BrowserModel

    private enum Load: Sendable {
        case loading
        case loaded(ZipArchive, ArchiveTree)
        case failed(String)
    }

    @State private var load = Load.loading
    @State private var expanded: Set<String> = []
    @State private var selected: String?
    @State private var limit = ArchiveContentsView.pageSize
    @State private var previewError: String?
    @State private var opening: String?

    private static let pageSize = 300

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch load {
            case .loading:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Reading archive…").foregroundStyle(Theme.textTertiary)
                }
                .font(.system(size: 11))
                .frame(maxWidth: .infinity, minHeight: 60)
            case .failed(let message):
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            case .loaded(let archive, let tree):
                summary(tree)
                rows(archive, tree)
                if let previewError {
                    Text(previewError)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.warning)
                }
            }
        }
        .task(id: url) {
            let url = url
            load = .loading
            expanded = []
            limit = Self.pageSize
            let result: Load = await Task.detached(priority: .userInitiated) {
                do {
                    let archive = try ZipArchive(url: url)
                    return .loaded(archive, ArchiveTree(archive))
                } catch {
                    return .failed((error as? LocalizedError)?.errorDescription ?? "Couldn't read this archive.")
                }
            }.value
            guard !Task.isCancelled else { return }
            // A zip of one folder opens straight into it.
            if case .loaded(_, let tree) = result, tree.roots.count == 1, tree.roots[0].isDirectory {
                expanded = [tree.roots[0].path]
            }
            load = result
        }
    }

    private func summary(_ tree: ArchiveTree) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                SectionCaption(title: "Contents")
                Spacer()
                Text("\(tree.fileCount.formatted()) \(tree.fileCount == 1 ? "file" : "files")")
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.textSecondary)
            }
            Text(sizeLine(tree))
                .font(Theme.monoSmall)
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private func sizeLine(_ tree: ArchiveTree) -> String {
        var line = Format.bytes(tree.totalSize) + " unpacked"
        if let archiveSize, tree.totalSize > 0 {
            let saved = 1 - Double(archiveSize) / Double(tree.totalSize)
            line += saved > 0.01 ? " · \(Int((saved * 100).rounded()))% smaller zipped" : " · stored uncompressed"
        }
        return line
    }

    @ViewBuilder
    private func rows(_ archive: ZipArchive, _ tree: ArchiveTree) -> some View {
        let visible = flatten(tree.roots)
        VStack(spacing: 1) {
            ForEach(visible.prefix(limit), id: \.node.id) { row in
                // Set up like the file list's rows: gestures outside the equatable row, and
                // draggable (which also makes double-clicks register reliably).
                ArchiveRow(
                    node: row.node,
                    depth: row.depth,
                    isExpanded: expanded.contains(row.node.path),
                    isSelected: selected == row.node.path,
                    isOpening: opening == row.node.path,
                    onToggle: { toggle(row.node) }
                )
                .equatable()
                .contentShape(.rect)
                .onTapGesture { selected = row.node.path }
                .simultaneousGesture(TapGesture(count: 2).onEnded { open(row.node, in: archive) })
                .draggable(ArchiveItemTransfer(archive: archive, path: row.node.path, isDirectory: row.node.isDirectory))
                .help(row.node.path)
                #if DEBUG
                .debugRowFrame(named: row.node.path)
                #endif
            }
        }
        .padding(4)
        .background(Theme.field, in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
        if visible.count > limit {
            Button("Show \(min(Self.pageSize, visible.count - limit)) more of \((visible.count - limit).formatted())") {
                limit += Self.pageSize
            }
            .buttonStyle(SubtleButtonStyle())
        } else if tree.fileCount > 0 {
            Text("Double-click a file to preview it.")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private struct VisibleRow {
        let node: ArchiveTree.Node
        let depth: Int
    }

    /// The rows on screen: only expanded folders are walked.
    private func flatten(_ nodes: [ArchiveTree.Node]) -> [VisibleRow] {
        var result: [VisibleRow] = []
        func visit(_ nodes: [ArchiveTree.Node], depth: Int) {
            for node in nodes {
                result.append(VisibleRow(node: node, depth: depth))
                if node.isDirectory && expanded.contains(node.path) { visit(node.children, depth: depth + 1) }
            }
        }
        visit(nodes, depth: 0)
        return result
    }

    private func toggle(_ node: ArchiveTree.Node) {
        if expanded.contains(node.path) {
            expanded = expanded.filter { $0 != node.path && !$0.hasPrefix(node.path + "/") }
        } else {
            expanded.insert(node.path)
        }
    }

    private func open(_ node: ArchiveTree.Node, in archive: ZipArchive) {
        if node.isDirectory { toggle(node); return }
        guard let index = node.entry, opening == nil else { return }
        let entry = archive.entries[index]
        previewError = nil
        opening = node.path
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try PreviewFiles.unpack(entry, from: archive) }
            }.value
            opening = nil
            switch result {
            case .success(let file): model.preview(file)
            case .failure(let error): previewError = (error as? LocalizedError)?.errorDescription ?? "Couldn't unpack this file."
            }
        }
    }
}

private struct ArchiveRow: View, Equatable {
    let node: ArchiveTree.Node
    let depth: Int
    let isExpanded: Bool
    let isSelected: Bool
    let isOpening: Bool
    let onToggle: () -> Void
    @State private var hovering = HoverPreview.on

    static func == (a: Self, b: Self) -> Bool {
        a.node.path == b.node.path && a.depth == b.depth && a.isExpanded == b.isExpanded
            && a.isSelected == b.isSelected && a.isOpening == b.isOpening
    }

    var body: some View {
        HStack(spacing: 4) {
            Group {
                if node.isDirectory {
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
            }
            Image(systemName: node.isDirectory ? "folder.fill" : "doc")
                .font(.system(size: 10))
                .foregroundStyle(node.isDirectory ? Theme.accent : Theme.textTertiary)
                .frame(width: 13)
            Text(node.name)
                .font(.system(size: 11.5, weight: node.isDirectory ? .medium : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            if isOpening {
                ProgressView().controlSize(.mini)
            } else {
                Text(Format.bytes(node.size))
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
        }
        .padding(.leading, CGFloat(depth) * 12 + 2)
        .padding(.trailing, 6)
        .frame(height: 22)
        .background(isSelected ? Theme.accentSoft : (hovering ? Theme.hoverFill : .clear), in: .rect(cornerRadius: Theme.chipRadius))
        .hoverTracking { hovering = $0 }
        .clickable()
    }
}

/// Files unpacked for previewing, kept in a temporary folder that's cleared at launch.
enum PreviewFiles {
    nonisolated(unsafe) private static var cleared = false
    private static let lock = NSLock()

    /// Where an archive path unpacks to. Paths come from the archive, so "..", "." and absolute
    /// paths are dropped to keep every file inside the preview folder.
    static func destination(forPath path: String, in archive: URL) throws -> URL {
        let folder = folder(for: archive)
        let parts = path.split(separator: "/").filter { $0 != ".." && $0 != "." && !$0.isEmpty }
        guard !parts.isEmpty else { throw ZipArchive.Failure.corrupt }
        let destination = parts.reduce(folder) { $0.appendingPathComponent(String($1)) }.standardizedFileURL
        guard destination.path.hasPrefix(folder.standardizedFileURL.path + "/") else { throw ZipArchive.Failure.corrupt }
        return destination
    }

    /// Unpacks one file (once; later previews reuse it) and returns where it is.
    static func unpack(_ entry: ZipArchive.Entry, from archive: ZipArchive) throws -> URL {
        let destination = try destination(forPath: entry.path, in: archive.url)
        if !FileManager.default.fileExists(atPath: destination.path) {
            try archive.extract(entry, to: destination)
        }
        return destination
    }

    /// Unpacks a file, or a folder with everything in it, and returns where it is.
    static func unpack(path: String, isDirectory: Bool, from archive: ZipArchive) throws -> URL {
        guard isDirectory else {
            guard let entry = archive.entries.first(where: { $0.path == path }) else { throw ZipArchive.Failure.corrupt }
            return try unpack(entry, from: archive)
        }
        let folder = try destination(forPath: path, in: archive.url)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for entry in archive.entries where entry.path.hasPrefix(path + "/") {
            if entry.isDirectory {
                try FileManager.default.createDirectory(at: try destination(forPath: entry.path, in: archive.url),
                                                        withIntermediateDirectories: true)
            } else {
                _ = try unpack(entry, from: archive)
            }
        }
        return folder
    }

    private static func folder(for archive: URL) -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TheExplorer Previews", isDirectory: true)
        lock.lock()
        if !cleared {
            cleared = true
            try? FileManager.default.removeItem(at: root)
        }
        lock.unlock()
        // One folder per archive version, so a changed archive never shows stale files.
        let modified = (try? archive.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?
            .timeIntervalSince1970 ?? 0
        let key = String(UInt64(bitPattern: Int64(archive.path.hashValue)) ^ UInt64(modified), radix: 36)
        return root.appendingPathComponent(key, isDirectory: true)
    }
}

/// A file or folder inside a zip, dragged out of the inspector. It's unpacked only when dropped.
private struct ArchiveItemTransfer: Transferable {
    let archive: ZipArchive
    let path: String
    let isDirectory: Bool

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .data) { item in
            SentTransferredFile(try PreviewFiles.unpack(path: item.path, isDirectory: item.isDirectory, from: item.archive))
        }
    }
}
