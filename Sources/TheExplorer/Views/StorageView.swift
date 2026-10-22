import SwiftUI

struct StorageView: View {
    @Bindable var model: BrowserModel
    @State private var tab: Tab = .breakdown

    private var storage: StorageModel { .shared }

    enum Tab: Hashable {
        case breakdown
        case largest
    }

    var body: some View {
        @Bindable var storage = storage

        VStack(spacing: 0) {
            PaneHeader {
                ChromeMenu {
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
                    .pickerStyle(.inline)
                    Divider()
                    Button("Choose Folder…", action: chooseFolder)
                } label: {
                    Text(storage.target.label)
                }
                if storage.isScanning {
                    Button("Stop") { storage.cancel() }
                        .buttonStyle(SubtleButtonStyle())
                } else {
                    Button(storage.result == nil ? "Scan" : "Rescan") { storage.scan() }
                        .buttonStyle(AccentButtonStyle())
                        .keyboardShortcut(.defaultAction)
                }
                Spacer()
                if storage.result != nil && !storage.isScanning {
                    Segmented(selection: $tab, options: [(.breakdown, "Breakdown"), (.largest, "Largest Files")])
                        .fixedSize()
                }
            }
            .onChange(of: storage.target) { storage.refreshVolume() }

            if let volume = storage.volume {
                VolumeSummary(volume: volume, scanned: storage.result?.root)
            }
            if !storage.hasFullDiskAccess {
                Banner(symbol: "lock.shield", tint: Theme.warning,
                       text: "Without Full Disk Access, protected folders (Mail, Messages, other apps' data) are skipped and sizes come out low.",
                       actionTitle: "Grant Access…", action: { StorageModel.openFullDiskAccessSettings() })
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
                VStack(spacing: 12) {
                    Image(systemName: "chart.pie.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(Theme.accent)
                    Text("See what's using space")
                        .font(.system(size: 17, weight: .semibold))
                    Text("Scan your home folder, the whole Mac, or any folder for a breakdown of where the space goes.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                    Button("Scan \(storage.target.label)") { storage.scan() }
                        .buttonStyle(AccentButtonStyle(large: true))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(volume.name).font(.system(size: 13, weight: .semibold))
                Text("\(Format.bytes(volume.used)) used of \(Format.bytes(volume.total))")
                    .font(Theme.mono)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text("\(Format.bytes(volume.available)) free")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.accent)
            }
            GeometryReader { proxy in
                let width = proxy.size.width
                let usedFraction = Double(volume.used) / Double(max(volume.total, 1))
                let scannedFraction = scanned.map { min(Double($0.size) / Double(max(volume.total, 1)), usedFraction) } ?? 0
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.border)
                    Capsule().fill(Theme.textTertiary.opacity(0.7)).frame(width: width * usedFraction)
                    Capsule().fill(Theme.accent).frame(width: width * scannedFraction)
                }
            }
            .frame(height: 8)
            if let scanned {
                HStack(spacing: 14) {
                    LegendDot(color: Theme.accent, text: "\(scanned.name) \(Format.bytes(scanned.size))")
                    LegendDot(color: Theme.textTertiary.opacity(0.7), text: "everything else \(Format.bytes(max(0, volume.used - scanned.size)))")
                    LegendDot(color: Theme.border, text: "free")
                }
                .font(Theme.monoSmall)
                .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}

private struct LegendDot: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 7, height: 7)
            Text(text)
        }
    }
}

private struct ScanProgressView: View {
    let storage: StorageModel

    var body: some View {
        if storage.progressFolders.isEmpty {
            VStack(spacing: 12) {
                ProgressView().controlSize(.regular).tint(Theme.accent)
                Text("Scanning \(storage.target.label)…").font(.system(size: 15, weight: .semibold))
                counts
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // The folders fill in as they're counted, so the big ones show up long before the end.
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small).tint(Theme.accent)
                    Text("Scanning \(storage.target.label)…").font(.system(size: 12.5, weight: .semibold))
                    Text("\(storage.progressFiles.formatted()) files · \(Format.bytes(storage.progressBytes))")
                        .font(Theme.mono)
                        .foregroundStyle(Theme.accent)
                    Text(Format.path(storage.progressPath))
                        .font(Theme.monoSmall)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    elapsed
                }
                .padding(.horizontal, 12)
                .frame(height: 38)
                ScrollView {
                    let largest = max(1, storage.progressFolders.first?.bytes ?? 1)
                    LazyVStack(spacing: 1) {
                        ForEach(storage.progressFolders) { folder in
                            HStack(spacing: 10) {
                                Text(folder.name)
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 12)
                                HeatBar(fraction: Double(folder.bytes) / Double(largest), height: 4, width: 130)
                                Text(Format.bytes(folder.bytes))
                                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                                    .frame(width: 78, alignment: .trailing)
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 30)
                        }
                    }
                    .padding(8)
                }
                .scrollContentBackground(.hidden)
            }
        }
    }

    @ViewBuilder private var counts: some View {
        Text("\(storage.progressFiles.formatted()) files · \(Format.bytes(storage.progressBytes))")
            .font(Theme.mono)
            .foregroundStyle(Theme.accent)
        Text(Format.path(storage.progressPath))
            .font(Theme.monoSmall)
            .foregroundStyle(Theme.textTertiary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: 520)
        elapsed
    }

    @ViewBuilder private var elapsed: some View {
        if let start = storage.scanStarted {
            Text(timerInterval: start...Date.distantFuture, countsDown: false)
                .font(Theme.monoSmall)
                .foregroundStyle(Theme.textTertiary)
        }
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
            HStack(spacing: 6) {
                IconButton(systemImage: "chevron.left", help: "Up one level (⌘↑)") { storage.focusParent() }
                    .disabled(focus.parent == nil)
                ForEach(Array(storage.focusTrail.enumerated()), id: \.element.id) { index, node in
                    if index > 0 { Text("/").font(.system(size: 11)).foregroundStyle(Theme.textTertiary.opacity(0.7)) }
                    Button { storage.drill(into: node) } label: {
                        Text(node.name)
                    }
                    .buttonStyle(CrumbStyle(isCurrent: node === focus))
                }
                Spacer()
                Text("\(Format.bytes(focus.size)) · \(focus.fileCount.formatted()) files")
                    .font(Theme.mono)
                    .foregroundStyle(Theme.textSecondary)
                if result.unreadableFolders > 0 {
                    Label("\(result.unreadableFolders.formatted()) unreadable", systemImage: "lock.fill")
                        .font(Theme.mono)
                        .foregroundStyle(Theme.warning)
                        .help("Some folders couldn't be read, so totals are a minimum. Grant Full Disk Access for complete results.")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 38)

            VSplitView {
                TreemapView(nodes: children, total: focus.size, selection: $storage.selection) { node in
                    storage.drill(into: node)
                }
                .frame(minHeight: 160, idealHeight: 280)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)

                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(children) { node in
                            StorageRow(node: node, parentSize: focus.size, isSelected: storage.selection == node.id)
                                .onTapGesture { storage.selection = node.id }
                                .simultaneousGesture(TapGesture(count: 2).onEnded {
                                    if node.isFolder { storage.drill(into: node) }
                                    else if node.kind == .file { FileOpener.open([node.url]) }
                                })
                                .contextMenu { StorageContextMenu(node: node, model: model, storage: storage) }
                        }
                    }
                    .padding(8)
                }
                .scrollContentBackground(.hidden)
                .frame(minHeight: 160)
            }
        }
    }
}

private struct StorageRow: View {
    let node: SizeNode
    let parentSize: Int64
    let isSelected: Bool
    @State private var hovering = HoverPreview.on

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .heavy))
                .foregroundStyle(Theme.accent)
                .frame(width: 10)
                .opacity(node.isFolder ? 1 : 0)
            Text(node.name)
                .font(.system(size: 12.5, weight: node.isFolder ? .semibold : .regular))
                .foregroundStyle(node.kind == .otherFiles ? Theme.textSecondary : Theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
            if !node.isReadable {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.warning)
                    .help("Couldn't read this folder")
            }
            Spacer(minLength: 12)
            if node.isFolder {
                Text("\(node.fileCount.formatted()) files")
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.textTertiary)
            }
            HeatBar(fraction: parentSize > 0 ? Double(node.size) / Double(parentSize) : 0, height: 4)
                .frame(width: 130)
            Text(Format.percent(node.size, of: parentSize))
                .font(Theme.mono)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 46, alignment: .trailing)
            Text(Format.bytes(node.size))
                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                .frame(width: 78, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(isSelected ? Theme.accentSoft : (hovering ? Theme.hoverFill : .clear), in: .rect(cornerRadius: Theme.controlRadius))
        .hoverTracking { hovering = $0 }
        .clickable()
        .animation(Theme.hoverAnimation, value: hovering)
    }
}

private struct StorageContextMenu: View {
    let node: SizeNode
    let model: BrowserModel
    let storage: StorageModel
    @Environment(\.openTab) private var openTab

    var body: some View {
        if node.kind != .otherFiles {
            if node.isFolder {
                Button("Break Down") { storage.drill(into: node) }
                Button("Open in Browser") { model.navigate(to: node.url) }
                Button("Open in New Tab") { openTab(node.url) }
            } else {
                Button("Open") { FileOpener.open([node.url]) }
                OpenWithMenu(urls: [node.url])
                Button("Show in Enclosing Folder") { model.reveal(node.url) }
            }
            Button("Quick Look") { model.quickLook([node.url]) }
            Divider()
            Button("Pin to Sidebar") { FavoritesStore.shared.add(node.url) }
            Button("Copy Path") { FileActions.copyPaths([node.url]) }
            Button(FileActions.revealTitle) { FileActions.revealInFinder([node.url]) }
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
    @State private var selection: Set<URL> = []
    /// Built off the main thread once per scan (each file is read from disk).
    @State private var rows: [ListRow] = []
    @Environment(\.openTab) private var openTab

    var body: some View {
        FileListView(
            rows: rows,
            selection: $selection,
            showLocation: true,
            empty: EmptyState(symbol: "doc", title: "No files found"),
            onOpen: { urls, _ in FileOpener.open(Array(urls)) },
            onQuickLook: { model.quickLook($0, in: $1) },
            rowMenu: { FileContextMenu(urls: $0, model: model) },
            backgroundMenu: { EmptyView() }
        )
        .task(id: files.map(\.path)) {
            let files = files
            rows = await Task.detached(priority: .userInitiated) {
                files.compactMap { file -> ListRow? in
                    guard let item = FileItem(url: file.url) else { return nil }
                    return ListRow(item: item, size: file.size, date: item.modified, location: (file.path as NSString).deletingLastPathComponent)
                }
            }.value
        }
    }
}
