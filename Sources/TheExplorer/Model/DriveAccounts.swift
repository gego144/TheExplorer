import Foundation
import Observation

/// A Google account you've signed in to. Its sign-in (a refresh token) is in the Keychain.
struct DriveAccount: Codable, Identifiable, Hashable {
    var id = UUID()
    var email: String
    var name: String

    var home: DriveLocation { DriveLocation(accountID: id, id: DriveLocation.homeID, name: email) }
    var myDrive: DriveLocation { DriveLocation(accountID: id, id: DriveLocation.myDriveID, name: "My Drive") }
}

/// A file or folder in Drive, by its ID. The name rides along in the URL so rows, drags and
/// history can show it without asking Drive. A few IDs are TheExplorer's own lists rather
/// than folders: the account's top level, Shared with me, Starred and Shared drives.
struct DriveLocation: Hashable, Sendable {
    var accountID: UUID
    var id: String
    var name: String
    var isFolder = true

    static let scheme = "x-gdrive"
    static let homeID = "~"
    /// Drive's own alias for the top of My Drive.
    static let myDriveID = "root"
    static let sharedID = "~shared"
    static let starredID = "~starred"
    static let drivesID = "~drives"

    /// TheExplorer's lists (not real folders): nothing can be put in them.
    var isVirtual: Bool { id.hasPrefix("~") }

    /// x-gdrive://<account>/<id>/<name>, with a trailing slash for folders.
    var url: URL { Self.url(accountID: accountID, id: id, name: name, isFolder: isFolder) }

    static func url(accountID: UUID, id: String, name: String, isFolder: Bool) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = accountID.uuidString.lowercased()
        components.percentEncodedPath = "/" + DriveClient.encode(id) + "/" + DriveClient.encode(name) + (isFolder ? "/" : "")
        return components.url!
    }

    init(accountID: UUID, id: String, name: String, isFolder: Bool = true) {
        self.accountID = accountID
        self.id = id
        self.name = name
        self.isFolder = isFolder
    }

    init?(url: URL) {
        guard url.scheme == Self.scheme, let host = url.host, let account = UUID(uuidString: host) else { return nil }
        let parts = url.path(percentEncoded: true).split(separator: "/", omittingEmptySubsequences: true)
        guard let id = parts.first?.removingPercentEncoding else { return nil }
        accountID = account
        self.id = id
        name = parts.count > 1 ? parts[1].removingPercentEncoding ?? "" : ""
        isFolder = url.absoluteString.hasSuffix("/")
    }
}

/// Your Google client and accounts, saved to Application Support (the client secret and each
/// account's sign-in go to the Keychain), with one Drive client per account. Also remembers
/// what's been listed: each item's details and the folder it was found in, which is what the
/// breadcrumbs and Enclosing Folder walk up through.
@MainActor
@Observable
final class DriveStore {
    static let shared = DriveStore()
    nonisolated static let keychainService = "TheExplorer Google Drive"
    nonisolated private static let clientSecretAccount = "client-secret"

    private struct Saved: Codable {
        var clientID = ""
        var accounts: [DriveAccount] = []
        var usage: [String: DriveAbout]? = [:]
        var drives: [String: [SharedDrive]]? = [:]

        init(clientID: String, accounts: [DriveAccount], usage: [String: DriveAbout], drives: [String: [SharedDrive]]) {
            self.clientID = clientID
            self.accounts = accounts
            self.usage = usage
            self.drives = drives
        }

        /// Storage figures are only a cache: if they can't be read, the accounts still load.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            clientID = try container.decodeIfPresent(String.self, forKey: .clientID) ?? ""
            accounts = try container.decodeIfPresent([DriveAccount].self, forKey: .accounts) ?? []
            usage = (try? container.decodeIfPresent([String: DriveAbout].self, forKey: .usage)) ?? [:]
            drives = (try? container.decodeIfPresent([String: [SharedDrive]].self, forKey: .drives)) ?? [:]
        }
    }

    /// The OAuth client's ID; empty until you set one up.
    private(set) var clientID = ""
    private(set) var accounts: [DriveAccount] = []
    /// Each account's name and storage, refreshed whenever it's opened.
    private(set) var usage: [UUID: DriveAbout] = [:]
    /// Each account's shared drives, by name, for the sidebar. Saved, so they show at launch,
    /// and refreshed from Drive.
    private(set) var sharedDrives: [UUID: [SharedDrive]] = [:]

    @ObservationIgnored private var clients: [UUID: DriveClient] = [:]
    @ObservationIgnored private var files: [String: DriveFile] = [:]
    @ObservationIgnored private var parents: [String: DriveLocation] = [:]
    @ObservationIgnored private var rootIDs: [UUID: String] = [:]
    @ObservationIgnored private let fileURL: URL

    init() {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["EXPLORER_DRIVE_FILE"] {
            fileURL = URL(fileURLWithPath: path)
            load()
            return
        }
        #endif
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TheExplorer", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        fileURL = support.appendingPathComponent("drive.json")
        load()
    }

    // MARK: Client and accounts

    var googleClient: GoogleClient? {
        guard !clientID.isEmpty, let secret = Self.secret(Self.clientSecretAccount) else { return nil }
        return GoogleClient(id: clientID, secret: secret)
    }

    func setClient(_ client: GoogleClient) {
        clientID = client.id
        Self.setSecret(client.secret, Self.clientSecretAccount)
        clients = [:]
        persist()
    }

    func account(_ id: UUID) -> DriveAccount? { accounts.first { $0.id == id } }

    /// What the sidebar calls an account: "Google Drive", or its address when there are several.
    func title(of account: DriveAccount) -> String {
        accounts.count == 1 ? "Google Drive" : account.email
    }

    /// Whether an OAuth client is set up. Known without reading the Keychain, so views can ask.
    var hasClient: Bool { !clientID.isEmpty }

    /// The account's client. Its secrets are read from the Keychain on first use, off the main
    /// thread; a missing one fails that first request.
    func client(for id: UUID) -> DriveClient? {
        if let client = clients[id] { return client }
        guard account(id) != nil, hasClient else { return nil }
        let clientID = clientID
        let client = DriveClient(auth: GoogleAuth {
            guard let secret = Self.secret(Self.clientSecretAccount) else {
                throw DriveError(message: "Google Drive's client secret isn't in the Keychain. Set up the client again in Settings → Cloud.")
            }
            guard let refresh = Self.secret(id.uuidString) else {
                throw DriveError(message: "This Google account isn't signed in. Sign in again in Settings → Cloud.")
            }
            return (GoogleClient(id: clientID, secret: secret), refresh)
        })
        clients[id] = client
        return client
    }

    /// Signs in through the browser and adds the account (or, for one already here, renews its
    /// sign-in).
    func signIn() async throws -> DriveAccount {
        guard let google = googleClient else { throw DriveError(message: "Set up your Google OAuth client first.") }
        let tokens = try await GoogleOAuth.signIn(client: google)
        guard let refresh = tokens.refreshToken else {
            throw DriveError(message: "Google didn't hand back a lasting sign-in. Remove TheExplorer's access at myaccount.google.com/permissions, then sign in again.")
        }
        let client = DriveClient(auth: GoogleAuth(client: google, refreshToken: refresh))
        let about = try await client.about()
        var account = accounts.first { $0.email.caseInsensitiveCompare(about.email) == .orderedSame }
            ?? DriveAccount(email: about.email, name: about.name)
        account.name = about.name
        Self.setSecret(refresh, account.id.uuidString)
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index] = account
        } else {
            accounts.append(account)
        }
        clients[account.id] = client
        usage[account.id] = about
        persist()
        return account
    }

    /// Signs out: Google forgets the sign-in, and nothing in Drive is touched.
    func remove(_ account: DriveAccount) {
        let keychainAccount = account.id.uuidString
        Task.detached {
            if let refresh = Self.secret(keychainAccount) { await GoogleOAuth.revoke(refresh) }
            Keychain.delete(account: keychainAccount, service: Self.keychainService)
        }
        accounts.removeAll { $0.id == account.id }
        clients[account.id] = nil
        usage[account.id] = nil
        sharedDrives[account.id] = nil
        persist()
    }

    /// Why an account's shared drives couldn't be listed, if they couldn't.
    private(set) var sharedDrivesError: [UUID: String] = [:]

    /// Accounts whose places (Shared with me, Starred, shared drives) are folded away in the sidebar.
    var collapsed: Set<UUID> = Set((UserDefaults.standard.stringArray(forKey: "collapsedDriveAccounts") ?? []).compactMap(UUID.init)) {
        didSet { UserDefaults.standard.set(collapsed.map(\.uuidString), forKey: "collapsedDriveAccounts") }
    }

    func refreshSharedDrives(_ accountID: UUID) {
        guard let client = client(for: accountID) else { return }
        Task {
            do {
                setSharedDrives(try await client.allDrives(), for: accountID)
                sharedDrivesError[accountID] = nil
            } catch {
                sharedDrivesError[accountID] = error.localizedDescription
            }
        }
    }

    func setSharedDrives(_ drives: [SharedDrive], for accountID: UUID) {
        let sorted = drives.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        for drive in sorted {
            parents[key(accountID, drive.id)] = DriveLocation(accountID: accountID, id: DriveLocation.drivesID, name: "Shared drives")
        }
        guard sharedDrives[accountID] != sorted else { return }
        sharedDrives[accountID] = sorted
        persist()
    }

    func refreshUsage(_ accountID: UUID) {
        guard let client = client(for: accountID) else { return }
        Task {
            guard let about = try? await client.about() else { return }
            if usage[accountID] != about {
                usage[accountID] = about
                persist()
            }
        }
    }

    // MARK: What's been listed

    private func key(_ accountID: UUID, _ id: String) -> String { accountID.uuidString + "|" + id }

    func file(_ location: DriveLocation) -> DriveFile? { files[key(location.accountID, location.id)] }

    func file(at url: URL) -> DriveFile? { DriveLocation(url: url).flatMap(file) }

    /// An item's details: as listed, or asked of Drive when it hasn't been.
    func details(_ location: DriveLocation) async throws -> DriveFile {
        if let known = file(location) { return known }
        guard let client = client(for: location.accountID) else { throw DriveError(message: "This Google account was removed.") }
        let fetched = try await client.file(location.id)
        files[key(location.accountID, fetched.id)] = fetched
        return fetched
    }

    /// Notes items listed in `folder`, so their details and where they were are known later.
    func remember(_ items: [DriveFile], in folder: DriveLocation?, accountID: UUID) {
        // What's at the top of My Drive names its real ID as the parent.
        if folder?.id == DriveLocation.myDriveID, let root = items.first?.parents.first { rootIDs[accountID] = root }
        for item in items {
            files[key(accountID, item.id)] = item
            if let folder { parents[key(accountID, item.isShortcut ? item.contentID : item.id)] = folder }
        }
    }

    func remember(parent: DriveLocation, of location: DriveLocation) {
        parents[key(location.accountID, location.id)] = parent
    }

    /// Whether two locations are the same folder, taking "root" as the top of My Drive.
    func isSameFolder(_ a: DriveLocation, _ b: DriveLocation) -> Bool {
        guard a.accountID == b.accountID else { return false }
        let root = rootIDs[a.accountID]
        let normal = { (id: String) in id == root ? DriveLocation.myDriveID : id }
        return normal(a.id) == normal(b.id)
    }

    /// The folder (or list) a location was found in, if it's known.
    func knownParent(of location: DriveLocation) -> DriveLocation? {
        switch location.id {
        case DriveLocation.homeID: return nil
        case DriveLocation.myDriveID, DriveLocation.sharedID, DriveLocation.starredID, DriveLocation.drivesID:
            return account(location.accountID)?.home
        default: return parents[key(location.accountID, location.id)]
        }
    }

    /// The folder a location is in, asking Drive when it isn't known: for search results, and
    /// shortcuts or folders opened from elsewhere.
    func parent(of location: DriveLocation) async -> DriveLocation? {
        if location.id == DriveLocation.homeID { return nil }
        if let known = knownParent(of: location) { return known }
        guard let client = client(for: location.accountID), let home = account(location.accountID)?.home else { return nil }
        let accountID = location.accountID
        let shared = DriveLocation(accountID: accountID, id: DriveLocation.sharedID, name: "Shared with me")
        let drives = DriveLocation(accountID: accountID, id: DriveLocation.drivesID, name: "Shared drives")
        do {
            let item = try await client.file(location.id)
            files[key(accountID, item.id)] = item
            let rootID = try await myDriveRootID(accountID, client: client)
            let parent: DriveLocation
            if item.id == rootID {
                parent = home
            } else if let driveID = item.driveID, item.id == driveID {
                parent = drives
            } else if let parentID = item.parents.first {
                if parentID == rootID {
                    parent = DriveLocation(accountID: accountID, id: DriveLocation.myDriveID, name: "My Drive")
                } else if parentID == item.driveID {
                    // The top of a shared drive, under its own name.
                    let name = (try? await client.sharedDrive(parentID).name) ?? "Shared drive"
                    parent = DriveLocation(accountID: accountID, id: parentID, name: name)
                    parents[key(accountID, parentID)] = drives
                } else if let folder = try? await client.file(parentID) {
                    files[key(accountID, folder.id)] = folder
                    parent = DriveLocation(accountID: accountID, id: folder.id, name: folder.name)
                } else {
                    // In a folder you can't see: it was shared with you on its own.
                    parent = shared
                }
            } else {
                parent = shared
            }
            parents[key(accountID, location.id)] = parent
            return parent
        } catch {
            return nil
        }
    }

    /// The real ID behind "root", for recognising the top of My Drive when walking up.
    private func myDriveRootID(_ accountID: UUID, client: DriveClient) async throws -> String {
        if let id = rootIDs[accountID] { return id }
        let id = try await client.file(DriveLocation.myDriveID).id
        rootIDs[accountID] = id
        return id
    }

    // MARK: Saving

    nonisolated private static func secret(_ account: String) -> String? {
        #if DEBUG
        // Test runs bring their own sign-in rather than touching the Keychain.
        if let token = ProcessInfo.processInfo.environment["EXPLORER_DRIVE_TOKEN"] {
            return account == clientSecretAccount ? "test-secret" : token
        }
        #endif
        return Keychain.get(account: account, service: keychainService)
    }

    private static func setSecret(_ secret: String, _ account: String) {
        #if DEBUG
        if ProcessInfo.processInfo.environment["EXPLORER_DRIVE_TOKEN"] != nil { return }
        #endif
        Keychain.set(secret, account: account, service: keychainService)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        clientID = saved.clientID
        accounts = saved.accounts
        usage = Dictionary(uniqueKeysWithValues: (saved.usage ?? [:]).compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
        sharedDrives = Dictionary(uniqueKeysWithValues: (saved.drives ?? [:]).compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let saved = Saved(clientID: clientID, accounts: accounts,
                          usage: Dictionary(uniqueKeysWithValues: usage.map { ($0.key.uuidString, $0.value) }),
                          drives: Dictionary(uniqueKeysWithValues: sharedDrives.map { ($0.key.uuidString, $0.value) }))
        guard let data = try? encoder.encode(saved) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
