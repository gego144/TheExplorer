import SwiftUI

struct StorageView: View {
    @Bindable var model: BrowserModel
    @State private var tab: Tab = .breakdown

    private var storage: StorageModel { .shared }

    enum Tab: String, CaseIterable, Identifiable {
        case breakdown = "Breakdown"
        case largest = "Largest Files"
        var id: String { rawValue }
    }

    var body: some View {
        @Bindable var storage = storage

        VStack(spacing: 0) {
            PaneHeader {
                Picker("Scan", selection: $storage.target) {
                    Text(ScanTarget.home.label).tag(ScanTarget.home)
                    Text(ScanTarget.mac.label).tag(ScanTarget.mac)
                    if case .custom = storage.target {
                        Text(storage.target.label).tag(storage.target)
                    }
                    if model.currentURL != .home && !model.currentURL.isRoot {
                        Text("Current Folder (\(FileManager.default.displayName(atPath: model.currentURL.path)))")
                            .tag(ScanTarget.custom(model.currentURL))
                    }
                }
                .fixedSize()
                Button("Choose…", action: chooseFolder)
                if storage.isScanning {
                    Button("Stop", role: .cancel) { storage.cancel() }
                } else {
                    Button(storage.result == nil ? "Scan" : "Rescan") { storage.scan() }
                        .keyboardShortcut(.defaultAction)
                }
                Spacer()
                if storage.result != nil && !storage.isScanning {
                    Picker("View", selection: $tab) {
                        ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            .onChange(of: storage.target) { storage.refreshVolume() }

            if let volume = storage.volume {
                VolumeSummary(volume: volume, scanned: storage.result?.root)
            }

            if !storage.hasFullDiskAccess {
                FullDiskAccessBanner()
            }

            if let message = storage.errorMessage {
                ErrorBanner(message: message) { storage.errorMessage = nil }
            }

            if storage.isScanning {
                ScanProgressView(storage: storage)
            } else if let result = storage.result {
                switch tab {
                case .breakdown: BreakdownView(model: model, storage: storage, result: result)
                case .largest: LargestFilesView(model: model, files: result.largestFiles)
                }
            } else {
                ContentUnavailableView {
                    Label("See What's Using Space", systemImage: "chart.pie")
                } description: {
                    Text("Scan your home folder, your entire Mac, or any folder to get a breakdown of exactly where the space is going.")
                } actions: {
                    Button("Scan \(storage.target.label)") { storage.scan() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
            }
        }
        .confirmationDialog(
            "Move “\(storage.pendingTrash?.name ?? "")” to the Trash?",
            isPresented: Binding(get: { storage.pendingTrash != nil }, set: { if !$0 { storage.pendingTrash = nil } }),
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) { storage.confirmTrash() }
        } message: {
            if let node = storage.pendingTrash {
                Text("This frees about \(Format.bytes(node.size)) once the Trash is emptied.")
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = model.currentURL
        panel.prompt = "Scan"
        if panel.runModal() == .OK, let url = panel.url {
            storage.target = .custom(url.standardizedFileURL)
            storage.scan()
        }
    }
}

// MARK: - Volume summary

private struct VolumeSummary: View {
    let volume: VolumeUsage
    let scanned: SizeNode?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(volume.name).font(.headline)
                Text("\(Format.bytes(volume.used)) used of \(Format.bytes(volume.total))")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Format.bytes(volume.available)) available")
                    .fontWeight(.medium)
            }
            GeometryReader { proxy in
                let width = proxy.size.width
                let usedFraction = Double(volume.used) / Double(max(volume.total, 1))
                let scannedFraction = scanned.map { min(Double($0.size) / Double(max(volume.total, 1)), usedFraction) } ?? 0
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(.quaternary)
                    RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.45))
                        .frame(width: width * usedFraction)
                    RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.gradient)
                        .frame(width: width * scannedFraction)
                }
            }
            .frame(height: 10)
            if let scanned {
                HStack(spacing: 14) {
                    LegendDot(color: .accentColor, text: "\(scanned.name): \(Format.bytes(scanned.size))")
                    LegendDot(color: .secondary.opacity(0.45), text: "Everything else used: \(Format.bytes(max(0, volume.used - scanned.size)))")
                    LegendDot(color: .gray.opacity(0.25), text: "Free")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct LegendDot: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
        }
    }
}

private struct FullDiskAccessBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield").foregroundStyle(.orange)
            Text("Without Full Disk Access, protected folders (Mail, Messages, other apps' data) are skipped and sizes will be low.")
                .font(.callout)
            Spacer()
            Button("Grant Access…") { StorageModel.openFullDiskAccessSettings() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.orange.opacity(0.1))
    }
}

private struct ScanProgressView: View {
    let storage: StorageModel

    var body: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text("Scanning \(storage.target.label)…").font(.title3.weight(.medium))
            Text("\(storage.progressFiles.formatted()) files · \(Format.bytes(storage.progressBytes))")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(Format.path(storage.progressPath))
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 520)
            if let start = storage.scanStarted {
                Text(timerInterval: start...Date.distantFuture, countsDown: false)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Breakdown

private struct BreakdownView: View {
    let model: BrowserModel
    @Bindable var storage: StorageModel
    let result: ScanResult

    var body: some View {
        let focus = storage.focus ?? result.root
        let children = focus.children.filter { $0.size > 0 || $0.kind == .folder }

        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button {
                    storage.focusParent()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .disabled(focus.parent == nil)
                .help("Up one level (⌘↑)")

                ForEach(Array(storage.focusTrail.enumerated()), id: \.element.id) { index, node in
                    if index > 0 {
                        Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary)
                    }
                    Button(node.name) { storage.drill(into: node) }
                        .buttonStyle(.plain)
                        .fontWeight(node === focus ? .semibold : .regular)
                }
                Spacer()
                Text("\(Format.bytes(focus.size)) · \(focus.fileCount.formatted()) files")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if result.unreadableFolders > 0 {
                    Label("\(result.unreadableFolders.formatted()) unreadable", systemImage: "lock.fill")
                        .foregroundStyle(.orange)
                        .help("Some folders couldn't be read, so totals are a minimum. Grant Full Disk Access for complete results.")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 30)

            VSplitView {
                TreemapView(nodes: children, total: focus.size, selection: $storage.selection) { node in
                    storage.drill(into: node)
                }
                .frame(minHeight: 160, idealHeight: 280)
                .padding(8)

                List(selection: $storage.selection) {
                    ForEach(children) { node in
                        StorageRow(node: node, parentSize: focus.size)
                            .tag(node.id)
                    }
                }
                .listStyle(.inset)
                .alternatingRowBackgrounds()
                .frame(minHeight: 160)
                .contextMenu(forSelectionType: SizeNode.ID.self) { ids in
                    if let id = ids.first, let node = children.first(where: { $0.id == id }) {
                        StorageContextMenu(node: node, model: model, storage: storage)
                    }
                } primaryAction: { ids in
                    guard let id = ids.first, let node = children.first(where: { $0.id == id }) else { return }
                    if node.isFolder {
                        storage.drill(into: node)
                    } else if node.kind == .file {
                        NSWorkspace.shared.open(node.url)
                    }
                }
                .onKeyPress(.space) {
                    guard let id = storage.selection, let node = children.first(where: { $0.id == id }), node.kind != .otherFiles else { return .ignored }
                    model.quickLook([node.url])
                    return .handled
                }
            }
        }
    }
}

private struct StorageRow: View {
    let node: SizeNode
    let parentSize: Int64

    var body: some View {
        HStack(spacing: 10) {
            icon
                .frame(width: 20, height: 20)
            Text(node.name)
                .fontWeight(node.isFolder ? .medium : .regular)
                .foregroundStyle(node.kind == .otherFiles ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
            if !node.isReadable {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.orange)
                    .help("Couldn't read this folder")
            }
            if node.isFolder {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 12)
            if node.isFolder {
                Text("\(node.fileCount.formatted()) files")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            SizeBar(fraction: parentSize > 0 ? Double(node.size) / Double(parentSize) : 0,
                    tint: node.isFolder ? .accentColor : .gray)
                .frame(width: 120, height: 7)
            Text(Format.percent(node.size, of: parentSize))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 48, alignment: .trailing)
            Text(Format.bytes(node.size))
                .fontWeight(.medium)
                .monospacedDigit()
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var icon: some View {
        if node.kind == .otherFiles {
            Image(systemName: "doc.on.doc").foregroundStyle(.secondary)
        } else {
            Image(nsImage: Icons.icon(forPath: node.path)).resizable()
        }
    }
}

private struct StorageContextMenu: View {
    let node: SizeNode
    let model: BrowserModel
    let storage: StorageModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if node.kind != .otherFiles {
            if node.isFolder {
                Button("Break Down") { storage.drill(into: node) }
                Button("Open in Browser") { model.navigate(to: node.url) }
                Button("Open in New Tab") { Tabs.open(node.url, with: openWindow) }
            } else {
                Button("Open") { NSWorkspace.shared.open(node.url) }
                Button("Show in Enclosing Folder") { model.reveal(node.url) }
            }
            Button("Quick Look") { model.quickLook([node.url]) }
            Divider()
            Button("Add to Favorites") { FavoritesStore.shared.add(node.url) }
            Button("Copy Path") { FileActions.copyPaths([node.url]) }
            Button("Reveal in Finder") { FileActions.revealInFinder([node.url]) }
            Divider()
            Button("Move to Trash…", role: .destructive) { storage.pendingTrash = node }
        } else {
            Button("Show Folder in Browser") { model.navigate(to: node.url) }
        }
    }
}

// MARK: - Largest files

private struct LargestFilesView: View {
    let model: BrowserModel
    let files: [LargeFile]
    @State private var selection: Set<LargeFile.ID> = []

    var body: some View {
        let maxSize = files.first?.size ?? 0
        Table(files, selection: $selection) {
            TableColumn("Name") { file in
                HStack(spacing: 6) {
                    Image(nsImage: Icons.icon(forPath: file.path)).resizable().frame(width: 16, height: 16)
                    Text(file.name).lineLimit(1).truncationMode(.middle)
                }
            }
            .width(min: 180, ideal: 260)
            TableColumn("Location") { file in
                Text(Format.path((file.path as NSString).deletingLastPathComponent))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(file.path)
            }
            .width(min: 160, ideal: 360)
            TableColumn("Size") { file in
                SizeLabel(bytes: file.size, maxBytes: maxSize)
            }
            .width(min: 110, ideal: 140)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            FileContextMenu(urls: Set(ids.map { URL(fileURLWithPath: $0) }), model: model)
        } primaryAction: { ids in
            ids.forEach { NSWorkspace.shared.open(URL(fileURLWithPath: $0)) }
        }
        .onKeyPress(.space) {
            model.quickLook(Set(selection.map { URL(fileURLWithPath: $0) }))
            return .handled
        }
    }
}
