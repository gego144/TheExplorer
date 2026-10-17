import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

extension Notification.Name {
    /// Posted with a DriveLocation (a folder) after uploads, new folders, renames, moves or
    /// trashing changed what's in it.
    static let driveChanged = Notification.Name("TheExplorerDriveChanged")
}

/// One tab's view of Google Drive: an account's top level (My Drive, Shared with me, Starred,
/// Shared drives), a folder, or Drive's search across the account, listed a page at a time.
@MainActor
@Observable
final class DriveBrowser {
    private(set) var location: DriveLocation?
    private(set) var rows: [ListRow] = []
    private(set) var isLoading = false
    private(set) var error: String?
    /// More items than are loaded; scrolling to the end loads the next page.
    private(set) var hasMore = false
    /// Where the location is, from the account down: Google Drive / My Drive / Projects.
    /// What isn't known yet is asked of Drive, and the trail fills in.
    private(set) var trail: [DriveLocation] = []
    /// The search being shown, if any.
    private(set) var query = ""
    var selection: Set<URL> = []
    var sort = SortSpec(key: .name, ascending: true) { didSet { rebuild() } }

    @ObservationIgnored private var files: [DriveFile] = []
    @ObservationIgnored private var drives: [SharedDrive] = []
    @ObservationIgnored private var nextToken: String?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var trailTask: Task<Void, Never>?
    @ObservationIgnored private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: .driveChanged, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let changed = note.object as? DriveLocation, let location = self.location, !self.isSearching,
                      DriveStore.shared.isSameFolder(changed, location) else { return }
                self.reload(keepSelection: true)
            }
        }
    }

    var account: DriveAccount? { location.flatMap { DriveStore.shared.account($0.accountID) } }
    var client: DriveClient? { location.flatMap { DriveStore.shared.client(for: $0.accountID) } }
    var isSearching: Bool { !query.isEmpty }

    /// The folder Enclosing Folder goes to.
    var parent: DriveLocation? { trail.count > 1 ? trail[trail.count - 2] : nil }

    /// Whether new folders and uploads can go here: a real folder you can add to.
    var canAddItems: Bool {
        guard let location, !location.isVirtual, !isSearching else { return false }
        return DriveStore.shared.file(location)?.canAddChildren ?? true
    }

    /// Folder and file counts for the status bar.
    var counts: (folders: Int, files: Int) {
        let folders = rows.filter(\.item.isFolder).count
        return (folders, rows.count - folders)
    }

    func show(_ location: DriveLocation) {
        let location = Self.resolvingShortcut(location)
        guard location != self.location || error != nil || isSearching else { return }
        let otherAccount = location.accountID != self.location?.accountID
        self.location = location
        query = ""
        selection = []
        rows = []
        files = []
        drives = []
        updateTrail()
        reload()
        if otherAccount { DriveStore.shared.refreshUsage(location.accountID) }
    }

    /// A shortcut to a folder opens the folder it points to.
    static func resolvingShortcut(_ location: DriveLocation) -> DriveLocation {
        guard let file = DriveStore.shared.file(location), file.isShortcut, file.isFolder, let target = file.targetID else { return location }
        return DriveLocation(accountID: location.accountID, id: target, name: file.name)
    }

    /// Searches the whole account with Drive's search; empty goes back to the folder.
    func search(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard text != query else { return }
        query = text
        selection = []
        reload()
    }

    func reload(keepSelection: Bool = false) {
        guard let location, let client else {
            rows = []
            error = "This Google account was removed. Sign in again in Settings → Cloud."
            return
        }
        loadTask?.cancel()
        isLoading = true
        error = nil
        let previous = selection
        let query = query
        loadTask = Task {
            do {
                var drives: [SharedDrive] = []
                var page = DriveListing()
                if !query.isEmpty {
                    page = try await client.search(query)
                } else {
                    switch location.id {
                    case DriveLocation.homeID:
                        // Only to know whether to offer Shared drives.
                        drives = (try? await client.allDrives()) ?? []
                        DriveStore.shared.setSharedDrives(drives, for: location.accountID)
                    case DriveLocation.drivesID:
                        drives = try await client.allDrives()
                        DriveStore.shared.setSharedDrives(drives, for: location.accountID)
                    case DriveLocation.sharedID: page = try await client.sharedWithMe()
                    case DriveLocation.starredID: page = try await client.starred()
                    default: page = try await client.list(in: location.id)
                    }
                }
                guard !Task.isCancelled, location == self.location, query == self.query else { return }
                files = page.files
                self.drives = drives
                nextToken = page.nextToken
                remember(page.files, drives: drives)
                rebuild()
                selection = keepSelection ? previous.intersection(rows.map(\.id)) : []
            } catch is CancellationError {
                return
            } catch {
                guard location == self.location, query == self.query else { return }
                rows = []
                self.error = error.localizedDescription
            }
            isLoading = false
        }
    }

    /// Loads the next 1,000 items.
    func loadMore() {
        guard hasMore, !isLoading, let location, let client, let token = nextToken else { return }
        isLoading = true
        let query = query
        loadTask = Task {
            defer { isLoading = false }
            do {
                var page = DriveListing()
                if !query.isEmpty {
                    page = try await client.search(query, token: token)
                } else {
                    switch location.id {
                    case DriveLocation.drivesID:
                        let result = try await client.drives(token: token)
                        drives += result.drives
                        page.nextToken = result.nextToken
                        remember([], drives: result.drives)
                    case DriveLocation.sharedID: page = try await client.sharedWithMe(token: token)
                    case DriveLocation.starredID: page = try await client.starred(token: token)
                    default: page = try await client.list(in: location.id, token: token)
                    }
                }
                guard location == self.location, query == self.query else { return }
                files += page.files
                nextToken = page.nextToken
                remember(page.files, drives: [])
                rebuild()
            } catch {
                guard location == self.location else { return }
                self.error = error.localizedDescription
            }
        }
    }

    /// Notes where everything listed was found: search results aren't in this folder, so
    /// their folders are looked up when needed instead.
    private func remember(_ files: [DriveFile], drives: [SharedDrive]) {
        guard let location else { return }
        let store = DriveStore.shared
        store.remember(files, in: isSearching ? nil : location, accountID: location.accountID)
        for drive in drives {
            store.remember(parent: DriveLocation(accountID: location.accountID, id: DriveLocation.drivesID, name: "Shared drives"),
                           of: DriveLocation(accountID: location.accountID, id: drive.id, name: drive.name))
        }
    }

    private func rebuild() {
        guard let location else { return }
        let account = location.accountID
        if !isSearching && location.id == DriveLocation.homeID {
            var places = [(DriveLocation.myDriveID, "My Drive"), (DriveLocation.sharedID, "Shared with me"), (DriveLocation.starredID, "Starred")]
            if !drives.isEmpty { places.append((DriveLocation.drivesID, "Shared drives")) }
            rows = places.map { id, name in
                ListRow(item: FileItem(url: DriveLocation(accountID: account, id: id, name: name).url, name: name, isDirectory: true, contentType: .folder))
            }
            hasMore = false
            return
        }
        var rows: [ListRow] = []
        if !isSearching && location.id == DriveLocation.drivesID {
            for drive in drives {
                let item = FileItem(url: DriveLocation(accountID: account, id: drive.id, name: drive.name).url, name: drive.name,
                                    isDirectory: true, created: drive.created, modified: drive.created, contentType: .folder)
                rows.append(ListRow(item: item, date: drive.created))
            }
        }
        for file in files {
            let url = DriveLocation.url(accountID: account, id: file.id, name: file.name, isFolder: file.isFolder)
            let item = FileItem(url: url, name: file.name, isDirectory: file.isFolder, isSymlink: file.isShortcut,
                                isHidden: file.name.hasPrefix("."), fileSize: file.size, created: file.created,
                                modified: file.modified, contentType: file.uniformType)
            rows.append(ListRow(item: item, size: file.size, date: file.modified))
        }
        self.rows = RowSorter.sorted(rows, by: sort, foldersFirst: true)
        hasMore = nextToken != nil
    }

    private func updateTrail() {
        guard let location else {
            trail = []
            return
        }
        let store = DriveStore.shared
        var chain = [location]
        while let parent = store.knownParent(of: chain[0]), chain.count < 40 { chain.insert(parent, at: 0) }
        trail = chain
        trailTask?.cancel()
        guard chain[0].id != DriveLocation.homeID else { return }
        trailTask = Task {
            while chain[0].id != DriveLocation.homeID, chain.count < 40, let parent = await store.parent(of: chain[0]) {
                guard !Task.isCancelled, location == self.location else { return }
                chain.insert(parent, at: 0)
                trail = chain
            }
        }
    }

    // MARK: Actions

    func createFolder(named raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let location, canAddItems, !name.isEmpty, let client else { return }
        Task {
            do {
                let folder = try await client.createFolder(named: name, in: location.id)
                DriveStore.shared.remember([folder], in: location, accountID: location.accountID)
                NotificationCenter.default.post(name: .driveChanged, object: location)
                selection = [DriveLocation.url(accountID: location.accountID, id: folder.id, name: folder.name, isFolder: true)]
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func rename(_ url: URL, to raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let target = DriveLocation(url: url), let location, !name.isEmpty, name != target.name, let client else { return }
        Task {
            do {
                let renamed = try await client.rename(target.id, to: name)
                DriveStore.shared.remember([renamed], in: isSearching ? nil : location, accountID: location.accountID)
                reload(keepSelection: false)
                selection = [DriveLocation.url(accountID: location.accountID, id: renamed.id, name: renamed.name, isFolder: renamed.isFolder)]
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Moves items to Drive's trash (restorable from drive.google.com for 30 days).
    func trash(_ urls: Set<URL>) {
        guard let location, let client else { return }
        let targets = urls.compactMap(DriveLocation.init(url:)).filter { !$0.isVirtual }
        guard !targets.isEmpty else { return }
        Task {
            var failures: [String] = []
            for target in targets {
                do {
                    try await client.trash(target.id)
                } catch {
                    failures.append("\(target.name): \(error.localizedDescription)")
                }
            }
            if !failures.isEmpty { self.error = "Some items couldn't be moved to the trash: " + failures.joined(separator: "; ") }
            NotificationCenter.default.post(name: .driveChanged, object: location)
            if isSearching { reload() }
        }
    }

    /// Moves Drive items into a folder in the same account. Returns false when they can't go there.
    @discardableResult
    func move(_ urls: [URL], into folder: DriveLocation) -> Bool {
        let targets = urls.compactMap(DriveLocation.init(url:))
        guard !folder.isVirtual, !targets.isEmpty, targets.allSatisfy({ $0.accountID == folder.accountID && !$0.isVirtual && $0.id != folder.id }),
              let client = DriveStore.shared.client(for: folder.accountID) else { return false }
        Task {
            var failures: [String] = []
            var sources: [DriveLocation] = []
            for target in targets {
                do {
                    var parents = try await DriveStore.shared.details(target).parents
                    if parents.isEmpty { parents = try await client.file(target.id).parents }
                    let moved = try await client.move(target.id, from: parents, to: folder.id)
                    DriveStore.shared.remember([moved], in: folder, accountID: folder.accountID)
                    sources += parents.map { DriveLocation(accountID: folder.accountID, id: $0, name: "") }
                } catch {
                    failures.append("\(target.name): \(error.localizedDescription)")
                }
            }
            if !failures.isEmpty { self.error = "Some items couldn't be moved: " + failures.joined(separator: "; ") }
            for changed in [folder] + sources { NotificationCenter.default.post(name: .driveChanged, object: changed) }
        }
        return true
    }

    /// Copies Drive files into a folder in the same account ("Copy of …" when it's the same
    /// folder). Drive can't copy folders. Returns false when they can't go there.
    @discardableResult
    func copy(_ urls: [URL], into folder: DriveLocation) -> Bool {
        let targets = urls.compactMap(DriveLocation.init(url:))
        guard !folder.isVirtual, !targets.isEmpty, targets.allSatisfy({ $0.accountID == folder.accountID && !$0.isVirtual }),
              let client = DriveStore.shared.client(for: folder.accountID) else { return false }
        Task {
            var failures: [String] = []
            for target in targets {
                do {
                    let file = try await DriveStore.shared.details(target)
                    guard !file.isFolder else {
                        failures.append("“\(file.name)”: Drive can't copy folders")
                        continue
                    }
                    let sameFolder = file.parents.contains { DriveStore.shared.isSameFolder(DriveLocation(accountID: folder.accountID, id: $0, name: ""), folder) }
                    _ = try await client.copy(file.id, named: sameFolder ? "Copy of " + file.name : file.name, to: folder.id)
                } catch {
                    failures.append("“\(target.name)”: \(error.localizedDescription)")
                }
            }
            if !failures.isEmpty { self.error = "Some items couldn't be copied: " + failures.joined(separator: "; ") }
            NotificationCenter.default.post(name: .driveChanged, object: folder)
        }
        return true
    }

    /// Copies the item's Drive link, which opens it for anyone it's shared with.
    func copyLink(_ urls: [URL]) {
        guard let client else { return }
        Task {
            var links: [String] = []
            for url in urls {
                guard let target = DriveLocation(url: url) else { continue }
                if let link = DriveStore.shared.file(target)?.webLink {
                    links.append(link)
                } else if let link = try? await client.file(target.id).webLink {
                    links.append(link)
                }
            }
            guard !links.isEmpty else {
                error = "Drive didn't give a link for that."
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(links.joined(separator: "\n"), forType: .string)
        }
    }

    func openInBrowser(_ urls: [URL]) {
        for url in urls {
            guard let target = DriveLocation(url: url) else { continue }
            if let link = DriveStore.shared.file(target)?.webLink.flatMap(URL.init(string:)) {
                FileOpener.systemOpen(link)
            } else if target.id == DriveLocation.myDriveID || target.id == DriveLocation.homeID {
                FileOpener.systemOpen(URL(string: "https://drive.google.com/drive/my-drive")!)
            } else if !target.isVirtual {
                let kind = target.isFolder ? "drive/folders" : "file/d"
                FileOpener.systemOpen(URL(string: "https://drive.google.com/\(kind)/\(target.id)")!)
            }
        }
    }

    func dismissError() { error = nil }
}

// MARK: - Transfers

private struct DrivePlanItem {
    let file: DriveFile
    let destination: URL
    /// For Google Docs and the like: what they're saved as.
    let format: DriveExport?
}

extension Transfers {
    /// Uploads files and folders (with everything in them) into a Drive folder.
    func upload(_ urls: [URL], toDrive target: DriveLocation) {
        guard !target.isVirtual, let client = DriveStore.shared.client(for: target.accountID) else { return }
        let sources = urls.filter(\.isFileURL)
        guard !sources.isEmpty else { return }
        let id = start(.upload, title: "\(Self.noun(sources)) to “\(target.name)”")
        tasks[id] = Task {
            // Every file with its path inside the upload ("Photos/2026/a.jpg"), walked off the main thread.
            let files = await Task.detached { Self.expand(sources, under: "") }.value
            update(id) {
                $0.totalItems = files.count
                $0.totalBytes = files.reduce(0) { $0 + $1.size }
            }
            // Folders made so far, by their path inside the upload.
            var folders: [String: String] = [:]
            var finishedBytes: Int64 = 0
            do {
                for file in files {
                    try Task.checkCancellation()
                    let parts = file.key.split(separator: "/").map(String.init)
                    var parent = target.id
                    var path = ""
                    for folder in parts.dropLast() {
                        path += (path.isEmpty ? "" : "/") + folder
                        if let made = folders[path] {
                            parent = made
                        } else {
                            parent = try await client.createFolder(named: folder, in: parent).id
                            folders[path] = parent
                        }
                    }
                    update(id) { $0.current = file.url.lastPathComponent }
                    let base = finishedBytes
                    _ = try await client.upload(file: file.url, named: parts.last ?? file.url.lastPathComponent, into: parent) { sent in
                        Task { @MainActor in self.update(id) { $0.doneBytes = base + sent } }
                    }
                    finishedBytes += file.size
                    update(id) {
                        $0.doneItems += 1
                        $0.doneBytes = finishedBytes
                    }
                }
                finish(id, .done)
            } catch {
                finish(id, Self.state(for: error))
            }
            NotificationCenter.default.post(name: .driveChanged, object: target)
        }
    }

    /// Downloads Drive files and folders (keeping their structure) into a local folder. Google
    /// Docs, Sheets and Slides are saved as Office files, or as `format` when it applies.
    /// `completion` gets the top-level items that landed there; `failed` hears about errors.
    func download(drive urls: [URL], into folder: URL, as format: DriveExport? = nil,
                  completion: (([URL]) -> Void)? = nil, failed: ((Error) -> Void)? = nil) {
        let targets = urls.compactMap(DriveLocation.init(url:)).filter { !$0.isVirtual }
        guard let first = targets.first, let client = DriveStore.shared.client(for: first.accountID) else {
            failed?(CocoaError(.fileReadNoSuchFile))
            return
        }
        let id = start(.download, title: Self.downloadTitle(urls, into: folder), folder: folder)
        tasks[id] = Task {
            do {
                var plan: [DrivePlanItem] = []
                var placed: [URL] = []
                var skipped: [String] = []
                var taken = Set<String>()
                for target in targets {
                    let file = try await DriveStore.shared.details(target)
                    if file.isFolder {
                        let top = FileTransfer.uniqueDestination(for: Self.localName(file.name), in: folder, avoiding: taken)
                        taken.insert(top.path)
                        placed.append(top)
                        try FileManager.default.createDirectory(at: top, withIntermediateDirectories: true)
                        try await Self.plan(folder: file.contentID, into: top, client: client, plan: &plan, skipped: &skipped)
                    } else if let item = Self.planItem(file, in: folder, format: format, taken: &taken) {
                        placed.append(item.destination)
                        plan.append(item)
                    } else {
                        skipped.append(file.name)
                    }
                }
                // Exports only learn their size as they arrive, so the total grows with each one.
                let sizedTotal = plan.reduce(0) { $0 + ($1.format == nil ? $1.file.size ?? 0 : 0) }
                var exported: Int64 = 0
                update(id) {
                    $0.totalItems = plan.count
                    $0.totalBytes = sizedTotal
                }
                var finishedBytes: Int64 = 0
                for item in plan {
                    try Task.checkCancellation()
                    update(id) { $0.current = item.destination.lastPathComponent }
                    let base = finishedBytes
                    let known = item.format == nil ? item.file.size : nil
                    let exportedSoFar = exported
                    let progress: @Sendable (Int64, Int64) -> Void = { written, expected in
                        Task { @MainActor in
                            self.update(id) { transfer in
                                if known == nil, expected > 0 { transfer.totalBytes = max(transfer.totalBytes, sizedTotal + exportedSoFar + expected) }
                                transfer.doneBytes = base + written
                            }
                        }
                    }
                    if let format = item.format {
                        try await client.export(item.file.contentID, as: format, to: item.destination, progress: progress)
                    } else {
                        try await client.download(item.file.contentID, to: item.destination, progress: progress)
                    }
                    let size = (try? item.destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                    if known == nil { exported += size }
                    finishedBytes = base + (known ?? size)
                    let total = sizedTotal + exported
                    update(id) {
                        $0.doneItems += 1
                        $0.doneBytes = finishedBytes
                        if known == nil { $0.totalBytes = total }
                    }
                }
                update(id) { $0.placed = placed }
                if skipped.isEmpty {
                    finish(id, .done)
                } else {
                    let names = skipped.prefix(3).map { "“\($0)”" }.joined(separator: ", ") + (skipped.count > 3 ? " and \(skipped.count - 3) more" : "")
                    finish(id, .failed("Downloaded everything except \(names): Google Forms, Sites and the like only open in the browser."))
                }
                completion?(placed)
            } catch {
                finish(id, Self.state(for: error))
                failed?(error)
            }
        }
    }

    /// Downloads a Drive file to a cache folder (once per version) and hands back the local
    /// copy, for opening and Quick Look. Google Docs come as PDFs, which preview everywhere.
    func fetchForViewing(drive url: URL, then use: @escaping (URL) -> Void) {
        guard let target = DriveLocation(url: url), !target.isFolder, DriveStore.shared.client(for: target.accountID) != nil else { return }
        Task {
            guard let file = try? await DriveStore.shared.details(target) else { return }
            let formats = DriveExport.formats(for: file.contentType)
            let format = file.isGoogleDoc ? (formats.contains(.pdf) ? .pdf : formats.first) : nil
            if file.isGoogleDoc && format == nil {
                DriveBrowser.openLink(file)
                return
            }
            let version = file.modified.map { String(Int($0.timeIntervalSince1970)) } ?? "0"
            let cache = FileManager.default.temporaryDirectory
                .appendingPathComponent("TheExplorer Drive", isDirectory: true)
                .appendingPathComponent(file.contentID + "-" + version, isDirectory: true)
            let local = cache.appendingPathComponent(format?.fileName(for: Self.localName(file.name)) ?? Self.localName(file.name))
            if FileManager.default.fileExists(atPath: local.path) {
                use(local)
                return
            }
            try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            download(drive: [url], into: cache, as: format) { placed in
                if let file = placed.first { use(file) }
            }
        }
    }

    /// Plans a folder's whole tree, making its local folders as it goes.
    private static func plan(folder id: String, into local: URL, client: DriveClient,
                             plan: inout [DrivePlanItem], skipped: inout [String]) async throws {
        var taken = Set<String>()
        for child in try await client.listAll(in: id) {
            try Task.checkCancellation()
            if child.isFolder {
                // Shortcuts to folders could lead in circles, so only real folders are followed.
                guard !child.isShortcut else { continue }
                let sub = FileTransfer.uniqueDestination(for: localName(child.name), in: local, avoiding: taken)
                taken.insert(sub.path)
                try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
                try await self.plan(folder: child.contentID, into: sub, client: client, plan: &plan, skipped: &skipped)
            } else if let item = planItem(child, in: local, format: nil, taken: &taken) {
                plan.append(item)
            } else {
                skipped.append(child.name)
            }
        }
    }

    private static func planItem(_ file: DriveFile, in folder: URL, format: DriveExport?, taken: inout Set<String>) -> DrivePlanItem? {
        var export: DriveExport?
        if file.isGoogleDoc {
            let formats = DriveExport.formats(for: file.contentType)
            guard let chosen = format.flatMap({ formats.contains($0) ? $0 : nil }) ?? formats.first else { return nil }
            export = chosen
        }
        let name = export?.fileName(for: localName(file.name)) ?? localName(file.name)
        let destination = FileTransfer.uniqueDestination(for: name, in: folder, avoiding: taken)
        taken.insert(destination.path)
        return DrivePlanItem(file: file, destination: destination, format: export)
    }

    /// A Drive name as a file name: slashes become colons, which Finder shows as slashes.
    nonisolated static func localName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: ":").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "Untitled" : cleaned
    }
}

extension DriveBrowser {
    /// Opens a Google Doc (or anything else) in the browser.
    static func openLink(_ file: DriveFile) {
        if let link = file.webLink.flatMap(URL.init(string:)) { FileOpener.systemOpen(link) }
    }
}
