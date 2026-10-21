import Foundation
import Observation

/// Who a Drive file is shared with, for the Share sheet: people and groups with their roles,
/// and the file's general access (just those people, anyone with the link, or everyone in your
/// organization). Every change goes to Google first; the list is then read back from Drive, so
/// what it shows is what Drive has.
@MainActor
@Observable
final class DriveSharing: Identifiable {
    /// Who can open the file besides the people it's shared with.
    enum Access: Hashable {
        case restricted
        case anyone(DrivePermission.Role)
        case domain(String, DrivePermission.Role)

        var role: DrivePermission.Role? {
            switch self {
            case .restricted: nil
            case .anyone(let role), .domain(_, let role): role
            }
        }
    }

    let location: DriveLocation
    /// The file whose sharing this is: a shortcut's target, since that's what's shared.
    let fileID: String
    private(set) var file: DriveFile?
    private(set) var permissions: [DrivePermission] = []
    private(set) var isLoading = true
    /// What's being changed: a permission's ID, "add" or "access".
    private(set) var busy: Set<String> = []
    var error: String?

    init(_ location: DriveLocation) {
        self.location = location
        let file = DriveStore.shared.file(location)
        fileID = file?.contentID ?? location.id
        self.file = file?.isShortcut == true ? nil : file
    }

    var name: String { file?.name ?? location.name }
    var canShare: Bool { file?.canShare ?? false }
    /// The signed-in account's address, to mark "you" in the list.
    var accountEmail: String? { DriveStore.shared.account(location.accountID)?.email }

    /// Your organization, for "Anyone at …": the domain of a Google Workspace address. Personal
    /// Google accounts don't have one.
    var organization: String? {
        guard let email = accountEmail, let at = email.lastIndex(of: "@") else { return nil }
        let domain = String(email[email.index(after: at)...]).lowercased()
        return ["gmail.com", "googlemail.com"].contains(domain) ? nil : domain
    }

    /// People and groups: the owner first, then you, then everyone else by name.
    var people: [DrivePermission] {
        let you = accountEmail?.lowercased()
        return permissions.filter { $0.kind == .user || $0.kind == .group }.sorted { a, b in
            func rank(_ p: DrivePermission) -> Int { p.role == .owner ? 0 : p.email?.lowercased() == you ? 1 : 2 }
            return rank(a) != rank(b) ? rank(a) < rank(b) : a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }

    private var linkPermission: DrivePermission? { permissions.first { $0.kind == .anyone } }
    private var domainPermission: DrivePermission? { permissions.first { $0.kind == .domain } }

    var access: Access {
        if let link = linkPermission { return .anyone(link.role) }
        if let domain = domainPermission { return .domain(domain.domain ?? organization ?? "", domain.role) }
        return .restricted
    }

    /// When general access comes from the shared drive or a folder above, so it isn't changed here.
    var accessIsInherited: Bool {
        (linkPermission ?? domainPermission)?.inherited ?? false
    }

    func isYou(_ permission: DrivePermission) -> Bool {
        guard let email = permission.email, let you = accountEmail else { return false }
        return email.caseInsensitiveCompare(you) == .orderedSame
    }

    // MARK: Changes

    func load() async {
        guard let client else { return }
        do {
            async let file = client.file(fileID)
            async let permissions = client.permissions(of: fileID)
            let (loaded, list) = try await (file, permissions)
            self.file = loaded
            self.permissions = list
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    /// Shares with each address. Returns whether all of them worked, so the field can clear.
    func add(_ emails: [String], role: DrivePermission.Role, notify: Bool, message: String) async -> Bool {
        guard let client, !emails.isEmpty else { return false }
        busy.insert("add")
        defer { busy.remove("add") }
        error = nil
        var failed: [String] = []
        for email in emails {
            do {
                _ = try await client.share(fileID, kind: .user, role: role, email: email, notify: notify, message: message)
            } catch {
                failed.append(email)
                self.error = emails.count > 1 ? "\(email): \(error.localizedDescription)" : error.localizedDescription
            }
        }
        await refresh()
        return failed.isEmpty
    }

    func setRole(_ role: DrivePermission.Role, for permission: DrivePermission) async {
        guard role != permission.role else { return }
        await change(permission.id) { client in
            _ = try await client.setRole(role, of: permission.id, on: self.fileID)
        }
    }

    func remove(_ permission: DrivePermission) async {
        await change(permission.id) { client in
            try await client.unshare(permission.id, on: self.fileID)
        }
    }

    /// Sets who else can open it. Like Drive, there's one general access at a time, so moving
    /// from "anyone with the link" to your organization (or back) replaces the other.
    func setAccess(_ new: Access) async {
        guard new != access else { return }
        let link = linkPermission
        let domain = domainPermission
        let fileID = fileID
        await change("access") { client in
            switch new {
            case .restricted:
                for permission in [link, domain].compactMap({ $0 }) { try await client.unshare(permission.id, on: fileID) }
            case .anyone(let role):
                if let link {
                    if link.role != role { _ = try await client.setRole(role, of: link.id, on: fileID) }
                } else {
                    _ = try await client.share(fileID, kind: .anyone, role: role)
                }
                if let domain { try await client.unshare(domain.id, on: fileID) }
            case .domain(let name, let role):
                if let domain, domain.domain?.caseInsensitiveCompare(name) == .orderedSame {
                    if domain.role != role { _ = try await client.setRole(role, of: domain.id, on: fileID) }
                } else {
                    _ = try await client.share(fileID, kind: .domain, role: role, domain: name)
                    if let domain { try await client.unshare(domain.id, on: fileID) }
                }
                if let link { try await client.unshare(link.id, on: fileID) }
            }
        }
    }

    private var client: DriveClient? { DriveStore.shared.client(for: location.accountID) }

    private func change(_ key: String, _ work: @escaping (DriveClient) async throws -> Void) async {
        guard let client else { return }
        busy.insert(key)
        defer { busy.remove(key) }
        error = nil
        do {
            try await work(client)
        } catch {
            self.error = error.localizedDescription
        }
        await refresh()
    }

    private func refresh() async {
        guard let client, let list = try? await client.permissions(of: fileID) else { return }
        permissions = list
    }
}
