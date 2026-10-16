import AppKit
import Observation
import SwiftUI

enum Destination: Hashable {
    case folder
    /// Documents you've opened, like Finder's Recents.
    case recents
    /// Files and folders that appeared recently.
    case newFiles
    case storage
}

enum NewItemKind {
    case folder
    case file

    var title: String { self == .folder ? "New Folder" : "New File" }
}

enum SortKey: String, CaseIterable {
    case name, kind, size, modified, created
    /// The list's own date column (e.g. when it was opened, in Recents).
    case date
}

struct SortSpec: Equatable {
    var key: SortKey
    var ascending: Bool

    /// The default everywhere: most recently changed first.
    static let byChanged = SortSpec(key: .modified, ascending: false)

    /// Clicking the active column flips direction; a new column starts in its natural order.
    func toggled(to key: SortKey) -> SortSpec {
        if key == self.key { return SortSpec(key: key, ascending: !ascending) }
        return SortSpec(key: key, ascending: key == .name || key == .kind)
    }
}

/// Asks the command bar to start editing, optionally pre-filled (e.g. with the current path).
struct OmniboxRequest: Equatable {
    let id = UUID()
    var text: String
}

/// Sorts list rows. Each row's key is computed once and only indices move during the sort,
/// so tens of thousands of rows sort in milliseconds.
@MainActor
enum RowSorter {
    static func sorted(_ rows: [ListRow], by spec: SortSpec, foldersFirst: Bool = false,
                       folderSize: (String) -> Int64? = { _ in nil }) -> [ListRow] {
        switch spec.key {
        case .name:
            return sort(rows, keys: rows.map(\.item.name), spec, foldersFirst) { $0.localizedStandardCompare($1) }
        case .kind:
            return sort(rows, keys: rows.map { TypeChip.style(for: $0.item).label }, spec, foldersFirst) { $0.compare($1) }
        case .size:
            let keys = rows.map { row in row.size ?? (row.item.isFolder ? folderSize(row.item.path) : nil) ?? -1 }
            return sort(rows, keys: keys, spec, foldersFirst) { $0 == $1 ? .orderedSame : ($0 < $1 ? .orderedAscending : .orderedDescending) }
        case .modified:
            return sort(rows, keys: rows.map { $0.item.modified ?? .distantPast }, spec, foldersFirst) { $0.compare($1) }
        case .created:
            return sort(rows, keys: rows.map { $0.item.created ?? .distantPast }, spec, foldersFirst) { $0.compare($1) }
        case .date:
            return sort(rows, keys: rows.map { $0.date ?? .distantPast }, spec, foldersFirst) { $0.compare($1) }
        }
    }

    private static func sort<Key>(_ rows: [ListRow], keys: [Key], _ spec: SortSpec, _ foldersFirst: Bool,
                                  compare: (Key, Key) -> ComparisonResult) -> [ListRow] {
        let folders = foldersFirst ? rows.map(\.item.isFolder) : []
        let order = rows.indices.sorted { a, b in
            if foldersFirst && folders[a] != folders[b] { return folders[a] }
            let result = compare(keys[a], keys[b])
            if result == .orderedSame {
                return rows[a].item.name.localizedStandardCompare(rows[b].item.name) == .orderedAscending
            }
            return spec.ascending ? result == .orderedAscending : result == .orderedDescending
        }
        return order.map { rows[$0] }
    }
}

/// Everything one window needs: where we are, history, what's selected, and how it's shown.
@MainActor
@Observable
final class BrowserModel: Identifiable {
    var destination: Destination = .folder
    private(set) var currentURL: URL
    private(set) var items: [FileItem] = [] { didSet { rebuildRows() } }
    /// Folders shown expanded inline, and the contents loaded for them.
    private(set) var expanded: Set<URL> = []
    @ObservationIgnored private var children: [URL: [FileItem]] = [:]
    /// The folder as shown: hidden files and the kind filter applied, sorted. Rebuilt only when
    /// the listing, sort or filters change, never while rendering.
    private(set) var rows: [ListRow] = []
    /// Largest size among `rows`, for scaling the size bars.
    private(set) var maxSize: Int64 = 0
    /// Counts for the folder itself, not counting the contents of expanded folders.
    private(set) var folderCount = 0
    private(set) var fileCount = 0
    private(set) var hiddenCount = 0
    /// Capacity of the volume holding the current folder, refreshed with each listing.
    private(set) var volume: VolumeUsage?
    private(set) var isLoading = false
    private(set) var loadError: String?
    private(set) var backStack: [URL] = []
    private(set) var forwardStack: [URL] = []

    var selection: Set<URL> = []
    var sort: SortSpec { didSet { rebuildRows() } }
    var kindFilter: KindFilter = .all { didSet { rebuildRows() } }
    var previewURL: URL?
    /// What the Quick Look panel steps through with the arrow keys.
    private(set) var previewItems: [URL] = []
    /// Whether stepping through the preview moves the selection with it.
    @ObservationIgnored private var previewMovesSelection = false

    var searchText = ""
    var searchScope: SearchScope = .folder

    var showHidden: Bool {
        didSet {
            // Like Finder, showing hidden files sticks for new tabs too.
            Prefs.shared.showHidden = showHidden
            rebuildRows()
        }
    }
    var foldersFirst: Bool {
        didSet {
            Prefs.shared.foldersFirst = foldersFirst
            rebuildRows()
        }
    }

    var renaming: FileItem?
    /// Set to show the name prompt for a new folder or file in the current folder.
    var creating: NewItemKind?
    /// Set to put the cursor in the path/search bar.
    var omniboxRequest: OmniboxRequest?
    /// Bumped to move keyboard focus back to the file list.
    var listFocusRequest = 0

    let search = SearchModel()
    let recents = RecentsModel(mode: .opened)
    let newFiles = RecentsModel(mode: .new)
    @ObservationIgnored private var started = false
    @ObservationIgnored private var pendingSelection: Set<String>?
    @ObservationIgnored private var listingFailed = false
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private lazy var watcher = DirectoryWatcher { [weak self] in self?.reload(keepSelection: true) }
    @ObservationIgnored private var sizeObserver: NSObjectProtocol?

    init(url: URL? = nil) {
        let prefs = Prefs.shared
        showHidden = prefs.showHidden
        foldersFirst = prefs.foldersFirst
        sort = prefs.defaultSort
        let start = url ?? prefs.startURL
        currentURL = FileManager.default.fileExists(atPath: start.path) ? start : .home
        sizeObserver = NotificationCenter.default.addObserver(forName: FolderSizeStore.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.folderSizesChanged() }
        }
    }

    deinit {
        if let sizeObserver { NotificationCenter.default.removeObserver(sizeObserver) }
    }

    /// Loads the first listing. Kept out of init because SwiftUI may construct throwaway models.
    func start() {
        guard !started else { return }
        started = true
        reload()
    }

    // MARK: - Derived state

    var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    private func rebuildRows() {
        var folders = 0
        var files = 0
        var hidden = 0
        for item in items {
            if item.isHidden { hidden += 1 }
            guard (showHidden || !item.isHidden) && kindFilter.matches(isFolder: item.isFolder) else { continue }
            if item.isFolder { folders += 1 } else { files += 1 }
        }
        var flattened: [ListRow] = []
        flattened.reserveCapacity(items.count)
        appendRows(of: items, depth: 0, to: &flattened)
        rows = flattened
        folderCount = folders
        fileCount = files
        hiddenCount = showHidden ? 0 : hidden
        updateMaxSize()
    }

    /// One level, filtered and sorted, with each expanded folder's contents right below it.
    private func appendRows(of items: [FileItem], depth: Int, to output: inout [ListRow]) {
        let sizes = FolderSizeStore.shared
        let level = items.compactMap { item -> ListRow? in
            guard (showHidden || !item.isHidden) && kindFilter.matches(isFolder: item.isFolder) else { return nil }
            return ListRow(item: item, size: item.isFolder ? nil : item.fileSize, liveFolderSize: item.isFolder,
                           date: item.modified, depth: depth,
                           expansion: item.isFolder ? expanded.contains(item.url) : nil)
        }
        for row in RowSorter.sorted(level, by: sort, foldersFirst: foldersFirst, folderSize: { sizes.size(for: $0)?.bytes }) {
            output.append(row)
            if row.expansion == true, let contents = children[row.item.url] {
                appendRows(of: contents, depth: depth + 1, to: &output)
            }
        }
    }

    // MARK: - Inline expansion

    func toggleExpanded(_ url: URL) {
        if expanded.contains(url) { collapse(url) } else { expand(url) }
    }

    func expand(_ url: URL) {
        guard !expanded.contains(url) else { return }
        expanded.insert(url)
        loadChildren(of: [url])
    }

    /// Collapses a folder and everything expanded inside it. Selected items that disappear
    /// hand their selection to the folder, as in Finder.
    func collapse(_ url: URL) {
        guard expanded.contains(url) else { return }
        let prefix = url.path + "/"
        let isInside = { (other: URL) in other.path.hasPrefix(prefix) }
        expanded = expanded.filter { $0 != url && !isInside($0) }
        children = children.filter { $0.key != url && !isInside($0.key) }
        if selection.contains(where: isInside) {
            selection = selection.filter { !isInside($0) }.union([url])
        }
        rebuildRows()
    }

    private func loadChildren(of folders: [URL]) {
        guard !folders.isEmpty else { return }
        Task { [weak self] in
            let listings = await Task.detached(priority: .userInitiated) {
                folders.map { folder in (folder, (try? Self.listContents(of: folder)) ?? []) }
            }.value
            guard let self else { return }
            var measure: [String] = []
            for (folder, contents) in listings where self.expanded.contains(folder) {
                self.children[folder] = contents
                measure += contents.filter(\.isFolder).map(\.path)
            }
            self.rebuildRows()
            FolderSizeStore.shared.request(measure)
        }
    }

    /// Everything listed: the folder's items plus the contents of expanded folders.
    var listedItems: [FileItem] {
        children.isEmpty ? items : items + expanded.compactMap { children[$0] }.joined()
    }

    nonisolated static func listContents(of url: URL) throws -> [FileItem] {
        try FileManager.default
            .contentsOfDirectory(at: url, includingPropertiesForKeys: FileItem.resourceKeys, options: [])
            .map { child in
                let values = (try? child.resourceValues(forKeys: Set(FileItem.resourceKeys))) ?? URLResourceValues()
                return FileItem(url: child, values: values)
            }
    }

    private func updateMaxSize() {
        let sizes = FolderSizeStore.shared
        var largest: Int64 = 0
        for row in rows {
            let size = row.size ?? (row.liveFolderSize ? sizes.size(for: row.item.path)?.bytes : nil) ?? 0
            if size > largest { largest = size }
        }
        if largest != maxSize { maxSize = largest }
    }

    /// Folder sizes arrive in batches; only a size sort needs the rows reordered.
    private func folderSizesChanged() {
        guard destination == .folder, !items.isEmpty else { return }
        if sort.key == .size {
            rebuildRows()
        } else {
            updateMaxSize()
        }
    }

    var selectedItems: [FileItem] {
        listedItems.filter { selection.contains($0.url) }
    }

    var title: String {
        switch destination {
        case .recents: "Recents"
        case .newFiles: "New"
        case .storage: "Storage"
        case .folder: FileManager.default.displayName(atPath: currentURL.path)
        }
    }

    /// URLs selected in whichever view is showing; what menu commands act on.
    var activeSelection: Set<URL> {
        if isSearching { return search.selection }
        switch destination {
        case .folder: return selection
        case .recents: return recents.selection
        case .newFiles: return newFiles.selection
        case .storage:
            let storage = StorageModel.shared
            guard let id = storage.selection, let node = storage.focus?.children.first(where: { $0.id == id }),
                  node.kind != .otherFiles else { return [] }
            return [node.url]
        }
    }

    var canGoUp: Bool { destination == .folder && !currentURL.isRoot }

    // MARK: - Navigation

    func show(_ destination: Destination) {
        searchText = ""
        self.destination = destination
    }

    func navigate(to url: URL, select: URL? = nil, recordHistory: Bool = true) {
        navigate(to: url, selecting: select.map { [$0] } ?? [], recordHistory: recordHistory)
    }

    func navigate(to url: URL, selecting: [URL], recordHistory: Bool = true) {
        let url = url.standardizedFileURL
        searchText = ""
        destination = .folder
        if url != currentURL {
            if recordHistory {
                backStack.append(currentURL)
                forwardStack.removeAll()
            }
            currentURL = url
            expanded = []
            children = [:]
            items = []
            selection = []
            pendingSelection = nil
            UserDefaults.standard.set(url.path, forKey: "lastPath")
        }
        reload(selecting: selecting.isEmpty ? nil : selecting.map(\.standardizedFileURL))
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(currentURL)
        navigate(to: previous, select: currentURL, recordHistory: false)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(currentURL)
        navigate(to: next, recordHistory: false)
    }

    func goUp() {
        guard canGoUp else { return }
        navigate(to: currentURL.deletingLastPathComponent(), select: currentURL)
    }

    /// Navigates to a typed path. File paths open their folder with the file selected.
    @discardableResult
    func goTo(path raw: String) -> Bool {
        let expanded = (raw.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        guard !expanded.isEmpty else { return false }
        let url = URL(fileURLWithPath: expanded)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return false }
        if isDir.boolValue {
            navigate(to: url)
        } else {
            reveal(url)
        }
        return true
    }

    /// Shows an item in its enclosing folder, selected.
    func reveal(_ url: URL) {
        navigate(to: url.deletingLastPathComponent(), select: url)
    }

    func openFavorite(_ path: String) {
        let url = URL(fileURLWithPath: path)
        guard let favorite = FavoritesStore.shared.favorites.first(where: { $0.path == path }) else { return }
        if favorite.isDirectory {
            navigate(to: url)
        } else {
            reveal(url)
        }
    }

    // MARK: - Loading

    func reload(keepSelection: Bool = false, selecting: [URL]? = nil) {
        let url = currentURL
        // Survives being superseded (e.g. the folder watcher reloading right after a drop).
        if let selecting { pendingSelection = Set(selecting.map(\.standardizedFileURL.path)) }
        let previousSelection = selection
        loadTask?.cancel()
        isLoading = true
        loadTask = Task { [weak self] in
            let listing = Task.detached(priority: .userInitiated) { () -> Result<[FileItem], Error> in
                Result { try Self.listContents(of: url) }
            }
            let volume = Task.detached(priority: .utility) { VolumeUsage(of: url) }
            let result = await listing.value
            guard let self, !Task.isCancelled, url == self.currentURL else { return }
            self.volume = await volume.value
            self.isLoading = false
            switch result {
            case .success(let items):
                self.items = items
                // Only clear errors from listing; errors from actions (trash, drops…) stay visible.
                if self.listingFailed {
                    self.loadError = nil
                    self.listingFailed = false
                }
                if let pending = self.pendingSelection {
                    // Both sides standardized: listings can say /private/tmp where the request says /tmp.
                    self.selection = Set(items.filter { pending.contains($0.url.standardizedFileURL.path) }.map(\.url))
                    self.pendingSelection = nil
                } else if keepSelection {
                    self.selection = previousSelection.intersection(Set(self.listedItems.map(\.url)))
                }
                FolderSizeStore.shared.request(items.filter(\.isFolder).map(\.path))
                // Refresh expanded folders too; drop the ones that are gone.
                let present = Set(items.map(\.url))
                self.expanded = self.expanded.filter { folder in
                    present.contains(folder) || self.expanded.contains(folder.deletingLastPathComponent())
                }
                self.loadChildren(of: Array(self.expanded))
            case .failure(let error):
                self.items = []
                self.loadError = Self.describe(error, for: url)
                self.listingFailed = true
            }
            self.watcher.watch(url)
        }
    }

    func recalculateSizes() {
        FolderSizeStore.shared.request(items.filter(\.isFolder).map(\.path), force: true)
    }

    private static func describe(_ error: Error, for url: URL) -> String {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoPermissionError {
            return "TheExplorer doesn't have permission to read “\(url.lastPathComponent)”. Grant Full Disk Access in System Settings › Privacy & Security."
        }
        return nsError.localizedDescription
    }

    // MARK: - Actions

    /// Opens folders in place; everything else opens in its default app.
    func open(_ item: FileItem) {
        if item.isFolder {
            navigate(to: item.url)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    func open(urls: Set<URL>) {
        let targets = listedItems.filter { urls.contains($0.url) }
        if targets.count == 1, let only = targets.first {
            open(only)
        } else {
            targets.forEach { NSWorkspace.shared.open($0.url) }
        }
    }

    func openSelection() { open(urls: selection) }

    /// Toggles Quick Look for the selection. With one item selected, the arrow keys step through
    /// every file in the list (`rows`, in on-screen order), like Finder; with several, through those.
    func quickLook(_ urls: Set<URL>? = nil, in rows: [ListRow]? = nil) {
        if previewURL != nil {
            previewURL = nil
            return
        }
        let target = urls ?? activeSelection
        guard !target.isEmpty else { return }
        let rows = rows ?? (destination == .folder && !isSearching ? self.rows : [])
        let ordered = rows.map(\.id).filter(target.contains)
        let items = ordered.count == target.count ? ordered : target.sorted { $0.path < $1.path }
        guard let first = items.first else { return }
        if target.count == 1 {
            let files = rows.filter { !$0.item.isFolder || $0.id == first }.map(\.id)
            previewItems = files.contains(first) ? files : [first]
            previewMovesSelection = true
        } else {
            previewItems = items
            previewMovesSelection = false
        }
        previewURL = first
    }

    /// Quick Looks a file that isn't in the list, such as one unpacked from an archive.
    func preview(_ url: URL) {
        previewItems = [url]
        previewMovesSelection = false
        previewURL = url
    }

    /// The list's selection moved while Quick Look is open: show the new item, like Finder.
    func followSelectionInPreview() {
        let selected = activeSelection
        guard previewURL != nil, previewMovesSelection, selected.count == 1, let url = selected.first,
              url != previewURL, previewItems.contains(url) else { return }
        previewURL = url
    }

    /// The Quick Look panel moved to another item (or closed).
    func previewMoved(to url: URL?) {
        previewURL = url
        guard let url, previewMovesSelection else { return }
        if isSearching {
            search.selection = [url]
            return
        }
        switch destination {
        case .folder: selection = [url]
        case .recents: recents.selection = [url]
        case .newFiles: newFiles.selection = [url]
        case .storage: break
        }
    }

    func trash(_ urls: Set<URL>) {
        var failed: [String] = []
        for url in urls {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch {
                failed.append(url.lastPathComponent)
            }
        }
        if !failed.isEmpty {
            loadError = "Couldn't move to Trash: " + failed.joined(separator: ", ")
        }
        search.remove(urls)
        reload(keepSelection: true)
    }

    /// Suggests a name that doesn't clash with anything in the current folder.
    func suggestedName(for kind: NewItemKind) -> String {
        let (stem, ext) = kind == .folder ? ("untitled folder", "") : ("untitled", ".txt")
        var name = stem + ext
        var counter = 2
        while FileManager.default.fileExists(atPath: currentURL.appendingPathComponent(name).path) {
            name = "\(stem) \(counter)\(ext)"
            counter += 1
        }
        return name
    }

    func create(_ kind: NewItemKind, named raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/") else {
            loadError = "“\(raw)” isn't a valid name."
            return
        }
        let url = currentURL.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            loadError = "An item named “\(name)” already exists here."
            return
        }
        do {
            switch kind {
            case .folder:
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            case .file:
                try Data().write(to: url, options: .withoutOverwriting)
            }
            reload(selecting: [url])
        } catch {
            loadError = error.localizedDescription
        }
    }

    func rename(_ item: FileItem, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != item.name, !trimmed.contains("/") else { return }
        let destination = item.url.deletingLastPathComponent().appendingPathComponent(trimmed)
        do {
            try FileManager.default.moveItem(at: item.url, to: destination)
            reload(selecting: [destination])
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Shown in the status bar while a drop is being moved/copied.
    private(set) var transferStatus: String?

    /// Moves (or copies, across volumes or with ⌥) dropped items into `folder`.
    /// Returns false when nothing could be dropped there, so the drop is rejected.
    @discardableResult
    func receiveDrop(_ urls: [URL], into folder: URL) -> Bool {
        let folder = folder.standardizedFileURL
        let sources = FileTransfer.validSources(urls, into: folder)
        guard !sources.isEmpty else { return false }
        let optionHeld = NSEvent.modifierFlags.contains(.option)
        let copying = sources.contains { FileTransfer.mode(for: $0, into: folder, optionHeld: optionHeld) == .copy }
        let noun = sources.count == 1 ? "“\(sources[0].lastPathComponent)”" : "\(sources.count) items"
        transferStatus = "\(copying ? "Copying" : "Moving") \(noun) to “\(folder.lastPathComponent)”…"

        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                FileTransfer.perform(sources, into: folder, optionHeld: optionHeld)
            }.value
            transferStatus = nil
            if !outcome.failures.isEmpty {
                loadError = "Some items couldn't be \(copying ? "copied" : "moved"): " + outcome.failures.joined(separator: "; ")
            }
            // Sizes changed for the destination and (for moves) every source folder.
            let touched = Set([folder.path] + sources.map { $0.deletingLastPathComponent().path })
            touched.forEach(FolderSizeStore.shared.invalidate)
            FolderSizeStore.shared.request(Array(touched), force: true)
            if folder == currentURL {
                reload(selecting: outcome.placed)
            } else {
                reload(keepSelection: true)
            }
        }
        return true
    }

    var canCreateItems: Bool { destination == .folder && !isSearching }

    func dismissError() { loadError = nil }
}

// MARK: - Shared actions

enum FileActions {
    static func copyPaths(_ urls: some Sequence<URL>) {
        let paths = urls.map(\.path).sorted().joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths, forType: .string)
    }

    static func revealInFinder(_ urls: some Sequence<URL>) {
        NSWorkspace.shared.activateFileViewerSelecting(Array(urls))
    }

    /// Opens `folder` in the terminal chosen in Settings.
    @MainActor
    static func openInTerminal(_ folder: URL) {
        Prefs.shared.terminal.open(folder)
    }

    /// "Open in cmux", "Open in Terminal"… for menus.
    @MainActor
    static var openInTerminalTitle: String { "Open in \(Prefs.shared.terminal.name)" }
}
