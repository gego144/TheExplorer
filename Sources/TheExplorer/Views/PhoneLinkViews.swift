import AppKit
import SwiftUI

/// Setting up "From iPhone": the QR code that pairs the iPhone, what to do with it, and where
/// photos go. Opening it turns receiving on.
struct PhoneLinkSheet: View {
    /// Called when it closes; true to show the folder photos land in.
    let onDone: (_ showFolder: Bool) -> Void
    private var link: PhoneLink { .shared }
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Send photos from your iPhone").font(.system(size: 16, weight: .semibold))
                Text("Over Wi-Fi, no cable or iCloud. Your iPhone and this Mac need to be on the same network.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .top, spacing: 18) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(.white)
                    if let code = link.qrCode(side: 170) {
                        Image(nsImage: code).interpolation(.none).resizable().frame(width: 170, height: 170)
                    }
                }
                .frame(width: 190, height: 190)
                .id(link.pageURL)
                VStack(alignment: .leading, spacing: 12) {
                    step(1, "Open the **Camera** on your iPhone and point it at this code, then tap the link.")
                    step(2, "In Safari, tap **Share**, then **Add to Home Screen**. You only do this once.")
                    step(3, "Any time, open **Send to Mac** from your Home Screen and pick photos. They land in “\(Prefs.shared.importFolder.lastPathComponent)” here.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            status
            VStack(spacing: 8) {
                row("Folder") {
                    Text(Format.path(Prefs.shared.importFolder.path)).font(Theme.mono).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Change…") { Self.chooseFolder() }.buttonStyle(SubtleButtonStyle())
                }
                row("Link") {
                    Text(link.pageURL.host() ?? "").font(Theme.mono).lineLimit(1).truncationMode(.middle)
                        .help("If the iPhone can't open the link, scan the code again or copy the address link instead.")
                    Spacer()
                    if let address = link.addressURL {
                        Button(copied ? "Copied" : "Copy Address Link") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(address.absoluteString, forType: .string)
                            copied = true
                        }
                        .buttonStyle(SubtleButtonStyle())
                        .help("A link by this Mac's address (\(address.host() ?? "")), for networks where the name doesn't work")
                    }
                }
            }
            .padding(12)
            .background(Theme.surface, in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
            HStack {
                Button("Reset Pairing") { link.resetPairing() }
                    .buttonStyle(SubtleButtonStyle())
                    .help("Make a new code. Home Screen links from the old one stop working.")
                if link.isOn {
                    Button("Stop Receiving") {
                        link.setOn(false)
                        onDone(false)
                    }
                    .buttonStyle(SubtleButtonStyle())
                }
                Spacer()
                Button("Show Folder") { onDone(true) }.buttonStyle(SubtleButtonStyle())
                Button("Done") { onDone(false) }
                    .buttonStyle(AccentButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .background(Theme.background)
        .preferredColorScheme(Theme.colorScheme)
        .onAppear { if !link.isOn { link.setOn(true) } }
    }

    @ViewBuilder private var status: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(link.error != nil ? Theme.danger : (link.isListening ? Color(red: 0.43, green: 0.72, blue: 1) : Theme.textTertiary))
                .frame(width: 7, height: 7)
            Text(statusText)
                .font(.system(size: 11.5))
                .foregroundStyle(link.error != nil ? Theme.danger : Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusText: String {
        if let error = link.error { return "Can't receive: \(error)" }
        if !link.isListening { return "Starting…" }
        let count = link.receivedCount
        return "Ready for your iPhone" + (count > 0 ? " · \(count.formatted()) received so far" : "") + ". Keep TheExplorer open to receive."
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text("\(number)")
                .font(.system(size: 11, weight: .bold).monospacedDigit())
                .frame(width: 20, height: 20)
                .background(Theme.raised, in: .circle)
            Text(text)
                .font(.system(size: 12.5))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Asks for a folder and makes it where photos land.
    static func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = Prefs.shared.importFolder
        panel.prompt = "Use Folder"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        Prefs.shared.importFolder = folder
    }

    private func row(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary).frame(width: 48, alignment: .leading)
            content()
        }
        .font(.system(size: 11.5))
    }
}
