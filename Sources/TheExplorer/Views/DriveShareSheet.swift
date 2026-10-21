import AppKit
import SwiftUI

/// Share… for a Drive file or folder: add people by address, change what each person can do
/// or take their access away, and choose who else can open it (only those people, anyone with
/// the link, or everyone in your organization). Like Drive's own Share dialog, minus making
/// someone else the owner, which Google confirms by email and stays in Drive.
struct DriveShareSheet: View {
    @Bindable var sharing: DriveSharing
    let onDone: () -> Void

    @State private var addresses = ""
    @State private var role = DrivePermission.Role.reader
    @State private var notify = true
    @State private var message = ""
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Share “\(sharing.name)”")
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(2)

            if sharing.isLoading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading who has access…").foregroundStyle(Theme.textTertiary)
                }
                .font(.system(size: 11.5))
                .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                if !sharing.canShare {
                    Label("You can see who has access, but only people who can share this can change it.", systemImage: "lock.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                addPeople
                people
                generalAccess
            }

            if let error = sharing.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            HStack {
                if let link = sharing.file?.webLink {
                    Button("Copy Link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(link, forType: .string)
                    }
                    .buttonStyle(SubtleButtonStyle())
                    .help("Copy the Drive link, which opens it for anyone it's shared with")
                }
                Spacer()
                Button("Done", action: onDone)
                    .buttonStyle(AccentButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 520)
        .background(Theme.background)
        .preferredColorScheme(Theme.colorScheme)
        .task { await sharing.load() }
    }

    // MARK: Adding people

    @ViewBuilder private var addPeople: some View {
        if sharing.canShare {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    TextField("Add people by email", text: $addresses)
                        .textFieldStyle(.plain)
                        .formField()
                        .focused($addressFocused)
                        .onSubmit(add)
                    rolePicker(selection: $role)
                    Button("Share", action: add)
                        .buttonStyle(AccentButtonStyle())
                        .disabled(emails.isEmpty || sharing.busy.contains("add"))
                }
                if !emails.isEmpty {
                    Toggle(isOn: $notify) {
                        Text("Email \(emails.count == 1 ? "them" : "everyone") to say it's shared").font(.system(size: 11.5))
                    }
                    .toggleStyle(.checkbox)
                    if notify {
                        TextField("Message (optional)", text: $message, axis: .vertical)
                            .textFieldStyle(.plain)
                            .lineLimit(1...4)
                            .formField()
                    }
                }
                if sharing.busy.contains("add") {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Sharing…")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }

    /// The addresses typed so far, however they're separated.
    private var emails: [String] {
        addresses.split(whereSeparator: { ",; \n\t".contains($0) })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "<>")) }
            .filter { $0.contains("@") && $0.contains(".") }
    }

    private func add() {
        let emails = emails
        guard !emails.isEmpty else { return }
        Task {
            if await sharing.add(emails, role: role, notify: notify, message: message) {
                addresses = ""
                message = ""
            }
        }
    }

    // MARK: People

    private var people: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionCaption(title: "People with access")
            VStack(spacing: 0) {
                ForEach(sharing.people) { person in
                    PersonRow(sharing: sharing, person: person)
                    if person.id != sharing.people.last?.id {
                        Rectangle().fill(Theme.border).frame(height: 1).padding(.leading, 44)
                    }
                }
            }
            .background(Theme.surface, in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
        }
    }

    // MARK: General access

    private var generalAccess: some View {
        let access = sharing.access
        let editable = sharing.canShare && !sharing.accessIsInherited && !sharing.busy.contains("access")
        return VStack(alignment: .leading, spacing: 6) {
            SectionCaption(title: "General access")
            HStack(spacing: 10) {
                Image(systemName: symbol(access))
                    .font(.system(size: 13))
                    .foregroundStyle(access == .restricted ? Theme.textSecondary : Theme.accent)
                    .frame(width: 26, height: 26)
                    .background(access == .restricted ? Theme.raised : Theme.accentSoft, in: .circle)
                VStack(alignment: .leading, spacing: 2) {
                    ChromeMenu(style: .chip) {
                        Button("Restricted") { set(.restricted) }
                        Button("Anyone with the link") { set(.anyone(access.role ?? .reader)) }
                        if let organization = sharing.organization {
                            Button("Anyone at \(organization)") { set(.domain(organization, access.role ?? .reader)) }
                        }
                    } label: {
                        MenuLabel(title: title(access), weight: .semibold, enabled: editable)
                    }
                    .disabled(!editable)
                    // The menu's padding, so its title lines up with the line below.
                    .padding(.leading, -6)
                    Text(detail(access))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if sharing.busy.contains("access") {
                    ProgressView().controlSize(.mini)
                } else if let current = access.role {
                    rolePicker(selection: Binding(get: { current }, set: { role in
                        switch access {
                        case .anyone: set(.anyone(role))
                        case .domain(let name, _): set(.domain(name, role))
                        case .restricted: break
                        }
                    }))
                    .disabled(!editable)
                }
            }
            .padding(10)
            .background(Theme.surface, in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
        }
    }

    private func set(_ access: DriveSharing.Access) {
        Task { await sharing.setAccess(access) }
    }

    private func symbol(_ access: DriveSharing.Access) -> String {
        switch access {
        case .restricted: "lock.fill"
        case .anyone: "globe"
        case .domain: "building.2.fill"
        }
    }

    private func title(_ access: DriveSharing.Access) -> String {
        switch access {
        case .restricted: "Restricted"
        case .anyone: "Anyone with the link"
        case .domain(let name, _): "Anyone at \(name)"
        }
    }

    private func detail(_ access: DriveSharing.Access) -> String {
        let suffix = sharing.accessIsInherited ? " Set by the shared drive or a folder above, so it's changed there." : ""
        switch access {
        case .restricted: return "Only people with access can open it." + suffix
        case .anyone: return "Anyone on the internet with the link can open it." + suffix
        case .domain(let name, _): return "Anyone signed in at \(name) with the link can open it." + suffix
        }
    }

    private func rolePicker(selection: Binding<DrivePermission.Role>) -> some View {
        ChromeMenu {
            Picker("Role", selection: selection) {
                ForEach(DrivePermission.Role.grantable, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(selection.wrappedValue.title)
        }
        .fixedSize()
    }
}

/// A menu's title with a chevron, so it reads as something to click.
private struct MenuLabel: View {
    let title: String
    var weight: Font.Weight = .regular
    let enabled: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(title).font(.system(size: 12, weight: weight))
            if enabled {
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
        }
        .foregroundStyle(enabled ? Theme.text : Theme.textSecondary)
    }
}

/// One person or group: who they are, and their role, which you can change or remove.
private struct PersonRow: View {
    let sharing: DriveSharing
    let person: DrivePermission

    var body: some View {
        HStack(spacing: 10) {
            Text(initial)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 26, height: 26)
                .background(Theme.accentSoft, in: .circle)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(person.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    if sharing.isYou(person) {
                        Text("(you)").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                    }
                    if person.kind == .group {
                        Text("group").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.textTertiary)
                    }
                }
                if let email = person.email, email != person.title {
                    Text(email).font(.system(size: 11)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
            }
            .textSelection(.enabled)
            Spacer(minLength: 8)
            if sharing.busy.contains(person.id) {
                ProgressView().controlSize(.mini)
            } else if editable {
                ChromeMenu(style: .chip) {
                    ForEach(DrivePermission.Role.grantable, id: \.self) { role in
                        Button {
                            Task { await sharing.setRole(role, for: person) }
                        } label: {
                            if role == person.role { Label(role.title, systemImage: "checkmark") } else { Text(role.title) }
                        }
                    }
                    Divider()
                    Button("Remove Access", role: .destructive) {
                        Task { await sharing.remove(person) }
                    }
                } label: {
                    MenuLabel(title: person.role.title, enabled: true)
                }
                .fixedSize()
            } else {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(person.role.title).font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
                    if person.inherited {
                        Text("from the shared drive").font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    /// Owners, people whose access comes from a shared drive, and anything when you can't
    /// share, are shown but not changed here.
    private var editable: Bool {
        sharing.canShare && person.role != .owner && !person.inherited
            && DrivePermission.Role.grantable.contains(person.role)
    }

    private var initial: String {
        person.title.first.map { String($0).uppercased() } ?? "?"
    }
}
