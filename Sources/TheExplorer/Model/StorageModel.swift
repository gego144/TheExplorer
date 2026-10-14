import AppKit
import Observation

struct VolumeUsage {
    let name: String
    let total: Int64
    let available: Int64
    var used: Int64 { max(0, total - available) }
}

enum ScanTarget: Hashable {
    case home
    case mac
    case custom(URL)

    var url: URL {
        switch self {
        case .home: .home
        case .mac: URL(fileURLWithPath: "/")
        case .custom(let url): url
        }
    }

    var label: String {
        switch self {
        case .home: "Home Folder"
        case .mac: "Entire Mac"
        case .custom(let url): FileManager.default.displayName(atPath: url.path)
        }
    }
}

/// Disk usage scanning, shared across windows so a finished scan isn't lost.
@MainActor
@Observable
final class StorageModel {
    static let shared = StorageModel()

    var target: ScanTarget = .home
    private(set) var result: ScanResult?
    private(set) var isScanning = false
    private(set) var progressFiles = 0
    private(set) var progressBytes: Int64 = 0
    private(set) var progressPath = ""
    private(set) var scanStarted: Date?
    private(set) var volume: VolumeUsage?
    private(set) var hasFullDiskAccess = StorageModel.checkFullDiskAccess()

    /// The folder currently drilled into.
    var focus: SizeNode?
    var selection: SizeNode.ID?
    /// Awaiting confirmation before moving to the Trash.
    var pendingTrash: SizeNode?

    @ObservationIgnored private var scanTask: Task<Void, Never>?

    init() {
        refreshVolume()
        // Re-check after you come back from System Settings, so the banner reflects a new grant.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let shared = StorageModel.shared
                shared.hasFullDiskAccess = StorageModel.checkFullDiskAccess()
            }
        }
    }

    /// Breadcrumb from the scan root down to the focused folder.
    var focusTrail: [SizeNode] {
        var trail: [SizeNode] = []
        var node = focus
        while let current = node {
            trail.insert(current, at: 0)
            node = current.parent
        }
        return trail
    }

    func scan() {
        cancel()
        let root = target.url
        let progress = ScanProgress()
        isScanning = true
        scanStarted = Date()
        progressFiles = 0
        progressBytes = 0
        progressPath = root.path
        hasFullDiskAccess = Self.checkFullDiskAccess()
        refreshVolume()

        scanTask = Task { [weak self] in
            let poller = Task { [weak self] in
                while !Task.isCancelled {
                    let snapshot = progress.snapshot
                    self?.progressFiles = snapshot.files
                    self?.progressBytes = snapshot.bytes
                    self?.progressPath = snapshot.path
                    try? await Task.sleep(for: .milliseconds(150))
                }
            }
            defer { poller.cancel() }
            let outcome = await Task.detached(priority: .userInitiated) {
                try? await DiskScanner.scan(root: root, progress: progress)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.isScanning = false
            if let outcome {
                self.result = outcome
                self.focus = outcome.root
                self.selection = nil
                FolderSizeStore.shared.absorb(outcome.root)
            }
        }
    }

    func cancel() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
    }

    func drill(into node: SizeNode) {
        guard node.isFolder else { return }
        focus = node
        selection = nil
    }

    func focusParent() {
        guard let parent = focus?.parent else { return }
        let previous = focus
        focus = parent
        selection = previous?.id
    }

    func refreshVolume() {
        let url = target.url
        guard let values = try? url.resourceValues(forKeys: [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]),
              let total = values.volumeTotalCapacity else {
            volume = nil
            return
        }
        let available = values.volumeAvailableCapacityForImportantUsage ?? Int64(values.volumeAvailableCapacity ?? 0)
        volume = VolumeUsage(name: values.volumeName ?? "Disk", total: Int64(total), available: available)
    }

    /// Without Full Disk Access, protected folders (Mail, Messages, Safari, other apps' data) are skipped.
    static func checkFullDiskAccess() -> Bool {
        let probe = URL.home.appendingPathComponent("Library/Application Support/com.apple.TCC")
        return (try? FileManager.default.contentsOfDirectory(atPath: probe.path)) != nil
    }

    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    var errorMessage: String?

    func confirmTrash() {
        guard let node = pendingTrash else { return }
        pendingTrash = nil
        do {
            try FileManager.default.trashItem(at: node.url, resultingItemURL: nil)
            didTrash(node)
        } catch {
            errorMessage = "Couldn't move “\(node.name)” to the Trash: \(error.localizedDescription)"
        }
    }

    /// Removes a node from the tree after it's been trashed, so totals stay honest without a rescan.
    private func didTrash(_ node: SizeNode) {
        node.detachFromParent()
        if selection == node.id { selection = nil }
        let removed = node.path
        result = result.map {
            ScanResult(root: $0.root,
                       largestFiles: $0.largestFiles.filter { $0.path != removed && !$0.path.hasPrefix(removed + "/") },
                       unreadableFolders: $0.unreadableFolders,
                       duration: $0.duration)
        }
        // SizeNode isn't observable; reassigning focus redraws views reading the mutated tree.
        let current = focus
        focus = current
        if let root = result?.root { FolderSizeStore.shared.absorb(root) }
        refreshVolume()
    }
}
