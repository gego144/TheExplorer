import SwiftUI

struct SidebarView: View {
    let model: BrowserModel
    @State private var volumes: [URL] = SidebarView.mountedVolumes()
    @State private var pinTargeted = false
    @Environment(\.openTab) private var openTab

    private var favorites: FavoritesStore { .shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                caption("Pinned")
                    .background(pinTargeted ? Theme.accentSoft : .clear, in: .rect(cornerRadius: 5))
                    .dropDestination(for: URL.self) { urls, _ in
                        urls.forEach { favorites.add($0) }
                        return !urls.isEmpty
                    } isTargeted: { pinTargeted = $0 }
                    .help("Drop here to pin")
                if favorites.favorites.isEmpty {
                    Text("Drop folders on “Pinned”, or press ⌘D")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }
                ForEach(Array(favorites.favorites.enumerated()), id: \.element.id) { index, favorite in
                    PinnedRow(favorite: favorite, index: index, model: model, openTab: openTab)
                }

                caption("Views")
                SidebarRow(title: "Recents", systemImage: "clock", isSelected: isShowing(.recents)) { model.show(.recents) }
                SidebarRow(title: "New", systemImage: "sparkles", isSelected: isShowing(.newFiles)) { model.show(.newFiles) }
                SidebarRow(title: "Storage", systemImage: "chart.pie", isSelected: isShowing(.storage)) { model.show(.storage) }

                CloudSection(model: model)

                caption("Places")
                ForEach(Self.places, id: \.url) { place in
                    SidebarRow(title: place.title, systemImage: place.symbol, isSelected: isShowing(place.url), dropURL: place.url, model: model) {
                        model.navigate(to: place.url)
                    }
                    .contextMenu { locationMenu(place.url) }
                }

                caption("Drives")
                ForEach(volumes, id: \.self) { url in
                    SidebarRow(title: FileManager.default.displayName(atPath: url.path),
                               systemImage: url.isRoot ? "internaldrive" : "externaldrive",
                               isSelected: isShowing(url), dropURL: url, model: model,
                               trailing: url.isRoot ? nil : AnyView(EjectButton(url: url))) {
                        model.navigate(to: url)
                    }
                    .contextMenu { locationMenu(url) }
                }
            }
            .padding(8)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            volumes = Self.mountedVolumes()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            volumes = Self.mountedVolumes()
        }
    }

    private func caption(_ title: String) -> some View {
        SectionCaption(title: title)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.top, 12)
            .padding(.bottom, 4)
    }

    private func isShowing(_ destination: Destination) -> Bool {
        !model.isSearching && model.destination == destination
    }

    private func isShowing(_ url: URL) -> Bool {
        !model.isSearching && model.destination == .folder && model.currentURL == url.standardizedFileURL
    }

    @ViewBuilder
    private func locationMenu(_ url: URL) -> some View {
        Button("Open in New Tab") { openTab(url) }
        Button(FileActions.openInTerminalTitle) { FileActions.openInTerminal(url) }
        Button("Copy Path") { FileActions.copyPaths([url]) }
        Button(FileActions.revealTitle) { FileActions.revealInFinder([url]) }
        Button("Pin") { favorites.add(url) }
    }

    struct Place {
        let title: String
        let symbol: String
        let url: URL
    }

    static let places: [Place] = {
        let fm = FileManager.default
        var places = [Place(title: FileManager.default.displayName(atPath: URL.home.path), symbol: "house", url: .home)]
        let standard: [(FileManager.SearchPathDirectory, String)] = [
            (.desktopDirectory, "menubar.dock.rectangle"), (.documentDirectory, "doc"), (.downloadsDirectory, "arrow.down.circle"),
        ]
        for (directory, symbol) in standard {
            if let url = fm.urls(for: directory, in: .userDomainMask).first {
                places.append(Place(title: fm.displayName(atPath: url.path), symbol: symbol, url: url))
            }
        }
        places.append(Place(title: "Applications", symbol: "square.grid.2x2", url: URL(fileURLWithPath: "/Applications")))
        let iCloud = URL.home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        if fm.fileExists(atPath: iCloud.path) {
            places.append(Place(title: "iCloud Drive", symbol: "icloud", url: iCloud))
        }
        return places.map { Place(title: $0.title, symbol: $0.symbol, url: $0.url.standardizedFileURL) }
    }()

    static func mountedVolumes() -> [URL] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeNameKey], options: [.skipHiddenVolumes]) ?? []
        #if DEBUG
        if DemoMode.isOn { return urls.filter { $0.path == "/" } }
        #endif
        return urls.map(\.standardizedFileURL)
    }
}

/// A sidebar line. Folder rows accept drops (items move inside).
private struct SidebarRow: View {
    let title: String
    var systemImage: String?
    var dotColor: Color?
    let isSelected: Bool
    var dimmed = false
    var dropURL: URL?
    var model: BrowserModel?
    var trailing: AnyView?
    let action: () -> Void
    @State private var hovering = HoverPreview.on
    @State private var targeted = false

    init(title: String, systemImage: String? = nil, dotColor: Color? = nil, isSelected: Bool, dimmed: Bool = false,
         dropURL: URL? = nil, model: BrowserModel? = nil, trailing: AnyView? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.dotColor = dotColor
        self.isSelected = isSelected
        self.dimmed = dimmed
        self.dropURL = dropURL
        self.model = model
        self.trailing = trailing
        self.action = action
    }

    var body: some View {
        HStack(spacing: 8) {
            if let dotColor {
                RoundedRectangle(cornerRadius: 2).fill(dotColor).frame(width: 7, height: 7)
                    .frame(width: 14)
            } else if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isSelected || hovering ? Theme.text : Theme.textTertiary)
                    .frame(width: 14)
            }
            Text(title)
                .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected || (hovering && !dimmed) ? Theme.text : (dimmed ? Theme.textTertiary : Theme.textSecondary))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, 8)
        .frame(height: Theme.controlHeight)
        .background(background, in: .rect(cornerRadius: Theme.controlRadius))
        .overlay {
            if targeted { RoundedRectangle(cornerRadius: Theme.controlRadius).strokeBorder(Theme.accent, lineWidth: 1.2) }
        }
        .hoverTracking { hovering = $0 }
        .clickable()
        .animation(Theme.hoverAnimation, value: hovering)
        .onTapGesture(perform: action)
        .modifier(SidebarDrop(url: dropURL, model: model, targeted: $targeted))
    }

    private var background: Color {
        if isSelected { return hovering ? Theme.raisedHover : Theme.raised }
        return hovering ? Theme.hoverFill : .clear
    }
}

private struct SidebarDrop: ViewModifier {
    let url: URL?
    let model: BrowserModel?
    @Binding var targeted: Bool

    func body(content: Content) -> some View {
        if let url, let model {
            content.dropDestination(for: URL.self) { urls, _ in
                model.receiveDrop(urls, into: url)
            } isTargeted: { targeted = $0 }
        } else {
            content
        }
    }
}

private struct PinnedRow: View {
    let favorite: Favorite
    let index: Int
    let model: BrowserModel
    let openTab: (URL) -> Void

    private var favorites: FavoritesStore { .shared }

    var body: some View {
        let exists = favorite.exists
        let isCurrent = !model.isSearching && model.destination == .folder && model.currentURL.path == favorite.path
        SidebarRow(title: favorite.name, dotColor: Theme.paletteColor(for: favorite.path), isSelected: isCurrent,
                   dimmed: !exists, dropURL: favorite.isDirectory && exists ? favorite.url : nil, model: model) {
            model.openFavorite(favorite.path)
        }
        .draggable(favorite.url)
        .help(exists ? Format.path(favorite.path) : "Missing: \(Format.path(favorite.path))")
        .contextMenu {
            if favorite.isDirectory {
                Button("Open in New Tab") { openTab(favorite.url) }
                Button(FileActions.openInTerminalTitle) { FileActions.openInTerminal(favorite.url) }
            } else {
                Button("Open") { FileOpener.open([favorite.url]) }
                OpenWithMenu(urls: [favorite.url])
            }
            Button("Show in Enclosing Folder") { model.reveal(favorite.url) }
            Button("Copy Path") { FileActions.copyPaths([favorite.url]) }
            Divider()
            Button("Move Up") { favorites.move(fromOffsets: [index], toOffset: index - 1) }
                .disabled(index == 0)
            Button("Move Down") { favorites.move(fromOffsets: [index], toOffset: index + 2) }
                .disabled(index == favorites.favorites.count - 1)
            Button("Unpin") { favorites.remove(favorite.url) }
        }
    }
}

private struct EjectButton: View {
    let url: URL

    var body: some View {
        Button {
            try? NSWorkspace.shared.unmountAndEjectDevice(at: url)
        } label: {
            Image(systemName: "eject.fill")
                .font(.system(size: 9))
        }
        .buttonStyle(GhostButtonStyle(padding: 3))
        .help("Eject")
    }
}

/// S3 connections and Google accounts: click to browse, drop files on one (an S3 connection
/// with a bucket set, or Google Drive) to upload.
private struct CloudSection: View {
    let model: BrowserModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openTab) private var openTab

    var body: some View {
        SectionCaption(title: "Cloud")
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.top, 12)
            .padding(.bottom, 4)
        let connections = S3Store.shared.connections
        let drives = DriveStore.shared.accounts
        if connections.isEmpty && drives.isEmpty {
            SidebarRow(title: "Connect S3 or Google Drive…", systemImage: "plus.circle", isSelected: false, dimmed: true) { showSettings() }
        }
        ForEach(connections) { connection in
            let isCurrent = model.destination == .s3 && model.s3.location?.connectionID == connection.id
            SidebarRow(title: connection.name, systemImage: "cloud", isSelected: isCurrent,
                       dropURL: connection.bucket.isEmpty ? nil : connection.root.url, model: model) {
                model.showS3(connection.root)
            }
            .contextMenu {
                Button("Open in New Tab") { openTab(connection.root.url) }
                Button("Edit Connection…") { showSettings() }
            }
        }
        ForEach(drives) { account in
            let isCurrent = model.destination == .drive && model.drive.location?.accountID == account.id
            SidebarRow(title: DriveStore.shared.title(of: account), systemImage: "externaldrive.connected.to.line.below",
                       isSelected: isCurrent, dropURL: account.myDrive.url, model: model) {
                model.showDrive(account.myDrive)
            }
            .help(account.email)
            .contextMenu {
                Button("Open in New Tab") { openTab(account.myDrive.url) }
                Button("Shared with Me") { model.showDrive(DriveLocation(accountID: account.id, id: DriveLocation.sharedID, name: "Shared with me")) }
                Button("Starred") { model.showDrive(DriveLocation(accountID: account.id, id: DriveLocation.starredID, name: "Starred")) }
                Divider()
                Button("Google Drive Settings…") { showSettings() }
            }
        }
    }

    private func showSettings() {
        Prefs.shared.settingsTab = .cloud
        openSettings()
    }
}
