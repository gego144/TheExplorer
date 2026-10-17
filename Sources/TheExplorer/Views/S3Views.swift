import AppKit
import SwiftUI

// MARK: - Browsing

/// A connection's buckets or a folder in S3, in the same list as local folders. Drop files on
/// it (or on a folder row) to upload; drag rows onto any local folder to download.
struct S3View: View {
    @Bindable var model: BrowserModel
    @Environment(\.openTab) private var openTab
    @State private var naming = false
    @State private var deleting: Set<URL>?

    private var s3: S3Browser { model.s3 }

    var body: some View {
        VStack(spacing: 0) {
            if let error = s3.error {
                Banner(symbol: "exclamationmark.triangle.fill", tint: Theme.danger, text: error,
                       actionTitle: "Retry", action: { s3.reload() }, onDismiss: { s3.dismissError() })
            }
            FileListView(
                rows: rows,
                selection: Binding(get: { s3.selection }, set: { s3.selection = $0 }),
                sort: s3.sort,
                onSort: { s3.sort = s3.sort.toggled(to: $0) },
                dateTitle: s3.location?.bucket == nil ? "Created" : "Modified",
                empty: emptyState,
                onOpen: open,
                onQuickLook: { model.quickLook($0, in: $1) },
                onDropInto: { urls, folder in model.receiveDrop(urls, into: folder) },
                onDropBackground: { urls in s3.location.map { model.receiveDrop(urls, into: $0.url) } ?? false },
                onReachEnd: s3.hasMore ? { s3.loadMore() } : nil,
                footer: s3.hasMore ? AnyView(loadingMore) : nil,
                rowMenu: { S3RowMenu(urls: $0, model: model, deleting: $deleting) },
                backgroundMenu: { S3BackgroundMenu(model: model, naming: $naming) }
            )
        }
        .alert("New Folder", isPresented: $naming) {
            NamePrompt(initialName: "untitled folder", confirmTitle: "Create") { s3.createFolder(named: $0) }
        } message: {
            Text("In “\(s3.location?.uri ?? "")”")
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) {
                if let deleting { s3.delete(deleting) }
                deleting = nil
            }
        } message: {
            Text("This deletes them from S3, including everything inside folders. It can't be undone.")
        }
    }

    /// The listing, filtered by whatever is typed in the command bar.
    private var rows: [ListRow] {
        let filter = model.searchText.trimmingCharacters(in: .whitespaces)
        guard !filter.isEmpty else { return s3.rows }
        return s3.rows.filter { $0.item.name.localizedCaseInsensitiveContains(filter) }
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

    private var deleteTitle: String {
        let count = deleting?.count ?? 0
        return count == 1 ? "Delete “\(deleting?.first.flatMap(S3Location.init(url:))?.itemName ?? "")” from S3?" : "Delete \(count) items from S3?"
    }

    private var emptyState: EmptyState? {
        guard !s3.isLoading, s3.error == nil else { return nil }
        if !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            return EmptyState(symbol: "magnifyingglass", title: "No matches in this folder")
        }
        if s3.location?.bucket == nil {
            return EmptyState(symbol: "cloud", title: "No buckets", hint: "These credentials can't see any buckets. Set a bucket in the connection to open it directly.")
        }
        return EmptyState(symbol: "icloud.and.arrow.up", title: "Nothing here yet", hint: "Drop files or folders here to upload them.")
    }

    private func open(_ urls: Set<URL>, newTab: Bool) {
        let targets = rows.filter { urls.contains($0.id) }
        for row in targets where row.item.isFolder {
            if newTab || targets.count > 1 { openTab(row.id) } else { model.navigate(to: row.id) }
        }
        for row in targets where !row.item.isFolder {
            Transfers.shared.fetchForViewing(row.id) { FileOpener.open([$0]) }
        }
    }
}

private struct S3RowMenu: View {
    let urls: Set<URL>
    let model: BrowserModel
    @Binding var deleting: Set<URL>?
    @Environment(\.openTab) private var openTab

    var body: some View {
        let targets = urls.compactMap(S3Location.init(url:))
        let isBucketList = targets.contains { $0.prefix.isEmpty }
        let single = urls.count == 1 ? urls.first : nil
        let isFile = single.map { !$0.absoluteString.hasSuffix("/") } ?? false
        if let single {
            Button("Open") {
                if isFile { Transfers.shared.fetchForViewing(single) { FileOpener.open([$0]) } } else { model.navigate(to: single) }
            }
            if !isFile { Button("Open in New Tab") { openTab(single) } }
            if isFile { Button("Quick Look") { model.quickLook([single]) } }
            Divider()
        }
        if !isBucketList || targets.allSatisfy({ $0.bucket != nil }) {
            Button("Download to Downloads") { Transfers.shared.download(Array(urls), into: URL.downloadsDirectory) }
            Button("Download To…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.canCreateDirectories = true
                panel.prompt = "Download Here"
                guard panel.runModal() == .OK, let folder = panel.url else { return }
                Transfers.shared.download(Array(urls), into: folder)
            }
            Divider()
        }
        if !isBucketList {
            // Pasted into a local folder, these download.
            Button("Copy") { FileClipboard.shared.copy(urls.sorted { $0.absoluteString < $1.absoluteString }) }
            PasteItems(model: model, folder: isFile ? nil : single)
            Divider()
        }
        Button(urls.count == 1 ? "Copy S3 URI" : "Copy S3 URIs") {
            let uris = targets.map(\.uri).sorted().joined(separator: "\n")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(uris, forType: .string)
        }
        if let single, isFile {
            Button("Copy Share Link (7 Days)") { model.s3.copyShareLink(single) }
        }
        if !isBucketList {
            Divider()
            Button("Delete…", role: .destructive) { deleting = urls }
        }
    }
}

private struct S3BackgroundMenu: View {
    let model: BrowserModel
    @Binding var naming: Bool

    var body: some View {
        if let location = model.s3.location, location.bucket != nil {
            Button("New Folder…") { naming = true }
            Button("Upload Files…") { upload(to: location) }
            let files = FileClipboard.shared.urls.filter(\.isFileURL)
            Button(files.count > 1 ? "Paste \(files.count) Items (Upload)" : "Paste (Upload)") { model.paste() }
                .disabled(files.isEmpty)
            Divider()
            Button("Copy S3 URI") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(location.uri, forType: .string)
            }
        }
        Button("Refresh") { model.s3.reload(keepSelection: true) }
    }

    private func upload(to location: S3Location) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Upload"
        guard panel.runModal() == .OK else { return }
        Transfers.shared.upload(panel.urls, to: location)
    }
}

// MARK: - Command bar

/// "my-account / bucket / videos / 2026": click to go there, drop files to upload into it.
struct S3Breadcrumbs: View {
    let model: BrowserModel

    var body: some View {
        if let location = model.s3.location {
            HStack(spacing: 4) {
                ForEach(Array(trail(location).enumerated()), id: \.element.url) { index, step in
                    if index > 0 { Text("/").foregroundStyle(Theme.textTertiary) }
                    S3Chip(title: step.title, location: step.location, isCurrent: step.location == location, model: model)
                }
            }
            .fixedSize()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private struct Step {
        let title: String
        let location: S3Location
        var url: URL { location.url }
    }

    private func trail(_ location: S3Location) -> [Step] {
        let connection = S3Store.shared.connection(location.connectionID)
        var steps: [Step] = []
        // A connection pinned to one bucket starts at that bucket.
        if connection?.bucket.isEmpty ?? true {
            steps.append(Step(title: connection?.name ?? "S3", location: S3Location(connectionID: location.connectionID, bucket: nil)))
        }
        guard let bucket = location.bucket else { return steps }
        steps.append(Step(title: bucket, location: S3Location(connectionID: location.connectionID, bucket: bucket)))
        var prefix = ""
        for part in location.prefix.split(separator: "/") {
            prefix += part + "/"
            steps.append(Step(title: String(part), location: S3Location(connectionID: location.connectionID, bucket: bucket, prefix: prefix)))
        }
        return steps
    }
}

private struct S3Chip: View {
    let title: String
    let location: S3Location
    let isCurrent: Bool
    let model: BrowserModel
    @State private var targeted = false

    var body: some View {
        Button { model.showS3(location) } label: {
            Text(title)
        }
        .buttonStyle(CrumbStyle(isCurrent: isCurrent, highlighted: targeted))
        .dropDestination(for: URL.self) { urls, _ in model.receiveDrop(urls, into: location.url) } isTargeted: { targeted = $0 }
        .help(location.uri)
    }
}

// MARK: - Inspector

/// Details for selected S3 objects, with download and link buttons.
struct S3Inspector: View {
    let model: BrowserModel

    var body: some View {
        let selected = model.s3.rows.filter { model.s3.selection.contains($0.id) }
        VStack(alignment: .leading, spacing: 12) {
            if selected.count == 1, let row = selected.first, let location = S3Location(url: row.id) {
                HStack(spacing: 8) {
                    TypeChip(item: row.item)
                    Text(row.item.name)
                        .font(.system(size: 13.5, weight: .semibold))
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                VStack(spacing: 6) {
                    if let size = row.size { detail("size", Format.bytes(size)) }
                    if let date = row.date { detail(location.prefix.isEmpty ? "created" : "modified", Format.compactDate(date)) }
                    detail("bucket", location.bucket ?? "")
                }
                Rectangle().fill(Theme.border).frame(height: 1)
                VStack(alignment: .leading, spacing: 6) {
                    SectionCaption(title: "S3 URI")
                    Text(location.uri)
                        .font(Theme.mono)
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("\(selected.count) selected").font(.system(size: 14, weight: .semibold))
                let bytes = selected.compactMap(\.size).reduce(0, +)
                let folders = selected.filter(\.item.isFolder).count
                Text("\(folders) \(folders == 1 ? "folder" : "folders") · \(selected.count - folders) files · \(Format.bytes(bytes))")
                    .font(Theme.mono)
                    .foregroundStyle(Theme.textSecondary)
            }
            HStack(spacing: 6) {
                Button("Download") { Transfers.shared.download(selected.map(\.id), into: URL.downloadsDirectory) }
                    .buttonStyle(SubtleButtonStyle())
                    .help("Download to your Downloads folder")
                if selected.count == 1, let row = selected.first, !row.item.isFolder {
                    Button("Copy Link") { model.s3.copyShareLink(row.id) }
                        .buttonStyle(SubtleButtonStyle())
                        .help("Copy a link anyone can download from for 7 days")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(padding: 14)
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

/// Uploads and downloads in progress (or just finished); click for details.
struct TransferActivity: View {
    private var transfers: Transfers { .shared }
    @State private var showing = false
    @State private var dismissedBefore = Date.distantPast

    var body: some View {
        if let latest = transfers.transfers.first, latest.state == .running || latest.started > dismissedBefore {
            let running = transfers.transfers.filter { $0.state == .running }
            let shown = running.first ?? latest
            Button { showing.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: shown.kind == .upload ? "arrow.up.circle" : "arrow.down.circle")
                        .font(.system(size: 10, weight: .semibold))
                    if shown.state == .running {
                        HeatBar(fraction: shown.fraction, height: 3, color: Theme.accent).frame(width: 46)
                        Text("\(Int(shown.fraction * 100))%").font(Theme.monoSmall)
                    }
                    Text(label(shown, others: running.count - 1)).lineLimit(1).truncationMode(.middle)
                }
                .foregroundStyle(isFailure(shown) ? Theme.danger : (shown.state == .running ? Theme.text : Theme.textSecondary))
            }
            .buttonStyle(PillButtonStyle())
            .frame(maxWidth: 360)
            .help("Show transfers")
            .popover(isPresented: $showing, arrowEdge: .top) {
                TransfersView(onClear: { dismissedBefore = Date() })
            }
            .task(id: latest.state) {
                guard latest.state == .done else { return }
                try? await Task.sleep(for: .seconds(8))
                if !showing { dismissedBefore = Date() }
            }
        }
    }

    private func label(_ transfer: Transfers.Transfer, others: Int) -> String {
        let more = others > 0 ? " +\(others)" : ""
        let verb = transfer.kind == .upload ? "Uploading" : "Downloading"
        switch transfer.state {
        case .running: return "\(verb) \(transfer.title)\(more)"
        case .done: return (transfer.kind == .upload ? "Uploaded " : "Downloaded ") + transfer.title
        case .cancelled: return "Stopped " + transfer.title
        case .failed: return (transfer.kind == .upload ? "Upload" : "Download") + " failed: " + transfer.title
        }
    }

    private func isFailure(_ transfer: Transfers.Transfer) -> Bool {
        if case .failed = transfer.state { return true }
        return false
    }
}

struct TransfersView: View {
    let onClear: () -> Void
    private var transfers: Transfers { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionCaption(title: "Transfers")
                Spacer()
                if transfers.transfers.contains(where: { $0.state != .running }) {
                    Button("Clear") {
                        transfers.clearFinished()
                        onClear()
                    }
                    .buttonStyle(SubtleButtonStyle())
                }
            }
            ForEach(transfers.transfers.prefix(8)) { transfer in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Image(systemName: transfer.kind == .upload ? "arrow.up" : "arrow.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.textSecondary)
                        Text(transfer.title).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if transfer.state == .running {
                            Button("Stop") { transfers.cancel(transfer.id) }.buttonStyle(SubtleButtonStyle())
                        }
                    }
                    HeatBar(fraction: transfer.state == .done ? 1 : transfer.fraction, height: 4, color: Theme.accent)
                    Text(status(transfer))
                        .font(Theme.monoSmall)
                        .foregroundStyle(statusColor(transfer))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background(Theme.surface, in: .rect(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
            }
        }
        .padding(12)
        .frame(width: 400)
        .background(Theme.background)
        .preferredColorScheme(Theme.colorScheme)
    }

    private func status(_ transfer: Transfers.Transfer) -> String {
        let bytes = "\(Format.bytes(transfer.doneBytes)) of \(Format.bytes(transfer.totalBytes))"
        let items = transfer.totalItems > 1 ? " · \(transfer.doneItems) of \(transfer.totalItems) files" : ""
        switch transfer.state {
        case .running: return bytes + items + (transfer.current.map { " · \($0)" } ?? "")
        case .done: return "Done · " + Format.bytes(transfer.totalBytes) + items
        case .cancelled: return "Stopped · " + bytes + items
        case .failed(let message): return message
        }
    }

    private func statusColor(_ transfer: Transfers.Transfer) -> Color {
        if case .failed = transfer.state { return Theme.danger }
        return Theme.textTertiary
    }
}

// MARK: - Settings

/// The Cloud tab in Settings: your S3 connections, then Google Drive.
struct CloudSettings: View {
    private var store: S3Store { .shared }
    @State private var editing: ConnectionDraft?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionCaption(title: "S3 connections")
                Spacer()
                ChromeMenu(style: .button) {
                    let profiles = AWSProfiles.names()
                    if !profiles.isEmpty {
                        Section("AWS profiles") {
                            ForEach(profiles, id: \.self) { profile in
                                Button("Profile “\(profile)”") { editing = .profile(profile) }
                            }
                        }
                    }
                    Button("AWS Access Keys…") { editing = .keys() }
                    Button("S3-Compatible Service…") { editing = .compatible() }
                } label: {
                    Label("Add Connection", systemImage: "plus")
                        .font(.system(size: 11.5, weight: .semibold))
                }
            }
            VStack(spacing: 0) {
                if store.connections.isEmpty {
                    VStack(spacing: 6) {
                        Text("No connections yet").font(.system(size: 12.5, weight: .medium))
                        Text("Connect S3 to browse your buckets in the sidebar, drop files on them to upload, and drag them out to download. Your AWS CLI profiles work as they are.")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity)
                } else {
                    ForEach(Array(store.connections.enumerated()), id: \.element.id) { index, connection in
                        if index > 0 { Rectangle().fill(Theme.border).frame(height: 1).padding(.leading, 12) }
                        HStack(spacing: 10) {
                            Image(systemName: "cloud").foregroundStyle(Theme.textSecondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(connection.name).font(.system(size: 12.5, weight: .medium))
                                Text(connection.summary).font(Theme.monoSmall).foregroundStyle(Theme.textTertiary).lineLimit(1)
                            }
                            Spacer()
                            Button { store.remove(connection) } label: {
                                Image(systemName: "trash").font(.system(size: 10, weight: .semibold)).frame(width: 16, height: 16)
                            }
                            .buttonStyle(GhostButtonStyle(padding: 2, tint: Theme.textSecondary, destructive: true))
                            .help("Remove this connection (nothing in S3 is touched)")
                            Button("Edit") { editing = ConnectionDraft(connection) }.buttonStyle(SubtleButtonStyle())
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                    }
                }
            }
            .panel(padding: 0)
            Text("Profiles read ~/.aws like the AWS CLI does (SSO and roles work through the CLI). Access keys are kept in your Keychain.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .sheet(item: $editing) { draft in
            ConnectionEditor(draft: draft) { editing = nil }
        }
        DriveSettings()
            .padding(.top, 10)
    }
}

/// A connection being added or edited, with the secret kept out of the saved list.
struct ConnectionDraft: Identifiable {
    var connection: S3Connection
    var usesProfile: Bool
    var profile: String
    var accessKeyID: String
    var secret = ""
    var isNew: Bool

    var id: UUID { connection.id }

    init(_ connection: S3Connection, isNew: Bool = false) {
        self.connection = connection
        self.isNew = isNew
        switch connection.auth {
        case .profile(let name):
            usesProfile = true
            profile = name
            accessKeyID = ""
        case .keys(let key):
            usesProfile = false
            profile = AWSProfiles.names().first ?? "default"
            accessKeyID = key
        }
    }

    static func profile(_ name: String) -> ConnectionDraft {
        let connection = S3Connection(name: name == "default" ? "AWS" : "AWS (\(name))", auth: .profile(name),
                                      region: AWSProfiles.region(for: name) ?? "us-east-1",
                                      endpoint: AWSProfiles.endpoint(for: name) ?? "")
        return ConnectionDraft(connection, isNew: true)
    }

    static func keys() -> ConnectionDraft {
        ConnectionDraft(S3Connection(name: "AWS", auth: .keys(accessKeyID: ""), region: "us-east-1"), isNew: true)
    }

    static func compatible() -> ConnectionDraft {
        ConnectionDraft(S3Connection(name: "Storage", auth: .keys(accessKeyID: ""), region: "auto", endpoint: "https://"), isNew: true)
    }

    var built: S3Connection {
        var connection = self.connection
        connection.auth = usesProfile ? .profile(profile) : .keys(accessKeyID: accessKeyID.trimmingCharacters(in: .whitespaces))
        connection.name = connection.name.trimmingCharacters(in: .whitespaces)
        connection.region = connection.region.trimmingCharacters(in: .whitespaces)
        connection.endpoint = connection.endpoint.trimmingCharacters(in: .whitespaces) == "https://" ? "" : connection.endpoint.trimmingCharacters(in: .whitespaces)
        connection.bucket = connection.bucket.trimmingCharacters(in: CharacterSet(charactersIn: " /"))
        return connection
    }
}

struct ConnectionEditor: View {
    @State var draft: ConnectionDraft
    let onDone: () -> Void
    @State private var testResult: (ok: Bool, text: String)?
    @State private var testing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(draft.isNew ? "New S3 Connection" : "Edit Connection").font(.system(size: 14, weight: .semibold))

            field("Name") { TextField("AWS", text: $draft.connection.name).textFieldStyle(.plain).formField() }

            field("Sign in with") {
                Segmented(selection: $draft.usesProfile, options: [(true, "AWS Profile"), (false, "Access Keys")]).fixedSize()
            }
            if draft.usesProfile {
                field("Profile", hint: "From ~/.aws/config and ~/.aws/credentials.") {
                    ChromeMenu(draft.profile) {
                        ForEach(Array(Set(AWSProfiles.names() + [draft.profile])).sorted(), id: \.self) { profile in
                            Button(profile) { draft.profile = profile }
                        }
                    }
                }
            } else {
                field("Access key ID") {
                    TextField("AKIA…", text: $draft.accessKeyID).textFieldStyle(.plain).formField()
                }
                field("Secret access key", hint: draft.isNew ? "Saved in your Keychain." : "Leave empty to keep the saved one.") {
                    SecureField(draft.isNew ? "" : "••••••••", text: $draft.secret).textFieldStyle(.plain).formField()
                }
            }
            HStack(spacing: 10) {
                field("Region") { TextField("us-east-1", text: $draft.connection.region).textFieldStyle(.plain).formField() }
                field("Bucket (optional)") { TextField("open straight into it", text: $draft.connection.bucket).textFieldStyle(.plain).formField() }
            }
            field("Endpoint (optional)", hint: "For S3-compatible services: Cloudflare R2, MinIO, Backblaze B2, Wasabi… Leave empty for AWS.") {
                TextField("https://<account>.r2.cloudflarestorage.com", text: $draft.connection.endpoint).textFieldStyle(.plain).formField()
            }

            if let testResult {
                Label(testResult.text, systemImage: testResult.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(testResult.ok ? Theme.text : Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button(testing ? "Testing…" : "Test Connection", action: test)
                    .buttonStyle(SubtleButtonStyle())
                    .disabled(testing || !isComplete)
                Spacer()
                Button("Cancel", action: onDone).buttonStyle(SubtleButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Save") {
                    S3Store.shared.save(draft.built, secret: draft.usesProfile ? nil : draft.secret)
                    onDone()
                }
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

    private var isComplete: Bool {
        let built = draft.built
        guard !built.name.isEmpty else { return false }
        if draft.usesProfile { return !draft.profile.isEmpty }
        return !draft.accessKeyID.trimmingCharacters(in: .whitespaces).isEmpty
            && (!draft.secret.isEmpty || (!draft.isNew && Keychain.get(account: built.id.uuidString) != nil))
    }

    /// Lists buckets (or the chosen bucket) with what's in the form, without saving anything.
    private func test() {
        let connection = draft.built
        let secret = draft.secret.isEmpty ? Keychain.get(account: connection.id.uuidString) : draft.secret
        testing = true
        testResult = nil
        Task {
            let client = S3Client(config: connection.config) {
                if case .keys(let key) = connection.auth { return S3Credentials(accessKeyID: key, secretAccessKey: secret ?? "") }
                return try await S3Store.credentials(for: connection)
            }
            do {
                if connection.bucket.isEmpty {
                    let buckets = try await client.listBuckets()
                    testResult = (true, "Connected. \(buckets.count) \(buckets.count == 1 ? "bucket" : "buckets") found.")
                } else {
                    let listing = try await client.list(bucket: connection.bucket, prefix: "")
                    testResult = (true, "Connected to \(connection.bucket). \(listing.prefixes.count + listing.objects.count) items at the top.")
                }
            } catch {
                testResult = (false, error.localizedDescription)
            }
            testing = false
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

