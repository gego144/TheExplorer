import AppKit
import Observation
import SwiftUI

/// The sidebar, drawn by AppKit: pinned folders and files, views, devices, cloud accounts,
/// places and drives. Click a line to go there, drop files on a folder's line to move them in,
/// drop folders on "Pinned" to pin them, right-click for a line's menu.
///
/// In SwiftUI, every line was looked at again whenever the active pane changed folder or tab
/// (~4ms a move, ~17ms a tab switch); here the lines are a short list drawn in one pass.
final class SidebarPanel: NSView {
    private let scroll = NSScrollView()
    private let list: SidebarList
    private let border = NSView()

    init(workspace: Workspace, values: RegionValues) {
        list = SidebarList(workspace: workspace, values: values)
        super.init(frame: .zero)
        wantsLayer = true
        // A shade darker than the window, so the list reads as the main surface.
        layer?.backgroundColor = (NSColor(Theme.background).blended(withFraction: 0.12, of: .black) ?? NSColor(Theme.background)).cgColor
        scroll.drawsBackground = false
        scroll.verticalScroller = ThinScroller()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = list
        addSubview(scroll)
        border.wantsLayer = true
        border.layer?.backgroundColor = NSColor(Theme.border).cgColor
        addSubview(border)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        border.frame = NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height)
        list.fit(width: scroll.contentSize.width)
    }
}

/// One line of the sidebar.
private struct SidebarItem {
    enum Kind {
        case caption(pinsDrop: Bool)
        case hint
        case row
    }

    enum Icon {
        case none
        case symbol(String)
        case dot(NSColor)
    }

    /// A small button at the end of a line (eject, the QR code, the disclosure arrow).
    struct Trailing {
        let symbol: String
        let size: CGFloat
        let weight: NSFont.Weight
        let help: String
        let action: () -> Void
    }

    let kind: Kind
    let title: String
    var icon = Icon.none
    var isSelected = false
    var dimmed = false
    var indent: CGFloat = 0
    var trailing: Trailing?
    /// Where files dropped on the line go.
    var dropURL: URL?
    /// What dragging the line carries (pinned items).
    var dragURL: URL?
    /// The folder it opens, read ahead when it's pointed at.
    var opens: URL?
    /// Whether clicking it goes somewhere (so the line lights up at once, ahead of the move).
    var navigates = false
    var tooltip: String?
    var action: () -> Void = {}
    var menu: (() -> AnyView)?

    static func caption(_ title: String, pinsDrop: Bool = false) -> SidebarItem {
        SidebarItem(kind: .caption(pinsDrop: pinsDrop), title: title, tooltip: pinsDrop ? "Drop here to pin" : nil)
    }

    /// What it looks like, to redraw only the lines that changed.
    var look: String {
        let mark: String
        switch icon {
        case .none: mark = ""
        case .symbol(let name): mark = name
        case .dot(let color): mark = color.description
        }
        return "\(title)|\(mark)|\(isSelected)|\(dimmed)|\(trailing?.symbol ?? "")"
    }

    /// Where it goes and what it says when pointed at; when these change, the lines are laid out again.
    var place: String {
        let tag: String
        switch kind {
        case .caption(let pinsDrop): tag = "c\(pinsDrop)"
        case .hint: tag = "h"
        case .row: tag = "r"
        }
        return "\(tag)|\(indent)|\(tooltip ?? "")|\(trailing?.help ?? "")"
    }

    var height: CGFloat {
        switch kind {
        case .caption: 12 + 12 + 4
        case .hint: 4 + 14 + 4
        case .row: Theme.controlHeight
        }
    }
}

private final class SidebarList: NSView, NSDraggingSource {
    private let workspace: Workspace
    private let values: RegionValues
    private let theme = TableTheme()
    private let raised = NSColor(Theme.raised)
    private let pressedFill = NSColor(Theme.pressedFill)
    private let rowFont = NSFont.systemFont(ofSize: 13)
    private let rowBoldFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    private let captionFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    /// Places you aren't in: a step down from the text color, so the current one stands out.
    private lazy var rowColor = theme.text.withAlphaComponent(0.74)
    private let hintFont = NSFont.systemFont(ofSize: 11)

    private var items: [SidebarItem] = []
    private var frames: [NSRect] = []
    private var volumes: [(url: URL, name: String)] = []
    private var driveAccounts: [UUID] = []
    private var setupRequest: Int

    private var hovered: Int?
    private var hoveredTrailing = false
    private var pressedTrailing: Int?
    private var dropTarget: Int?
    /// A pinned line pressed but not yet released: a click opens it, a drag carries it.
    private var pressedDraggable: (index: Int, at: NSPoint)?
    /// A line clicked and drawn as current, until the move it starts is made.
    private var pendingSelection: Int?
    private var pendingChanges = 0
    private var generation = 0
    private var tracking: NSTrackingArea?
    private var mountObservers: [NSObjectProtocol] = []
    private weak var sheet: NSViewController?

    init(workspace: Workspace, values: RegionValues) {
        self.workspace = workspace
        self.values = values
        setupRequest = PhoneLink.shared.setupRequest
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL, .URL])
        readVolumes()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            mountObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.readVolumes()
                    self?.refresh()
                }
            })
        }
        refresh()
        #if DEBUG
        RowGeometry.providers[ObjectIdentifier(self)] = { [weak self] in self?.debugFrames() ?? [] }
        #endif
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        for observer in mountObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func readVolumes() {
        volumes = SidebarPlaces.mountedVolumes().map { ($0, Format.displayName($0.path)) }
    }

    // MARK: Following what it shows

    /// Reads the lines, and again whenever anything they show changes.
    private func refresh() {
        guard pendingChanges == 0 else { return }
        generation += 1
        let current = generation
        let old = items
        items = withObservationTracking { readItems() } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.generation == current else { return }
                self.refresh()
            }
        }
        if let pendingSelection, frames.indices.contains(pendingSelection) { setNeedsDisplay(frames[pendingSelection]) }
        pendingSelection = nil
        if let hovered, !items.indices.contains(hovered) { self.hovered = nil }
        if old.count == items.count && zip(old, items).allSatisfy({ $0.place == $1.place }) {
            // The same lines: only those that look different are drawn again.
            for (index, (before, after)) in zip(old, items).enumerated() where before.look != after.look {
                setNeedsDisplay(frames[index])
            }
        } else {
            relayout()
            needsDisplay = true
        }
        followSetupRequests()
    }

    /// "From iPhone" setup asked for elsewhere (the menu): shown in the window you're in.
    private func followSetupRequests() {
        let request = PhoneLink.shared.setupRequest
        guard request != setupRequest else { return }
        setupRequest = request
        guard let window, NSApp.keyWindow == nil || window == NSApp.keyWindow else { return }
        showPhoneSetup()
    }

    private func readItems() -> [SidebarItem] {
        let model = workspace.selected
        _ = PhoneLink.shared.setupRequest
        let browsing = !model.isSearching && model.destination == .folder
        var items: [SidebarItem] = []

        // Pinned
        let favorites = FavoritesStore.shared
        items.append(.caption("Pinned", pinsDrop: true))
        if favorites.favorites.isEmpty {
            items.append(SidebarItem(kind: .hint, title: "Drop folders on “Pinned”, or press ⌘D"))
        }
        for (index, favorite) in favorites.favorites.enumerated() {
            let exists = favorites.exists(favorite)
            items.append(SidebarItem(
                kind: .row, title: favorites.name(of: favorite), icon: .dot(NSColor(Theme.paletteColor(for: favorite.path))),
                isSelected: browsing && model.currentURL.path == favorite.path, dimmed: !exists,
                dropURL: favorite.isDirectory && exists ? favorite.url : nil, dragURL: favorite.url,
                opens: favorite.isDirectory && exists ? favorite.url : nil, navigates: favorite.isDirectory,
                tooltip: exists ? Format.path(favorite.path) : "Missing: \(Format.path(favorite.path))",
                action: { [weak self] in self?.workspace.selected.openFavorite(favorite.path) },
                menu: { [weak self] in AnyView(self?.pinnedMenu(favorite, index: index)) }
            ))
        }

        // Views
        items.append(.caption("Views"))
        for (title, symbol, destination) in [("Recents", "clock", Destination.recents), ("New", "sparkles", .newFiles), ("Storage", "chart.pie", .storage)] {
            items.append(SidebarItem(kind: .row, title: title, icon: .symbol(symbol),
                                     isSelected: !model.isSearching && model.destination == destination, navigates: true,
                                     action: { [weak self] in self?.workspace.selected.show(destination) }))
        }

        // Devices
        items.append(.caption("Devices"))
        let link = PhoneLink.shared
        let importFolder = Prefs.shared.importFolder
        items.append(SidebarItem(
            kind: .row, title: "From iPhone", icon: .symbol("iphone.radiowaves.left.and.right"),
            isSelected: browsing && model.currentURL == importFolder.standardizedFileURL, dimmed: !link.isOn,
            trailing: .init(symbol: "qrcode", size: 10, weight: .semibold, help: "Show the QR code for your iPhone") { [weak self] in
                self?.showPhoneSetup()
            },
            dropURL: importFolder, opens: link.isOn ? importFolder : nil, navigates: link.isOn,
            tooltip: link.isOn ? "Photos sent from your iPhone land in “\(importFolder.lastPathComponent)”" : "Set up sending photos from your iPhone over Wi-Fi",
            action: { [weak self] in
                if PhoneLink.shared.isOn { self?.openImportFolder() } else { self?.showPhoneSetup() }
            },
            menu: { [weak self] in AnyView(self?.phoneMenu()) }
        ))

        // Cloud
        items.append(.caption("Cloud"))
        let connections = S3Store.shared.connections
        let drives = DriveStore.shared
        if connections.isEmpty && drives.accounts.isEmpty {
            items.append(SidebarItem(kind: .row, title: "Connect S3 or Google Drive…", icon: .symbol("plus.circle"), dimmed: true,
                                     action: { [weak self] in self?.showCloudSettings() }))
        }
        for connection in connections {
            items.append(SidebarItem(
                kind: .row, title: connection.name, icon: .symbol("cloud"),
                isSelected: model.destination == .s3 && model.s3.location?.connectionID == connection.id,
                dropURL: connection.bucket.isEmpty ? nil : connection.root.url, navigates: true,
                action: { [weak self] in self?.workspace.selected.showS3(connection.root) },
                menu: { [weak self] in
                    AnyView(Group {
                        Button("Open in New Tab") { self?.workspace.newTab(connection.root.url) }
                        Button("Edit Connection…") { self?.showCloudSettings() }
                    })
                }
            ))
        }
        for account in drives.accounts {
            let section = driveSection(of: account, in: model)
            let expanded = !drives.collapsed.contains(account.id)
            items.append(SidebarItem(
                kind: .row, title: drives.title(of: account), icon: .symbol("externaldrive.connected.to.line.below"),
                isSelected: section == DriveLocation.myDriveID || section == DriveLocation.homeID,
                trailing: .init(symbol: expanded ? "chevron.down" : "chevron.right", size: 8, weight: .heavy,
                                help: expanded ? "Hide Shared with me, Starred and shared drives" : "Show Shared with me, Starred and shared drives") {
                    if expanded { DriveStore.shared.collapsed.insert(account.id) } else { DriveStore.shared.collapsed.remove(account.id) }
                },
                dropURL: account.myDrive.url, navigates: true, tooltip: "My Drive · \(account.email)",
                action: { [weak self] in self?.workspace.selected.showDrive(account.myDrive) },
                menu: { [weak self] in
                    AnyView(Group {
                        Button("Open in New Tab") { self?.workspace.newTab(account.myDrive.url) }
                        Divider()
                        Button("Google Drive Settings…") { self?.showCloudSettings() }
                    })
                }
            ))
            // Its other places, each a click away: what's shared with you, starred, and every
            // shared drive you're in.
            guard expanded else { continue }
            var places = [(DriveLocation(accountID: account.id, id: DriveLocation.sharedID, name: "Shared with me"), "person.2", false),
                          (DriveLocation(accountID: account.id, id: DriveLocation.starredID, name: "Starred"), "star", false)]
            for drive in drives.sharedDrives[account.id] ?? [] {
                places.append((DriveLocation(accountID: account.id, id: drive.id, name: drive.name), "externaldrive.badge.person.crop", true))
            }
            for (place, symbol, drops) in places {
                items.append(SidebarItem(
                    kind: .row, title: place.name, icon: .symbol(symbol), isSelected: section == place.id, indent: 14,
                    dropURL: drops ? place.url : nil, navigates: true,
                    action: { [weak self] in self?.workspace.selected.showDrive(place) },
                    menu: { [weak self] in AnyView(Button("Open in New Tab") { self?.workspace.newTab(place.url) }) }
                ))
            }
            if let error = drives.sharedDrivesError[account.id] {
                items.append(SidebarItem(kind: .row, title: "Drives didn't load", icon: .symbol("exclamationmark.triangle"), dimmed: true,
                                         indent: 14, tooltip: error + " Click to try again.",
                                         action: { DriveStore.shared.refreshSharedDrives(account.id) }))
            }
        }
        let accountIDs = drives.accounts.map(\.id)
        if accountIDs != driveAccounts {
            driveAccounts = accountIDs
            DispatchQueue.main.async {
                for id in accountIDs { DriveStore.shared.refreshSharedDrives(id) }
            }
        }

        // Places and drives
        items.append(.caption("Places"))
        for place in SidebarPlaces.places {
            items.append(locationRow(place.title, symbol: place.symbol, url: place.url, isSelected: browsing && model.currentURL == place.url))
        }
        items.append(.caption("Drives"))
        for volume in volumes {
            let url = volume.url
            var row = locationRow(volume.name, symbol: url.isRoot ? "internaldrive" : "externaldrive", url: url,
                                  isSelected: browsing && model.currentURL == url)
            if !url.isRoot {
                row.trailing = .init(symbol: "eject.fill", size: 9, weight: .regular, help: "Eject") {
                    try? NSWorkspace.shared.unmountAndEjectDevice(at: url)
                }
            }
            items.append(row)
        }
        if let volume = model.volume, model.destination == .folder {
            items.append(SidebarItem(kind: .hint, title: "\(Format.bytes(volume.available)) available"))
        }
        return items
    }

    private func locationRow(_ title: String, symbol: String, url: URL, isSelected: Bool) -> SidebarItem {
        SidebarItem(kind: .row, title: title, icon: .symbol(symbol), isSelected: isSelected, dropURL: url, opens: url, navigates: true,
                    action: { [weak self] in self?.workspace.selected.navigate(to: url) },
                    menu: { [weak self] in
                        AnyView(Group {
                            Button("Open in New Tab") { self?.workspace.newTab(url) }
                            Button(FileActions.openInTerminalTitle) { FileActions.openInTerminal(url) }
                            Button("Copy Path") { FileActions.copyPaths([url]) }
                            Button(FileActions.revealTitle) { FileActions.revealInFinder([url]) }
                            Button("Pin") { FavoritesStore.shared.add(url) }
                        })
                    })
    }

    /// Which of an account's places the active pane is in: My Drive, Shared with me, Starred or
    /// a shared drive (by ID). Nil when it's showing something else.
    private func driveSection(of account: DriveAccount, in model: BrowserModel) -> String? {
        guard model.destination == .drive, let location = model.drive.location, location.accountID == account.id else { return nil }
        let trail = model.drive.trail
        guard trail.count > 1 else { return location.id }
        if trail[1].id == DriveLocation.drivesID { return trail.count > 2 ? trail[2].id : DriveLocation.drivesID }
        return trail[1].id
    }

    // MARK: Menus and actions

    @ViewBuilder
    private func pinnedMenu(_ favorite: Favorite, index: Int) -> some View {
        let favorites = FavoritesStore.shared
        if favorite.isDirectory {
            Button("Open in New Tab") { [weak self] in self?.workspace.newTab(favorite.url) }
            Button(FileActions.openInTerminalTitle) { FileActions.openInTerminal(favorite.url) }
        } else {
            Button("Open") { FileOpener.open([favorite.url]) }
            OpenWithMenu(urls: [favorite.url])
        }
        Button("Show in Enclosing Folder") { [weak self] in self?.workspace.selected.reveal(favorite.url) }
        Button("Copy Path") { FileActions.copyPaths([favorite.url]) }
        Divider()
        Button("Move Up") { favorites.move(fromOffsets: [index], toOffset: index - 1) }
            .disabled(index == 0)
        Button("Move Down") { favorites.move(fromOffsets: [index], toOffset: index + 2) }
            .disabled(index == favorites.favorites.count - 1)
        Button("Unpin") { favorites.remove(favorite.url) }
    }

    @ViewBuilder
    private func phoneMenu() -> some View {
        let link = PhoneLink.shared
        Button("Show QR Code…") { [weak self] in self?.showPhoneSetup() }
        Button("Open in New Tab") { [weak self] in self?.workspace.newTab(Prefs.shared.importFolder) }
        Button("Change Folder…") { PhoneLinkSheet.chooseFolder() }
        Divider()
        Button(link.isOn ? "Stop Receiving" : "Start Receiving") { link.setOn(!link.isOn) }
    }

    private func showCloudSettings() {
        Prefs.shared.settingsTab = .cloud
        values.showSettings()
    }

    /// The folder photos arrive in, as a gallery the first time.
    private func openImportFolder() {
        let folder = Prefs.shared.importFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let place = folder.standardizedFileURL.path
        if !UserDefaults.standard.bool(forKey: "phoneLinkFolderShown") {
            UserDefaults.standard.set(true, forKey: "phoneLinkFolderShown")
            Prefs.shared.setGallery(true, for: place)
        }
        workspace.selected.navigate(to: folder)
    }

    /// The QR code and setup for sending photos from an iPhone, as a sheet on this window.
    private func showPhoneSetup() {
        guard sheet == nil, let presenter = window?.contentViewController else { return }
        weak var controller: NSViewController?
        let host = NSHostingController(rootView: PhoneLinkSheet { [weak self] opened in
            if let controller { presenter.dismiss(controller) }
            if opened { self?.openImportFolder() }
        }.modifier(RegionStyle(values: values)))
        controller = host
        sheet = host
        presenter.presentAsSheet(host)
    }

    /// Runs a line's action. A line that goes somewhere is drawn as current and sent to the
    /// screen first; the move is made on the next turn of the run loop.
    private func run(_ index: Int) {
        let item = items[index]
        guard item.navigates, !item.isSelected, window != nil else { return item.action() }
        pendingSelection = index
        setNeedsDisplay(frames[index])
        if let current = items.firstIndex(where: \.isSelected) { setNeedsDisplay(frames[current]) }
        displayIfNeeded()
        CATransaction.flush()
        LatencyMeter.shared.noteFlush()
        pendingChanges += 1
        DispatchQueue.main.async { [weak self] in
            item.action()
            guard let self else { return }
            self.pendingChanges -= 1
            self.refresh()
        }
    }

    // MARK: Layout

    func fit(width: CGFloat) {
        let height = relayout(width: width)
        setFrameSize(NSSize(width: width, height: max(height, superview?.bounds.height ?? 0)))
    }

    @discardableResult
    private func relayout(width: CGFloat? = nil) -> CGFloat {
        let width = width ?? bounds.width
        var y: CGFloat = 8
        frames = items.map { item in
            let frame = NSRect(x: 8, y: y, width: max(0, width - 16), height: item.height)
            y = frame.maxY + 1
            return frame
        }
        let height = y - 1 + 8
        if width == bounds.width, abs(height - frame.height) > 0.5, superview != nil {
            setFrameSize(NSSize(width: width, height: max(height, superview?.bounds.height ?? 0)))
        }
        updateToolTips()
        return height
    }

    private func trailingFrame(_ index: Int) -> NSRect? {
        guard let trailing = items[index].trailing, frames.indices.contains(index) else { return nil }
        let image = theme.symbol(trailing.symbol, size: trailing.size, weight: trailing.weight, color: theme.textTertiary)
        // The disclosure arrow sits in a fixed square, so it doesn't jump as it turns.
        let side = trailing.symbol.hasPrefix("chevron") ? 12 : max(image.size.width, image.size.height)
        let size = side + 6
        let row = frames[index]
        return NSRect(x: row.maxX - 8 - size + 3, y: row.midY - size / 2, width: size, height: size)
    }

    private func index(at point: NSPoint) -> Int? {
        frames.firstIndex { $0.minY <= point.y && point.y < $0.maxY + 1 && $0.minX <= point.x && point.x <= $0.maxX }
    }

    private func updateToolTips() {
        removeAllToolTips()
        for (index, item) in items.enumerated() where frames.indices.contains(index) {
            if let tooltip = item.tooltip { addToolTip(frames[index], owner: tooltip as NSString, userData: nil) }
            if let trailing = item.trailing, let rect = trailingFrame(index) {
                addToolTip(rect, owner: trailing.help as NSString, userData: nil)
            }
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        for (index, item) in items.enumerated() where frames.indices.contains(index) && frames[index].intersects(dirtyRect) {
            let frame = frames[index]
            switch item.kind {
            case .caption(let pinsDrop):
                if pinsDrop && dropTarget == index {
                    theme.accentSoft.setFill()
                    NSBezierPath(roundedRect: frame, xRadius: 5, yRadius: 5).fill()
                }
                let text = NSAttributedString(string: item.title, attributes: [.font: captionFont, .foregroundColor: theme.textTertiary])
                text.draw(at: NSPoint(x: frame.minX + 10, y: frame.minY + 11))
            case .hint:
                let text = NSAttributedString(string: item.title, attributes: [.font: hintFont, .foregroundColor: theme.textTertiary])
                text.draw(with: NSRect(x: frame.minX + 8, y: frame.minY + 4, width: frame.width - 16, height: 14),
                          options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            case .row:
                drawRow(item, index: index, in: frame)
            }
        }
    }

    private func drawRow(_ item: SidebarItem, index: Int, in frame: NSRect) {
        let isSelected = pendingSelection.map { $0 == index } ?? item.isSelected
        let isHovered = hovered == index || HoverPreview.on
        let fill: NSColor? = isSelected ? (isHovered ? theme.raisedHover : raised) : (isHovered ? theme.hoverFill : nil)
        let shape = NSBezierPath(roundedRect: frame, xRadius: Theme.controlRadius, yRadius: Theme.controlRadius)
        if let fill {
            fill.setFill()
            shape.fill()
        }
        if dropTarget == index {
            let ring = NSBezierPath(roundedRect: frame.insetBy(dx: 0.6, dy: 0.6), xRadius: Theme.controlRadius, yRadius: Theme.controlRadius)
            ring.lineWidth = 1.2
            theme.accent.setStroke()
            ring.stroke()
        }
        // Words only: no icons or colored dots before them.
        let x = frame.minX + 10 + item.indent
        let trailing = trailingFrame(index)
        let end = (trailing?.minX ?? frame.maxX - 8) - (trailing == nil ? 0 : 8)
        let color = isSelected || (isHovered && !item.dimmed) ? theme.text : (item.dimmed ? theme.textTertiary : rowColor)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingMiddle
        let title = NSAttributedString(string: item.title, attributes: [
            .font: isSelected ? rowBoldFont : rowFont, .foregroundColor: color, .paragraphStyle: style,
        ])
        let height = ceil(title.size().height)
        title.draw(with: NSRect(x: x, y: frame.midY - height / 2, width: max(0, end - x), height: height),
                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        if let trailing, let button = item.trailing {
            let onButton = hovered == index && hoveredTrailing
            if onButton {
                (pressedTrailing == index ? pressedFill : theme.raisedHover).setFill()
                NSBezierPath(roundedRect: trailing, xRadius: Theme.chipRadius, yRadius: Theme.chipRadius).fill()
            }
            let image = theme.symbol(button.symbol, size: button.size, weight: button.weight, color: onButton ? theme.text : theme.textTertiary)
            image.draw(in: NSRect(x: trailing.midX - image.size.width / 2, y: trailing.midY - image.size.height / 2,
                                  width: image.size.width, height: image.size.height))
        }
    }

    private func redraw(_ index: Int?) {
        if let index, frames.indices.contains(index) { setNeedsDisplay(frames[index]) }
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    private func hover(at point: NSPoint?) {
        var index = point.flatMap { self.index(at: $0) }
        if let found = index, case .row = items[found].kind {} else { index = nil }
        var onTrailing = false
        if let index, let point, let frame = trailingFrame(index) { onTrailing = frame.contains(point) }
        guard index != hovered || onTrailing != hoveredTrailing else { return }
        redraw(hovered)
        redraw(index)
        hovered = index
        hoveredTrailing = onTrailing
        if let index, let folder = items[index].opens { ListingCache.shared.readAhead(folder, .pointer) }
        (index != nil ? NSCursor.pointingHand : NSCursor.arrow).set()
    }

    override func mouseMoved(with event: NSEvent) { hover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseEntered(with event: NSEvent) { hover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { hover(at: nil) }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = index(at: point), case .row = items[index].kind else { return }
        if let trailing = trailingFrame(index), trailing.contains(point) {
            pressedTrailing = index
            redraw(index)
            return
        }
        // A pinned line can be dragged out, so it opens when you let go; the rest on the press.
        if items[index].dragURL != nil {
            pressedDraggable = (index, point)
        } else {
            run(index)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressed = pressedDraggable, items.indices.contains(pressed.index), let url = items[pressed.index].dragURL else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - pressed.at.x, point.y - pressed.at.y) > 3 else { return }
        pressedDraggable = nil
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let frame = frames[pressed.index]
        item.setDraggingFrame(frame, contents: snapshot(of: frame))
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let index = pressedTrailing {
            pressedTrailing = nil
            redraw(index)
            if items.indices.contains(index), let trailing = trailingFrame(index), trailing.contains(point) {
                items[index].trailing?.action()
            }
            return
        }
        if let pressed = pressedDraggable {
            pressedDraggable = nil
            if index(at: point) == pressed.index, items.indices.contains(pressed.index) { run(pressed.index) }
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let index = index(at: convert(event.locationInWindow, from: nil)), let content = items[index].menu?() else { return nil }
        return NSHostingMenu(rootView: content)
    }

    private func snapshot(of rect: NSRect) -> NSImage {
        guard let bitmap = bitmapImageRepForCachingDisplay(in: rect) else { return NSImage() }
        cacheDisplay(in: rect, to: bitmap)
        let image = NSImage(size: rect.size)
        image.addRepresentation(bitmap)
        return image
    }

    // MARK: Dragging pins out

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // A pin carries its item as the file list does: dropped in a folder it moves there
        // (copies with ⌥, or onto another disk).
        [.copy, .move, .link, .generic]
    }

    // MARK: Dropping

    private func dropIndex(_ sender: NSDraggingInfo) -> Int? {
        guard let index = index(at: convert(sender.draggingLocation, from: nil)) else { return nil }
        switch items[index].kind {
        case .caption(let pinsDrop): return pinsDrop ? index : nil
        case .row: return items[index].dropURL == nil ? nil : index
        case .hint: return nil
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let index = dropIndex(sender)
        if index != dropTarget {
            redraw(dropTarget)
            redraw(index)
            dropTarget = index
        }
        guard let index else { return [] }
        if case .caption = items[index].kind { return sender.draggingSourceOperationMask.contains(.link) ? .link : .copy }
        return NSEvent.modifierFlags.contains(.option) ? .copy : .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { endDrop() }
    override func draggingEnded(_ sender: NSDraggingInfo) { endDrop() }

    private func endDrop() {
        guard dropTarget != nil else { return }
        redraw(dropTarget)
        dropTarget = nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { endDrop() }
        guard let index = dropIndex(sender) else { return false }
        let urls = FileTableController.urls(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        if case .caption = items[index].kind {
            urls.forEach { FavoritesStore.shared.add($0) }
            return true
        }
        guard let folder = items[index].dropURL else { return false }
        return workspace.selected.receiveDrop(urls, into: folder)
    }

    // MARK: Scripted runs

    #if DEBUG
    /// Each line as "sidebar-<title>", in the window from its top left.
    private func debugFrames() -> [(URL, CGRect, Int)] {
        guard let content = window?.contentView else { return [] }
        return zip(items, frames).compactMap { item, frame in
            guard case .row = item.kind else { return nil }
            let rect = convert(frame, to: nil)
            return (URL(fileURLWithPath: "/debug-rows/sidebar-" + item.title),
                    CGRect(x: rect.minX, y: content.bounds.height - rect.maxY, width: rect.width, height: rect.height), 0)
        }
    }
    #endif
}

/// The standard places and the mounted drives the sidebar lists.
@MainActor
enum SidebarPlaces {
    struct Place {
        let title: String
        let symbol: String
        let url: URL
    }

    static let places: [Place] = {
        let fm = FileManager.default
        var places = [Place(title: Format.displayName(URL.home.path), symbol: "house", url: .home)]
        let standard: [(FileManager.SearchPathDirectory, String)] = [
            (.desktopDirectory, "menubar.dock.rectangle"), (.documentDirectory, "doc"), (.downloadsDirectory, "arrow.down.circle"),
        ]
        for (directory, symbol) in standard {
            if let url = fm.urls(for: directory, in: .userDomainMask).first {
                places.append(Place(title: Format.displayName(url.path), symbol: symbol, url: url))
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
