import AppKit
import Observation
import SwiftUI

enum Destination: Hashable {
    case folder
    case recents
    case storage
}

enum SidebarItem: Hashable {
    case recents
    case storage
    case favorite(String)
    case location(URL)
}

/// A row in the folder table: the item plus its (possibly still-computing) size.
struct FileRow: Identifiable {
    let item: FileItem
    let folderSize: FolderSize?

    var id: URL { item.url }
    var name: String { item.name }
    var kind: String { item.kindDescription }
    var modified: Date { item.modified ?? .distantPast }
    var created: Date { item.created ?? .distantPast }
    var displaySize: Int64? { item.isFolder ? folderSize?.bytes : item.fileSize }
    /// Unknown sizes sort below everything.
    var sortSize: Int64 { displaySize ?? -1 }
    var fileCount: Int { folderSize?.files ?? -1 }
}

/// Everything one window needs: where we are, history, what's selected, and how it's shown.
@MainActor
@Observable
final class BrowserModel {
    var destination: Destination = .folder
    private(set) var currentURL: URL
    private(set) var items: [FileItem] = []
    private(set) var isLoading = false
    private(set) var loadError: String?
    private(set) var backStack: [URL] = []
    private(set) var forwardStack: [URL] = []

    var selection: Set<URL> = []
    var sortOrder: [KeyPathComparator<FileRow>] = [KeyPathComparator(\FileRow.name, comparator: .localizedStandard)]
    var kindFilter: KindFilter = .all
    var previewURL: URL?
    var showInspector = true
    var isEditingPath = false

    var searchText = ""
    var searchScope: SearchScope = .folder

    var showHidden: Bool {
        didSet { UserDefaults.standard.set(showHidden, forKey: "showHidden") }
    }
    var foldersFirst: Bool {
        didSet { UserDefaults.standard.set(foldersFirst, forKey: "foldersFirst") }
    }

    var renaming: FileItem?
    /// Bumped to ask the window to focus the search field.
    var searchFocusRequest = 0

    let search = SearchModel()
    let recents = RecentsModel()
    @ObservationIgnored private var started = false
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
        rows.sort(using: sortOrder)
        if foldersFirst {
            let folders = rows.filter(\.item.isFolder)
            let files = rows.filter { !$0.item.isFolder }
            rows = folders + files
        }
        return rows
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

    var sidebarSelection: SidebarItem? {
        get {
            switch destination {
            case .recents: return .recents
            case .storage: return .storage
            case .folder:
                if FavoritesStore.shared.contains(currentURL) { return .favorite(currentURL.path) }
                return .location(currentURL.standardizedFileURL)
            }
        }
        set {
            switch newValue {
            case .recents: show(.recents)
            case .storage: show(.storage)
            case .location(let url): navigate(to: url)
            case .favorite(let path): openFavorite(path)
            case nil: break
            }
        }
    }

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
                self.loadError = nil
                let present = Set(items.map(\.url))
                if let selecting {
                    self.selection = Set(selecting).intersection(present)
                } else if keepSelection {
                    self.selection = previousSelection.intersection(present)
                }
                FolderSizeStore.shared.request(items.filter(\.isFolder).map(\.path))
            case .failure(let error):
                self.items = []
                self.loadError = Self.describe(error, for: url)
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

    func createFolder() {
        var name = "untitled folder"
        var counter = 2
        while FileManager.default.fileExists(atPath: currentURL.appendingPathComponent(name).path) {
            name = "untitled folder \(counter)"
            counter += 1
        }
        let url = currentURL.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
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
