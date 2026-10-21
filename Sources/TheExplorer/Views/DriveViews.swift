import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Browsing

/// A Google account's top level, a Drive folder or Drive's search, in the same list as local
/// folders. Drop files on it (or a folder row) to upload, drag Drive items between folders to
/// move them, and drag them onto any local folder to download. Typing in the command bar
/// searches Drive.
struct DriveView: View {
    @Bindable var model: BrowserModel
    @Environment(\.openTab) private var openTab

    private var drive: DriveBrowser { model.drive }

    var body: some View {
        VStack(spacing: 0) {
            if let error = drive.error {
                Banner(symbol: "exclamationmark.triangle.fill", tint: Theme.danger, text: error,
                       actionTitle: "Retry", action: { drive.reload() }, onDismiss: { drive.dismissError() })
            }
            FileListView(
                rows: drive.rows,
                selection: Binding(get: { drive.selection }, set: { drive.selection = $0 }),
                sort: drive.sort,
                onSort: { drive.sort = drive.sort.toggled(to: $0) },
                dateTitle: drive.location?.id == DriveLocation.drivesID ? "Created" : "Modified",
                empty: emptyState,
                onOpen: open,
                onQuickLook: { model.quickLook($0, in: $1) },
                onDropInto: { urls, folder in model.receiveDrop(urls, into: folder) },
                onDropBackground: { urls in drive.canAddItems ? drive.location.map { model.receiveDrop(urls, into: $0.url) } ?? false : false },
                onReachEnd: drive.hasMore ? { drive.loadMore() } : nil,
                footer: drive.hasMore ? AnyView(loadingMore) : nil,
                rowMenu: { DriveRowMenu(urls: $0, model: model) },
                backgroundMenu: { DriveBackgroundMenu(model: model) }
            )
        }
        // Drive's search runs a moment after typing stops.
        .task(id: model.searchText) {
            let text = model.searchText.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
            }
            drive.search(text)
        }
    }

    private var loadingMore: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text("Loading more…")
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.textTertiary)
        .frame(maxWidth: .infinity)
        .padding(10)
    }

    private var emptyState: EmptyState? {
        guard !drive.isLoading, drive.error == nil else { return nil }
        if drive.isSearching {
            return EmptyState(symbol: "magnifyingglass", title: "No matches in Drive", hint: "Drive searches names and the text inside documents.")
        }
        switch drive.location?.id {
        case DriveLocation.sharedID: return EmptyState(symbol: "person.2", title: "Nothing shared with you")
        case DriveLocation.starredID: return EmptyState(symbol: "star", title: "Nothing starred", hint: "Star files in Drive to keep them here.")
        case DriveLocation.drivesID: return EmptyState(symbol: "externaldrive.connected.to.line.below", title: "No shared drives")
        default: return EmptyState(symbol: "icloud.and.arrow.up", title: "Nothing here yet", hint: "Drop files or folders here to upload them.")
        }
    }

    private func open(_ urls: Set<URL>, newTab: Bool) {
        let targets = drive.rows.filter { urls.contains($0.id) }
        for row in targets where row.item.isFolder {
            if newTab || targets.count > 1 { openTab(row.id) } else { model.navigate(to: row.id) }
        }
        DriveActions.openFiles(targets.filter { !$0.item.isFolder }.map(\.id))
    }
}

/// What opening does with Drive files: Google Docs and the like open in the browser, since
/// that's where they live; everything else is downloaded (once) and opened.
@MainActor
enum DriveActions {
    static func openFiles(_ urls: [URL]) {
        for url in urls {
            if let file = DriveStore.shared.file(at: url), file.isGoogleDoc {
                DriveBrowser.openLink(file)
            } else {
                Transfers.shared.fetchForViewing(drive: url) { FileOpener.open([$0]) }
            }
        }
    }

    static func chooseFolder(prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseUploads() -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Upload"
        return panel.runModal() == .OK ? panel.urls : []
    }
}

private struct DriveRowMenu: View {
    let urls: Set<URL>
    let model: BrowserModel
    @Environment(\.openTab) private var openTab

    var body: some View {
        let targets = urls.compactMap(DriveLocation.init(url:))
        let isPlaces = targets.contains(where: \.isVirtual)
        let single = urls.count == 1 ? urls.first : nil
        let singleTarget = targets.count == 1 ? targets.first : nil
        let file = single.flatMap(DriveStore.shared.file(at:))
        let sorted = urls.sorted { $0.absoluteString < $1.absoluteString }
        if let single, let singleTarget {
            Button(file?.isGoogleDoc == true ? "Open in \(file?.googleKind ?? "Browser")" : "Open") {
                if singleTarget.isFolder { model.navigate(to: single) } else { DriveActions.openFiles([single]) }
            }
            if singleTarget.isFolder { Button("Open in New Tab") { openTab(single) } }
            if !singleTarget.isFolder { Button("Quick Look") { model.quickLook([single]) } }
            Divider()
        }
        if !isPlaces {
            if let single {
                Button("Share…") { model.drive.share(single) }
            }
            Button("Open in Browser") { model.drive.openInBrowser(sorted) }
            Button(urls.count == 1 ? "Copy Link" : "Copy Links") { model.drive.copyLink(sorted) }
            Divider()
            Button("Download to Downloads") { Transfers.shared.download(drive: sorted, into: URL.downloadsDirectory) }
            Button("Download To…") {
                guard let folder = DriveActions.chooseFolder(prompt: "Download Here") else { return }
                Transfers.shared.download(drive: sorted, into: folder)
            }
            if let single, let file, file.isGoogleDoc {
                let formats = DriveExport.formats(for: file.contentType)
                if formats.count > 1 {
                    Menu("Download As") {
                        ForEach(formats, id: \.self) { format in
                            Button("\(format.title) (.\(format.fileExtension))") {
                                Transfers.shared.download(drive: [single], into: URL.downloadsDirectory, as: format)
                            }
                        }
                    }
                }
            }
            Divider()
            // Pasted into a local folder, these download; into a Drive folder, they're copied.
            Button("Copy") { FileClipboard.shared.copy(sorted) }
            PasteItems(model: model, folder: singleTarget?.isFolder == true ? single : nil)
            Divider()
            if let single {
                Button("Rename…") { model.renaming = model.drive.rows.first { $0.id == single }?.item }
                    .disabled(file?.canRename == false)
            }
            Button("Move to Trash") { model.drive.trash(urls) }
                .disabled(file?.canTrash == false)
        } else if let single {
            Button("Open in Browser") { model.drive.openInBrowser([single]) }
        }
    }
}

private struct DriveBackgroundMenu: View {
    let model: BrowserModel

    var body: some View {
        let drive = model.drive
        if drive.canAddItems, let location = drive.location {
            Button("New Folder…") { model.creating = .folder }
            Button("Upload Files…") {
                let urls = DriveActions.chooseUploads()
                if !urls.isEmpty { Transfers.shared.upload(urls, toDrive: location) }
            }
            let count = FileClipboard.shared.urls.count
            Button(count > 1 ? "Paste \(count) Items" : "Paste") { model.paste() }
                .disabled(count == 0)
            Divider()
        }
        if let location = drive.location {
            Button("Open in Browser") { drive.openInBrowser([location.url]) }
        }
        Button("Refresh") { drive.reload(keepSelection: true) }
    }
}

// MARK: - Command bar

/// "Google Drive / My Drive / Projects": click to go there, drop files to upload or move
/// Drive items into it.
struct DriveBreadcrumbs: View {
    let model: BrowserModel

    var body: some View {
        let drive = model.drive
        HStack(spacing: 4) {
            ForEach(Array(drive.trail.enumerated()), id: \.offset) { index, location in
                if index > 0 { Text("/").foregroundStyle(Theme.textTertiary) }
                DriveChip(location: location, isCurrent: index == drive.trail.count - 1 && !drive.isSearching, model: model)
            }
            if drive.isSearching {
                Text("/").foregroundStyle(Theme.textTertiary)
                Text("Search “\(drive.query)”")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
            }
        }
        .fixedSize()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DriveChip: View {
    let location: DriveLocation
    let isCurrent: Bool
    let model: BrowserModel
    @State private var targeted = false

    var body: some View {
        Button { model.showDrive(location) } label: {
            Text(title)
        }
        .buttonStyle(CrumbStyle(isCurrent: isCurrent, highlighted: targeted))
        .dropDestination(for: URL.self) { urls, _ in
            !location.isVirtual && model.receiveDrop(urls, into: location.url)
        } isTargeted: { targeted = $0 && !location.isVirtual }
    }

    private var title: String {
        guard location.id == DriveLocation.homeID else { return location.name }
        return DriveStore.shared.account(location.accountID).map(DriveStore.shared.title) ?? "Google Drive"
    }
}

// MARK: - Inspector

/// Details for selected Drive items, or the account's storage when nothing is selected.
struct DriveInspector: View {
    let model: BrowserModel

    var body: some View {
        let drive = model.drive
        let selected = drive.rows.filter { drive.selection.contains($0.id) }
        VStack(alignment: .leading, spacing: 12) {
            if selected.isEmpty {
                account
            } else if selected.count == 1, let row = selected.first {
                single(row)
            } else {
                Text("\(selected.count) selected").font(.system(size: 14, weight: .semibold))
                let bytes = selected.compactMap(\.size).reduce(0, +)
                let folders = selected.filter(\.item.isFolder).count
                Text("\(folders) \(folders == 1 ? "folder" : "folders") · \(selected.count - folders) files · \(Format.bytes(bytes))")
                    .font(Theme.mono)
                    .foregroundStyle(Theme.textSecondary)
                buttons(selected.map(\.id), single: nil)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(padding: 14)
    }

    @ViewBuilder private var account: some View {
        if let location = model.drive.location, let account = DriveStore.shared.account(location.accountID) {
            HStack(spacing: 8) {
                Image(systemName: "externaldrive.connected.to.line.below").foregroundStyle(Theme.accent)
                Text(DriveStore.shared.title(of: account)).font(.system(size: 13.5, weight: .semibold))
            }
            VStack(spacing: 6) {
                detail("account", account.email)
                if let usage = DriveStore.shared.usage[account.id] {
                    detail("used", DriveAbout.format(usage.usage))
                    if let limit = usage.limit {
                        detail("free", DriveAbout.format(max(0, limit - usage.usage)))
                        HeatBar(fraction: Double(usage.usage) / Double(max(limit, 1)), height: 4, color: Theme.accent)
                            .padding(.top, 2)
                    }
                }
            }
        }
    }

    @ViewBuilder private func single(_ row: ListRow) -> some View {
        let file = DriveStore.shared.file(at: row.id)
        RemotePreviewCard(url: row.id, size: row.size, version: "\(file?.modified?.timeIntervalSince1970 ?? 0)") {
            model.quickLook([row.id])
        }
        HStack(spacing: 8) {
            TypeChip(item: row.item)
            Text(row.item.name)
                .font(.system(size: 13.5, weight: .semibold))
                .lineLimit(3)
                .textSelection(.enabled)
        }
        VStack(spacing: 6) {
            detail("kind", kind(row, file))
            if let size = row.size { detail("size", Format.bytes(size)) }
            if let date = file?.modified ?? row.date { detail("modified", Format.compactDate(date)) }
            if let date = file?.created { detail("created", Format.compactDate(date)) }
            if let owner = file?.owner { detail("owner", owner) }
        }
        if DriveLocation(url: row.id)?.isVirtual != true {
            buttons([row.id], single: file)
        }
    }

    private func kind(_ row: ListRow, _ file: DriveFile?) -> String {
        if let google = file?.googleKind { return google }
        if file?.isShortcut == true { return row.item.isFolder ? "Shortcut to a folder" : "Shortcut" }
        if row.item.isFolder { return "Folder" }
        return row.item.contentType?.localizedDescription ?? "File"
    }

    /// Two rows, so the buttons fit the inspector's width.
    private func buttons(_ urls: [URL], single file: DriveFile?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button("Download") { Transfers.shared.download(drive: urls, into: URL.downloadsDirectory) }
                    .buttonStyle(SubtleButtonStyle())
                    .help(file?.isGoogleDoc == true ? "Download to your Downloads folder as \(DriveExport.formats(for: file!.contentType).first?.title ?? "a file")" : "Download to your Downloads folder")
                if urls.count == 1 {
                    Button("Open") { model.drive.openInBrowser(urls) }
                        .buttonStyle(SubtleButtonStyle())
                        .help("Open in your browser")
                }
            }
            if urls.count == 1, let url = urls.first {
                HStack(spacing: 6) {
                    Button("Share…") { model.drive.share(url) }
                        .buttonStyle(SubtleButtonStyle())
                        .help("See and change who it's shared with")
                    Button("Copy Link") { model.drive.copyLink(urls) }
                        .buttonStyle(SubtleButtonStyle())
                        .help("Copy the Drive link, which opens it for anyone it's shared with")
                }
            }
        }
        .fixedSize()
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(Theme.textTertiary)
            Spacer(minLength: 10)
            Text(value)
                .font(.system(size: 11.5, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .font(.system(size: 11.5))
    }
}

// MARK: - Status bar

/// How full the account's Drive is, where the disk's free space shows for local folders.
struct DriveUsageIndicator: View {
    let accountID: UUID

    var body: some View {
        if let usage = DriveStore.shared.usage[accountID] {
            Text("Google Drive").foregroundStyle(Theme.textSecondary)
            if let limit = usage.limit {
                HeatBar(fraction: Double(usage.usage) / Double(max(limit, 1)), height: 4, color: Theme.accent)
                    .frame(width: 110)
                Text("\(DriveAbout.format(max(0, limit - usage.usage))) free")
                    .font(Theme.mono)
                    .foregroundStyle(Theme.textSecondary)
            } else {
                Text("\(DriveAbout.format(usage.usage)) used")
                    .font(Theme.mono)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

// MARK: - Settings

/// Google Drive in the Cloud tab of Settings: your OAuth client and the accounts signed in with it.
struct DriveSettings: View {
    private var store: DriveStore { .shared }
    @State private var editingClient = false
    @State private var signIn: Task<Void, Never>?
    @State private var signInError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionCaption(title: "Google Drive")
                Spacer()
                if store.hasClient {
                    Button("Edit Client…") { editingClient = true }.buttonStyle(SubtleButtonStyle())
                    Button(action: startSignIn) {
                        Label("Add Account", systemImage: "plus").font(.system(size: 11.5, weight: .semibold))
                    }
                    .buttonStyle(SubtleButtonStyle())
                    .disabled(signIn != nil)
                }
            }
            VStack(spacing: 0) {
                if !store.hasClient {
                    VStack(spacing: 8) {
                        Text("Not set up yet").font(.system(size: 12.5, weight: .medium))
                        Text("Google Drive works through an OAuth client from your own Google Cloud project, so it talks to Google directly with nothing in between. Setting one up is free and takes about five minutes.")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Set Up Google Client…") { editingClient = true }
                            .buttonStyle(AccentButtonStyle())
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity)
                } else {
                    if signIn != nil {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Waiting for you to sign in to Google in your browser…").font(.system(size: 12))
                            Spacer()
                            Button("Cancel") {
                                signIn?.cancel()
                                signIn = nil
                            }
                            .buttonStyle(SubtleButtonStyle())
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                    }
                    if store.accounts.isEmpty && signIn == nil {
                        VStack(spacing: 6) {
                            Text("No accounts yet").font(.system(size: 12.5, weight: .medium))
                            Text("Add your Google account to browse Drive in the sidebar, drop files on it to upload, and drag them out to download.")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textTertiary)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(20)
                        .frame(maxWidth: .infinity)
                    }
                    ForEach(Array(store.accounts.enumerated()), id: \.element.id) { index, account in
                        if index > 0 || signIn != nil { Rectangle().fill(Theme.border).frame(height: 1).padding(.leading, 12) }
                        HStack(spacing: 10) {
                            Image(systemName: "externaldrive.connected.to.line.below").foregroundStyle(Theme.textSecondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.email).font(.system(size: 12.5, weight: .medium))
                                Text(summary(account)).font(Theme.monoSmall).foregroundStyle(Theme.textTertiary).lineLimit(1)
                            }
                            Spacer()
                            Button { store.remove(account) } label: {
                                Image(systemName: "trash").font(.system(size: 10, weight: .semibold)).frame(width: 16, height: 16)
                            }
                            .buttonStyle(GhostButtonStyle(padding: 2, tint: Theme.textSecondary, destructive: true))
                            .help("Sign out of this account (nothing in Drive is touched)")
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                    }
                }
            }
            .panel(padding: 0)
            if let signInError {
                Label(signInError, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Sign-ins and the client secret are kept in your Keychain. Removing an account signs it out with Google too.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .sheet(isPresented: $editingClient) {
            GoogleClientEditor { editingClient = false }
        }
    }

    private func summary(_ account: DriveAccount) -> String {
        guard let usage = store.usage[account.id] else { return account.name }
        let used = DriveAbout.format(usage.usage)
        let storage = usage.limit.map { "\(used) of \(DriveAbout.format($0)) used" } ?? "\(used) used"
        return [account.name.isEmpty ? nil : account.name, storage].compactMap { $0 }.joined(separator: " · ")
    }

    private func startSignIn() {
        signInError = nil
        signIn = Task {
            do {
                _ = try await store.signIn()
                // Back to TheExplorer from the browser.
                NSApp.activate()
            } catch is CancellationError {
            } catch {
                signInError = error.localizedDescription
            }
            signIn = nil
        }
    }
}

/// Setting up the OAuth client: the steps in Google Cloud Console, then its downloaded JSON
/// (or the ID and secret pasted in).
struct GoogleClientEditor: View {
    let onDone: () -> Void
    @State private var clientID = DriveStore.shared.clientID
    @State private var secret = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("Google OAuth Client").font(.system(size: 14, weight: .semibold))
            Text("In Google Cloud Console, with a project of your own:")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
            VStack(alignment: .leading, spacing: 9) {
                step(1, "Enable the Google Drive API.", link: "Open API Library", "https://console.cloud.google.com/apis/library/drive.googleapis.com")
                step(2, "Under Google Auth Platform → Branding, give the app a name and your email.", link: "Open Branding", "https://console.cloud.google.com/auth/branding")
                step(3, "Under Audience, choose External, then Publish App. (Left in Testing, Google signs you out every 7 days.)", link: "Open Audience", "https://console.cloud.google.com/auth/audience")
                step(4, "Under Clients, create a client of type Desktop app, then download its JSON.", link: "Open Clients", "https://console.cloud.google.com/auth/clients")
            }
            .padding(12)
            .background(Theme.surface, in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))

            HStack {
                Button("Choose Downloaded JSON…", action: chooseJSON).buttonStyle(SubtleButtonStyle())
                Text("or paste the ID and secret:").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
            }
            field("Client ID") {
                TextField("1234567890-abc.apps.googleusercontent.com", text: $clientID).textFieldStyle(.plain).formField()
            }
            field("Client secret", hint: isEditing ? "Leave empty to keep the saved one." : "Saved in your Keychain.") {
                SecureField(isEditing ? "••••••••" : "GOCSPX-…", text: $secret).textFieldStyle(.plain).formField()
            }
            Text("When you sign in, Google says it hasn't verified the app. That's expected for your own client: choose Advanced, then Go to (your app name).")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onDone).buttonStyle(SubtleButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .buttonStyle(AccentButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isComplete)
            }
        }
        .padding(18)
        .frame(width: 500)
        .background(Theme.background)
        .preferredColorScheme(Theme.colorScheme)
    }

    private var isEditing: Bool { DriveStore.shared.hasClient }

    private var isComplete: Bool {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        return !id.isEmpty && (!secret.isEmpty || isEditing)
    }

    private func save() {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.hasSuffix(".apps.googleusercontent.com") else {
            error = "That doesn't look like a Google client ID (they end in .apps.googleusercontent.com)."
            return
        }
        let kept = secret.isEmpty ? DriveStore.shared.googleClient?.secret ?? "" : secret
        DriveStore.shared.setClient(GoogleClient(id: id, secret: kept))
        onDone()
    }

    private func chooseJSON() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.directoryURL = URL.downloadsDirectory
        panel.prompt = "Use Client"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let client = try GoogleClient(json: Data(contentsOf: url))
            clientID = client.id
            secret = client.secret
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func step(_ number: Int, _ text: String, link: String, _ address: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)")
                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(text).font(.system(size: 11.5)).fixedSize(horizontal: false, vertical: true)
                Button(link) { NSWorkspace.shared.open(URL(string: address)!) }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
        }
    }

    private func field(_ title: String, hint: String? = nil, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.textSecondary)
            content()
            if let hint { Text(hint).font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true) }
        }
    }
}
