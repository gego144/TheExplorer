import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Observation
import SystemConfiguration

/// Receiving photos from an iPhone over Wi-Fi, no cable: TheExplorer serves a small page on
/// the local network (see PhoneReceiver), the iPhone opens it from a QR code and keeps it on
/// its Home Screen, and whatever it sends lands in the import folder.
@MainActor
@Observable
final class PhoneLink {
    static let shared = PhoneLink()

    /// Whether the Mac is accepting photos. Turned on the first time you set it up.
    private(set) var isOn: Bool
    private(set) var isListening = false
    private(set) var error: String?
    /// Files received since launch.
    private(set) var receivedCount = 0
    /// Bumped to show the setup sheet (with the QR code) from outside the sidebar.
    private(set) var setupRequest = 0

    func showSetup() { setupRequest += 1 }

    @ObservationIgnored private var server: PhoneReceiver?
    /// Incoming files' transfers in the status bar, by the server's ID for them.
    @ObservationIgnored private var transfers: [UUID: UUID] = [:]
    @ObservationIgnored private let defaults = UserDefaults.standard

    static let defaultPort: UInt16 = 47391

    private init() {
        isOn = defaults.bool(forKey: "phoneLinkOn")
    }

    var port: UInt16 {
        (defaults.object(forKey: "phoneLinkPort") as? Int).flatMap { UInt16(exactly: $0) } ?? Self.defaultPort
    }

    /// The pairing key in the QR code. Without it, nothing on the network can see the page or
    /// send files.
    var token: String {
        if let saved = defaults.string(forKey: "phoneLinkToken"), saved.count >= 32 { return saved }
        let token = Self.randomToken()
        defaults.set(token, forKey: "phoneLinkToken")
        return token
    }

    /// "Davids-MacBook-Pro.local": found by the iPhone without knowing the Mac's address, which
    /// can change.
    var hostName: String {
        let name = SCDynamicStoreCopyLocalHostName(nil) as String? ?? "localhost"
        return name + ".local"
    }

    var macName: String { SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "Mac" }

    /// What the QR code opens.
    var pageURL: URL { URL(string: "http://\(hostName):\(port)/?t=\(token)")! }

    /// The same page by the Mac's current Wi-Fi address, for networks that don't pass on
    /// ".local" names.
    var addressURL: URL? {
        Self.localIPv4().map { URL(string: "http://\($0):\(port)/?t=\(token)")! }
    }

    func setOn(_ on: Bool) {
        isOn = on
        defaults.set(on, forKey: "phoneLinkOn")
        on ? start() : stop()
    }

    /// Starts receiving if it's turned on. Called at launch.
    func start() {
        guard isOn, server == nil else { return }
        error = nil
        let config = PhoneReceiver.Config(port: port, token: token, folder: Prefs.shared.importFolder, macName: macName)
        let events = PhoneReceiver.Events(
            started: { id, name, bytes, folder in PhoneLink.shared.started(id, name: name, bytes: bytes, folder: folder) },
            progress: { id, bytes in PhoneLink.shared.progressed(id, bytes: bytes) },
            finished: { id, file, error in PhoneLink.shared.finished(id, file: file, error: error) },
            state: { listening, error in PhoneLink.shared.stateChanged(listening, error) }
        )
        let server = PhoneReceiver(config: config, events: events)
        self.server = server
        server.start()
    }

    func stop() {
        server?.stop()
        server = nil
        isListening = false
    }

    /// Makes a new pairing key, so links handed out before stop working.
    func resetPairing() {
        defaults.set(Self.randomToken(), forKey: "phoneLinkToken")
        restart()
    }

    func importFolderChanged() {
        let folder = Prefs.shared.importFolder
        server?.update { $0.folder = folder }
    }

    private func restart() {
        stop()
        start()
    }

    // MARK: Events from the server

    private func stateChanged(_ listening: Bool, _ error: String?) {
        isListening = listening
        self.error = error
    }

    private func started(_ id: UUID, name: String, bytes: Int64, folder: URL) {
        let shared = Transfers.shared
        let transfer = shared.start(.download, title: "“\(name)” from iPhone", folder: folder)
        shared.update(transfer) {
            $0.receiving = true
            $0.totalBytes = bytes
            $0.totalItems = 1
        }
        transfers[id] = transfer
    }

    private func progressed(_ id: UUID, bytes: Int64) {
        guard let transfer = transfers[id] else { return }
        Transfers.shared.update(transfer) { $0.doneBytes = bytes }
    }

    private func finished(_ id: UUID, file: URL?, error: String?) {
        guard let transfer = transfers.removeValue(forKey: id) else { return }
        let shared = Transfers.shared
        if let file {
            receivedCount += 1
            shared.update(transfer) {
                $0.doneBytes = $0.totalBytes
                $0.doneItems = 1
                $0.placed = [file]
            }
            shared.finish(transfer, .done)
        } else {
            shared.finish(transfer, .failed(error ?? "The transfer stopped."))
        }
    }

    // MARK: Helpers

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 20)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// The Mac's address on Wi-Fi or Ethernet.
    static func localIPv4() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var found: [String: String] = [:]
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  (entry.ifa_flags & UInt32(IFF_UP)) != 0, (entry.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            let name = String(cString: entry.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                found[name] = String(cString: host)
            }
        }
        return found.keys.sorted().first.flatMap { found[$0] }
    }

    /// The pairing QR code, sharp at `side` points on a Retina screen.
    func qrCode(side: CGFloat) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(pageURL.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale = (side * 2 / output.extent.width).rounded(.down)
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let image = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: side, height: side))
    }
}
