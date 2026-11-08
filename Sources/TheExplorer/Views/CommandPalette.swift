import AppKit
import Observation
import SwiftUI

/// ⌘K: go anywhere. Before you type, the folders you visit most; type a name for matching
/// folders and files on your Mac, with Find for where you are on the top line; type a path
/// starting with / or ~ to jump there, with folder completion. ↩ goes to the highlighted line,
/// ⌘↩ finds everywhere on your Mac, ⇥ completes a path, esc closes.
///
/// It never searches the list behind: that's Find's job (⌘F), whose results you can use, so
/// a search typed here is handed over to Find rather than run under the palette.
final class CommandPaletteView: NSView, NSTextFieldDelegate {
    private let workspace: Workspace
    private let theme = TableTheme()
    private let field = PaletteField()
    private let panelFill = NSColor(Theme.surface).blended(withFraction: 0.04, of: .white) ?? NSColor(Theme.surface)
    private let fieldBorder = NSColor(Theme.fieldBorder)
    private let danger = NSColor(Theme.danger)
    private let nameFont = NSFont.systemFont(ofSize: 13)
    private let detailFont = NSFont.systemFont(ofSize: 12)
    private let titleFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    private let keyFont = NSFont.systemFont(ofSize: 11)

    /// One line in the list.
    private struct Entry {
        enum Kind {
            case folder(URL)
            case file(FileItem)
            case action(() -> Void)
        }

        let kind: Kind
        let name: String
        var detail = ""
        var key = ""
        var symbol: String?
    }

    private var sections: [(title: String, entries: [Entry])] = []
    private var entries: [Entry] { sections.flatMap(\.entries) }
    private var highlighted = 0
    private var query = ""
    private var invalid = false
    private var suggestions: [URL] = []
    private var suggestionTask: Task<Void, Never>?
    private weak var model: BrowserModel?
    /// The palette's own search of your Mac, for its Files lines.
    private let fileSearch = SearchModel()
    private var lastRequest: [ObjectIdentifier: UUID] = [:]
    private var generation = 0
    private var tracking: NSTrackingArea?

    /// Where things are, worked out in `relayout`.
    private var panel = NSRect.zero
    private var rows: [(entry: Int, rect: NSRect)] = []
    private var titles: [(title: String, y: CGFloat)] = []

    private static let width: CGFloat = 640
    private static let fieldHeight: CGFloat = 52
    private static let rowHeight: CGFloat = 34

    private var isPathMode: Bool { query.hasPrefix("/") || query.hasPrefix("~") }

    init(workspace: Workspace) {
        self.workspace = workspace
        super.init(frame: .zero)
        isHidden = true
        field.delegate = self
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.systemFont(ofSize: 16)
        field.textColor = theme.text
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.placeholderAttributedString = NSAttributedString(string: "Go to a folder or file, or type a path like ~/Dev", attributes: [
            .foregroundColor: theme.textTertiary, .font: NSFont.systemFont(ofSize: 16),
        ])
        addSubview(field)
        followRequests()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    // MARK: Opening and closing

    /// Opens when a pane asks (⌘K, Go to Path…).
    private func followRequests() {
        generation += 1
        let current = generation
        withObservationTracking {
            let model = workspace.selected
            let key = ObjectIdentifier(model)
            if let request = model.omniboxRequest, request.id != lastRequest[key] {
                lastRequest[key] = request.id
                DispatchQueue.main.async { [weak self] in self?.open(request.text) }
            } else if model.omniboxRequest == nil {
                lastRequest[key] = nil
            }
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.generation == current else { return }
                self.followRequests()
            }
        }
    }

    func open(_ text: String) {
        guard let window else { return }
        model = workspace.selected
        isHidden = false
        query = text
        field.stringValue = text
        invalid = false
        highlighted = 0
        changed()
        window.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NSRange(location: (text as NSString).length, length: 0)
    }

    /// Closes the palette, handing the keyboard back to the list.
    private func close() {
        guard !isHidden else { return }
        isHidden = true
        suggestionTask?.cancel()
        fileSearch.clear()
        window?.makeFirstResponder(nil)
        let model = model
        DispatchQueue.main.async { model?.listFocusRequest += 1 }
    }

    // MARK: What it lists

    func controlTextDidChange(_ notification: Notification) {
        guard field.stringValue != query else { return }
        query = field.stringValue
        invalid = false
        highlighted = 0
        changed()
    }

    /// The query changed: the palette's own search follows it, and the lines are listed again.
    private func changed() {
        let text = isPathMode ? "" : query.trimmingCharacters(in: .whitespaces)
        if text.isEmpty {
            fileSearch.clear()
        } else {
            fileSearch.run(text: text, scope: .mac, folder: URL.home, includeHidden: false)
        }
        suggest()
        list()
    }

    private func list() {
        guard let model, !isHidden else { return }
        // Read under Observation, so search results arriving list again.
        withObservationTracking {
            sections = isPathMode ? pathSections() : (query.trimmingCharacters(in: .whitespaces).isEmpty ? startSections() : searchSections(model))
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.list() }
        }
        highlighted = min(highlighted, max(0, entries.count - 1))
        relayout()
        needsDisplay = true
    }

    private func folderEntry(_ url: URL, key: String = "") -> Entry {
        Entry(kind: .folder(url), name: url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent,
              detail: Format.path(url.deletingLastPathComponent().path), key: key)
    }

    private func startSections() -> [(String, [Entry])] {
        let current = model?.destination == .folder ? [model?.currentURL.path ?? ""] : []
        let visited = FolderVisits.shared.top(6, excluding: Set(current)).map { folderEntry($0) }
        let actions = [
            Entry(kind: .action { [weak self] in self?.model?.show(.recents) }, name: "Show recent files", key: "⇧⌘F", symbol: "clock"),
            Entry(kind: .action { [weak self] in self?.model?.show(.newFiles) }, name: "Show new files", key: "⇧⌘E", symbol: "sparkles"),
        ]
        return [("Folders you visit", visited), ("Actions", actions)].filter { !$0.1.isEmpty }
    }

    private func searchSections(_ model: BrowserModel) -> [(String, [Entry])] {
        let text = query.trimmingCharacters(in: .whitespaces)
        let lowered = text.lowercased()
        let folders = FolderVisits.shared.top(60)
            .filter { $0.lastPathComponent.lowercased().contains(lowered) }
            .prefix(3)
            .map { folderEntry($0) }
        let shownFolders = Set(folders.compactMap { entry -> URL? in if case .folder(let url) = entry.kind { url } else { nil } })
        let hits = fileSearch.visibleHits.lazy
            .filter { !shownFolders.contains($0.item.url) }
            .prefix(5)
            .map { hit in
                hit.item.isFolder ? self.folderEntry(hit.item.url)
                    : Entry(kind: .file(hit.item), name: hit.item.name, detail: Format.path(hit.item.url.deletingLastPathComponent().path))
            }
        // First, Find where you are: the results land in the list, where you can use them.
        let scope = model.destination == .folder ? Format.displayName(model.currentURL.path) : model.findScopeName
        var sections: [(String, [Entry])] = [("", [Entry(kind: .action { [weak self] in self?.find(everywhere: false) },
                                                        name: "Find “\(text)” in \(scope)", symbol: "magnifyingglass")])]
        if !folders.isEmpty { sections.append(("Folders you visit", Array(folders))) }
        if !hits.isEmpty {
            sections.append(("On your Mac", Array(hits)))
        } else if fileSearch.isRunning || fileSearch.isIndexing {
            sections.append(("Searching your Mac…", []))
        }
        if !model.destination.isRemote && !(model.destination == .folder && model.searchScope == .mac && model.isFinding) {
            sections.append(("", [Entry(kind: .action { [weak self] in self?.find(everywhere: true) },
                                        name: "Find “\(text)” everywhere on your Mac", key: "⌘↩", symbol: "globe")]))
        }
        return sections
    }

    private func pathSections() -> [(String, [Entry])] {
        suggestions.isEmpty ? [] : [("Folders", suggestions.map { folderEntry($0) })]
    }

    /// Hands what's typed to Find: where you are, or everywhere on your Mac.
    private func find(everywhere: Bool) {
        let text = query.trimmingCharacters(in: .whitespaces)
        let model = model
        close()
        model?.openFind(text, everywhere: everywhere)
    }

    /// Folder completions for a typed path, listed off the main thread.
    private func suggest() {
        suggestionTask?.cancel()
        guard isPathMode else {
            suggestions = []
            return
        }
        let query = query
        let visits = FolderVisits.shared
        let scores = visits.visits.keys.reduce(into: [String: Double]()) { $0[$1] = visits.score($1) }
        suggestionTask = Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) { Self.suggestions(for: query, scores: scores) }.value
            guard let self, !Task.isCancelled, self.query == query else { return }
            self.suggestions = found
            self.list()
        }
    }

    /// Folders matching what's typed: the contents of a folder ending in "/", otherwise siblings
    /// whose names start with the last component. The ones you visit most come first.
    nonisolated static func suggestions(for query: String, scores: [String: Double]) -> [URL] {
        let expanded = Format.expandingTilde(query)
        let endsWithSlash = query.hasSuffix("/")
        let parent = endsWithSlash ? expanded : (expanded as NSString).deletingLastPathComponent
        let prefix = endsWithSlash ? "" : (expanded as NSString).lastPathComponent.lowercased()
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: parent.isEmpty ? "/" : parent), includingPropertiesForKeys: keys) else { return [] }
        return children
            .filter { url in
                let name = url.lastPathComponent
                guard (prefix.hasPrefix(".") || !name.hasPrefix(".")) && (prefix.isEmpty || name.lowercased().hasPrefix(prefix)) else { return false }
                let values = try? url.resourceValues(forKeys: Set(keys))
                return values?.isDirectory == true && values?.isPackage != true
            }
            .sorted { lhs, rhs in
                let left = scores[lhs.standardizedFileURL.path] ?? 0
                let right = scores[rhs.standardizedFileURL.path] ?? 0
                if left != right { return left > right }
                return lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
            }
            .prefix(8)
            .map { $0 }
    }

    // MARK: Keys

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            move(1)
        case #selector(NSResponder.moveUp(_:)):
            move(-1)
        case #selector(NSResponder.insertTab(_:)):
            complete()
        case #selector(NSResponder.cancelOperation(_:)):
            close()
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.command) == true, !isPathMode, !query.isEmpty {
                find(everywhere: model?.destination.isRemote == false)
            } else {
                submit()
            }
        default:
            return false
        }
        return true
    }

    private func move(_ delta: Int) {
        let count = entries.count
        guard count > 0 else { return }
        highlighted = (highlighted + delta + count) % count
        needsDisplay = true
    }

    private func complete() {
        guard isPathMode else { return }
        let all = entries
        guard all.indices.contains(highlighted), case .folder(let url) = all[highlighted].kind else { return }
        query = Format.path(url.path) + "/"
        field.stringValue = query
        field.currentEditor()?.selectedRange = NSRange(location: (query as NSString).length, length: 0)
        highlighted = 0
        changed()
    }

    private func submit() {
        let all = entries
        if all.indices.contains(highlighted) {
            activate(all[highlighted])
        } else if isPathMode {
            if model?.goTo(path: query) == true {
                close()
            } else {
                invalid = true
                needsDisplay = true
            }
        }
    }

    private func activate(_ entry: Entry) {
        guard let model else { return }
        switch entry.kind {
        case .folder(let url):
            close()
            model.navigate(to: url)
        case .file(let item):
            // Shown where it is, selected.
            close()
            model.navigate(to: item.url.deletingLastPathComponent(), selecting: [item.url])
        case .action(let run):
            run()
            if !isHidden { close() }
        }
    }

    // MARK: Layout and drawing

    private func relayout() {
        let width = min(Self.width, bounds.width - 48)
        var y = Self.fieldHeight + 8
        rows = []
        titles = []
        var index = 0
        for (number, section) in sections.enumerated() {
            if number > 0 { y += 6 }
            // A section without a title (Find's line) has no heading to make room for.
            if !section.title.isEmpty {
                titles.append((section.title, y))
                y += 24
            }
            for _ in section.entries {
                rows.append((index, NSRect(x: 8, y: y, width: width - 16, height: Self.rowHeight)))
                y += Self.rowHeight + 1
                index += 1
            }
        }
        let height = sections.isEmpty ? Self.fieldHeight : y + 7
        panel = NSRect(x: ((bounds.width - width) / 2).rounded(), y: min(96, max(24, bounds.height * 0.12)), width: width, height: height)
        field.frame = NSRect(x: panel.minX + 46, y: panel.minY + (Self.fieldHeight - 22) / 2, width: width - 46 - 48, height: 22)
    }

    override func layout() {
        super.layout()
        relayout()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.4).setFill()
        bounds.fill()
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
        shadow.shadowBlurRadius = 30
        shadow.shadowOffset = NSSize(width: 0, height: -12)
        shadow.set()
        panelFill.setFill()
        NSBezierPath(roundedRect: panel, xRadius: 12, yRadius: 12).fill()
        NSGraphicsContext.restoreGraphicsState()
        let ring = NSBezierPath(roundedRect: panel.insetBy(dx: 0.5, dy: 0.5), xRadius: 11.5, yRadius: 11.5)
        (invalid ? danger : fieldBorder).setStroke()
        ring.stroke()

        // The field.
        let icon = theme.symbol(isPathMode ? "arrow.turn.down.right" : "magnifyingglass", size: 14, weight: .medium,
                                color: isPathMode ? theme.text : theme.textSecondary)
        icon.draw(in: NSRect(x: panel.minX + 18 + 8 - icon.size.width / 2, y: panel.minY + Self.fieldHeight / 2 - icon.size.height / 2,
                             width: icon.size.width, height: icon.size.height))
        FileCellView.drawText("esc", font: keyFont, color: theme.textTertiary, x: panel.maxX - 40, midY: panel.minY + Self.fieldHeight / 2, width: 24, alignment: .right)
        guard !sections.isEmpty else { return }
        fieldBorder.setFill()
        NSRect(x: panel.minX, y: panel.minY + Self.fieldHeight, width: panel.width, height: 1).fill()

        // Section titles, then their lines.
        for title in titles {
            FileCellView.drawText(title.title, font: titleFont, color: theme.textTertiary, x: panel.minX + 18, midY: panel.minY + title.y + 12,
                                  width: panel.width - 36)
        }
        let all = entries
        for row in rows {
            let entry = all[row.entry]
            let rect = row.rect.offsetBy(dx: panel.minX, dy: panel.minY)
            if row.entry == highlighted {
                theme.accentSoft.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
            }
            let image: NSImage = switch entry.kind {
            case .folder: theme.symbol("folder", size: 12, weight: .regular, color: theme.textSecondary)
            case .file(let item): theme.typeIcon(for: item)
            case .action: theme.symbol(entry.symbol ?? "arrow.right", size: 11.5, weight: .regular, color: theme.textSecondary)
            }
            image.draw(in: FileCellView.centered(image.size, in: NSRect(x: rect.minX + 10, y: rect.minY, width: 16, height: rect.height)))
            var right = rect.maxX - 10
            let key = row.entry == highlighted && entry.key.isEmpty ? "↩" : entry.key
            if !key.isEmpty {
                let width = ceil(TextLines.shared.line(key, font: keyFont, color: theme.textSecondary).width)
                FileCellView.drawText(key, font: keyFont, color: theme.textSecondary, x: right - width, midY: rect.midY, width: width + 2)
                right -= width + 14
            }
            let nameX = rect.minX + 36
            var nameRoom = right - nameX
            if !entry.detail.isEmpty {
                let detailWidth = min(nameRoom * 0.45, ceil(TextLines.shared.line(entry.detail, font: detailFont, color: theme.textTertiary).width))
                FileCellView.drawText(entry.detail, font: detailFont, color: theme.textTertiary, x: right - detailWidth, midY: rect.midY,
                                      width: detailWidth, truncation: .byTruncatingHead)
                nameRoom -= detailWidth + 16
            }
            FileCellView.drawText(entry.name, font: nameFont, color: theme.text, x: nameX, midY: rect.midY, width: max(0, nameRoom),
                                  truncation: .byTruncatingMiddle)
        }
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    private func entry(at event: NSEvent) -> Int? {
        let point = convert(event.locationInWindow, from: nil)
        return rows.first { $0.rect.offsetBy(dx: panel.minX, dy: panel.minY).contains(point) }?.entry
    }

    override func mouseMoved(with event: NSEvent) {
        guard let index = entry(at: event), index != highlighted else { return }
        highlighted = index
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard panel.contains(point) else { return close() }
        if let index = entry(at: event) {
            let all = entries
            if all.indices.contains(index) { activate(all[index]) }
        }
    }

    override func scrollWheel(with event: NSEvent) {}
}

/// The palette's text field.
final class PaletteField: NSTextField {}
