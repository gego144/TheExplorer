import SwiftUI

struct SidebarView: View {
    @Bindable var model: BrowserModel
    @Environment(\.openWindow) private var openWindow
    @State private var volumes: [URL] = SidebarView.mountedVolumes()

    private var favorites: FavoritesStore { .shared }

    var body: some View {
        List(selection: $model.sidebarSelection) {
            Section("Explore") {
                Label("Recents", systemImage: "clock.arrow.circlepath")
                    .tag(SidebarItem.recents)
                Label("Storage", systemImage: "chart.pie")
                    .tag(SidebarItem.storage)
            }

            Section("Favorites") {
                if favorites.favorites.isEmpty {
                    Text("Drag files or folders here, or press ⌘D")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .dropDestination(for: URL.self) { urls, _ in
                            urls.forEach { favorites.add($0) }
                            return !urls.isEmpty
                        }
                }
                ForEach(favorites.favorites) { favorite in
                    FavoriteRow(favorite: favorite)
                        .tag(SidebarItem.favorite(favorite.path))
                        .draggable(favorite.url)
                        .contextMenu {
                            if favorite.isDirectory {
                                Button("Open in New Tab") { Tabs.open(favorite.url, with: openWindow) }
                            } else {
                                Button("Open") { NSWorkspace.shared.open(favorite.url) }
                            }
                            Button("Show in Enclosing Folder") { model.reveal(favorite.url) }
                            Button("Reveal in Finder") { FileActions.revealInFinder([favorite.url]) }
                            Button("Copy Path") { FileActions.copyPaths([favorite.url]) }
                            Divider()
                            Button("Remove from Favorites") { favorites.remove(favorite.url) }
                        }
                }
                .onMove { favorites.move(fromOffsets: $0, toOffset: $1) }
                .dropDestination(for: URL.self) { urls, index in
                    for (offset, url) in urls.enumerated() {
                        favorites.add(url, at: index + offset)
                    }
                }
            }

            Section("Locations") {
                ForEach(Self.standardLocations, id: \.self) { url in
                    LocationRow(url: url)
                        .tag(SidebarItem.location(url))
                }
                ForEach(volumes, id: \.self) { url in
                    LocationRow(url: url, ejectable: !url.isRoot)
                        .tag(SidebarItem.location(url))
                }
            }
        }
        .listStyle(.sidebar)
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            volumes = Self.mountedVolumes()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            volumes = Self.mountedVolumes()
        }
    }

    static let standardLocations: [URL] = {
        let fm = FileManager.default
        var urls: [URL] = [.home]
        for directory: FileManager.SearchPathDirectory in [.desktopDirectory, .documentDirectory, .downloadsDirectory] {
            if let url = fm.urls(for: directory, in: .userDomainMask).first { urls.append(url) }
        }
        urls.append(URL(fileURLWithPath: "/Applications"))
        let iCloud = URL.home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        if fm.fileExists(atPath: iCloud.path) { urls.append(iCloud) }
        return urls.map(\.standardizedFileURL)
    }()

    static func mountedVolumes() -> [URL] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeNameKey], options: [.skipHiddenVolumes]) ?? []
        return urls.map(\.standardizedFileURL)
    }
}

private struct FavoriteRow: View {
    let favorite: Favorite

    var body: some View {
        let exists = favorite.exists
        Label {
            Text(favorite.name)
                .lineLimit(1)
                .truncationMode(.middle)
        } icon: {
            Image(nsImage: Icons.icon(forPath: favorite.path))
                .resizable()
                .frame(width: 16, height: 16)
        }
        .opacity(exists ? 1 : 0.4)
        .help(exists ? Format.path(favorite.path) : "Missing: \(Format.path(favorite.path))")
    }
}

private struct LocationRow: View {
    let url: URL
    var ejectable = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack {
            Label {
                Text(url.lastPathComponent == "com~apple~CloudDocs" ? "iCloud Drive" : FileManager.default.displayName(atPath: url.path))
            } icon: {
                Image(nsImage: Icons.icon(forPath: url.path))
                    .resizable()
                    .frame(width: 16, height: 16)
            }
            if ejectable {
                Spacer()
                Button {
                    try? NSWorkspace.shared.unmountAndEjectDevice(at: url)
                } label: {
                    Image(systemName: "eject.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Eject")
            }
        }
        .contextMenu {
            Button("Open in New Tab") { Tabs.open(url, with: openWindow) }
            Button("Reveal in Finder") { FileActions.revealInFinder([url]) }
            Button("Copy Path") { FileActions.copyPaths([url]) }
            Button("Add to Favorites") { FavoritesStore.shared.add(url) }
        }
    }
}
