import AppKit
import Observation
import SwiftUI

enum Destination: Hashable {
    case folder
    case recents
    case storage
}

enum NewItemKind {
    case folder
    case file

    var title: String { self == .folder ? "New Folder" : "New File" }
}

enum SortKey: String, CaseIterable {
    case name, kind, size, modified, created
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

/// A row in the folder table: the item plus its (possibly still-computing) size.
struct FileRow: Identifiable {
    let item: FileItem
    let folderSize: FolderSize?
    /// Size supplied by the caller (e.g. search results), overriding the computed one.
    var sizeOverride: Int64? = nil

    var id: URL { item.url }
    var name: String { item.name }
    var kind: String { item.kindDescription }
    var modified: Date { item.modified ?? .distantPast }
    var created: Date { item.created ?? .distantPast }
    var displaySize: Int64? { sizeOverride ?? (item.isFolder ? folderSize?.bytes : item.fileSize) }
    /// Unknown sizes sort below everything.
    var sortSize: Int64 { displaySize ?? -1 }
    var fileCount: Int { folderSize?.files ?? -1 }
}

/// Everything one window needs: where we are, history, what's selected, and how it's shown.
@MainActor
@Observable
final class BrowserModel: Identifiable {
    var destination: Destination = .folder
    private(set) var currentURL: URL
    private(set) var items: [FileItem] = []
    private(set) var isLoading = false
    private(set) var loadError: String?
    private(set) var backStack: [URL] = []
    private(set) var forwardStack: [URL] = []

    var selection: Set<URL> = []
    var sort: SortSpec = .byChanged
    var kindFilter: KindFilter = .all
    var previewURL: URL?

    var searchText = ""
    var searchScope: SearchScope = .folder

    var showHidden: Bool {
        didSet { UserDefaults.standard.set(showHidden, forKey: "showHidden") }
    }
    var foldersFirst: Bool {
        didSet { UserDefaults.standard.set(foldersFirst, forKey: "foldersFirst") }
    }

    var renaming: FileItem?
    /// Set to show the name prompt for a new folder or file in the current folder.
    var creating: NewItemKind?
    /// Set to put the cursor in the path/search bar.
    var omniboxRequest: OmniboxRequest?
    /// Bumped to move keyboard focus back to the file list.
    var listFocusRequest = 0

    let search = SearchModel()
    let recents = RecentsModel()
    @ObservationIgnored private var started = false
    @ObservationIgnored private var pendingSelection: Set<String>?
    @ObservationIgnored private var listingFailed = false
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private lazy var watcher = DirectoryWatcher { [weak self] in self?.reload(keepSelection: true) }

    init(url: URL? = nil) {
        let defaults = UserDefaults.standard
        showHidden = defaults.bool(forKey: "showHidden")
        foldersFirst = defaults.object(forKey: "foldersFirst") as? Bool ?? true
        let saved = defaults.string(forKey: "lastPath").map(URL.init(fileURLWithPath:))
        let start = url ?? saved ?? .home
        currentURL = FileManager.default.fileExists(atPath: start.path) ? start : .home
    }

    /// Loads the first listing. Kept out of init because SwiftUI may construct throwaway models.
    func start() {
        guard !started else { return }
        started = true
        reload()
    }

    // MARK: - Derived state

    var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    var rows: [FileRow] {
        let sizes = FolderSizeStore.shared
        var rows = items
            .filter { (showHidden || !$0.isHidden) && kindFilter.matches(isFolder: $0.isFolder) }
            .map { FileRow(item: $0, folderSize: $0.isFolder ? sizes.size(for: $0.path) : nil) }
        rows.sort(by: Self.comparator(for: sort))
        if foldersFirst {
            let folders = rows.filter(\.item.isFolder)
            let files = rows.filter { !$0.item.isFolder }
            rows = folders + files
        }
        return rows
    }

    static func comparator(for sort: SortSpec) -> (FileRow, FileRow) -> Bool {
        { lhs, rhs in
            let order: ComparisonResult
            switch sort.key {
            case .name: order = lhs.name.localizedStandardCompare(rhs.name)
            case .kind: order = TypeChip.style(for: lhs.item).label.compare(TypeChip.style(for: rhs.item).label)
            case .size: order = lhs.sortSize == rhs.sortSize ? .orderedSame : (lhs.sortSize < rhs.sortSize ? .orderedAscending : .orderedDescending)
            case .modified: order = lhs.modified.compare(rhs.modified)
            case .created: order = lhs.created.compare(rhs.created)
            }
            if order == .orderedSame { return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending }
            return sort.ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }

    var selectedItems: [FileItem] {
        items.filter { selection.contains($0.url) }
    }

    var title: String {
        switch destination {
        case .recents: "Recents"
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
        let url = url.standardizedFileURL
        searchText = ""
        destination = .folder
        if url != currentURL {
            if recordHistory {
                backStack.append(currentURL)
                forwardStack.removeAll()
            }
            currentURL = url
            items = []
            selection = []
            pendingSelection = nil
            UserDefaults.standard.set(url.path, forKey: "lastPath")
        }
        reload(selecting: select.map { [$0.standardizedFileURL] })
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
            let result = await Task.detached(priority: .userInitiated) { () -> Result<[FileItem], Error> in
                Result {
                    try FileManager.default
                        .contentsOfDirectory(at: url, includingPropertiesForKeys: FileItem.resourceKeys, options: [])
                        .map { child in
                            let values = (try? child.resourceValues(forKeys: Set(FileItem.resourceKeys))) ?? URLResourceValues()
                            return FileItem(url: child.standardizedFileURL, values: values)
                        }
                }
            }.value
            guard let self, !Task.isCancelled, url == self.currentURL else { return }
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
                    self.selection = Set(items.filter { pending.contains($0.path) }.map(\.url))
                    self.pendingSelection = nil
                } else if keepSelection {
                    self.selection = previousSelection.intersection(Set(items.map(\.url)))
                }
                FolderSizeStore.shared.request(items.filter(\.isFolder).map(\.path))
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
        let targets = items.filter { urls.contains($0.url) }
        if targets.count == 1, let only = targets.first {
            open(only)
        } else {
            targets.forEach { NSWorkspace.shared.open($0.url) }
        }
    }

    func openSelection() { open(urls: selection) }

    func quickLook(_ urls: Set<URL>? = nil) {
        if previewURL != nil {
            previewURL = nil
            return
        }
        let target = urls ?? activeSelection
        // Prefer on-screen order so the preview matches what you'd expect.
        previewURL = rows.first(where: { target.contains($0.id) })?.id ?? target.sorted { $0.path < $1.path }.first
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

    static func openInTerminal(_ folder: URL) {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([folder], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }
}
