import AppKit
import Observation
import UniformTypeIdentifiers

/// Files with these extensions open in this app when you open them from TheExplorer.
struct OpenRule: Codable, Identifiable, Hashable {
    var id = UUID()
    /// Lowercased, without dots.
    var extensions: [String]
    /// The app's bundle identifier; empty until one is chosen.
    var appID: String
}

/// Your default apps for file types, set in Settings › Open With or from the right-click menu's
/// "Always Open With". They only apply to opening files from TheExplorer; macOS's own defaults
/// (and every other app) are left alone.
@MainActor
@Observable
final class OpenWithRules {
    static let shared = OpenWithRules(defaults: OpenWithRules.persists ? .standard : nil)

    private(set) var rules: [OpenRule] = []
    @ObservationIgnored private let defaults: UserDefaults?
    private static let key = "openWithRules"

    /// Scripted runs keep their rules to themselves.
    private static var persists: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["EXPLORER_SCENES"] == nil
        #else
        return true
        #endif
    }

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        if let data = defaults?.data(forKey: Self.key), let decoded = try? JSONDecoder().decode([OpenRule].self, from: data) {
            rules = decoded
        }
    }

    /// The app chosen for an extension, if it's still installed. The first rule listing it wins.
    func appID(forExtension ext: String) -> String? {
        let ext = ext.lowercased()
        guard !ext.isEmpty else { return nil }
        return rules.first { !$0.appID.isEmpty && $0.extensions.contains(ext) && FileOpener.appURL(for: $0.appID) != nil }?.appID
    }

    @discardableResult
    func add(extensions: [String] = [], appID: String = "") -> OpenRule {
        let rule = OpenRule(extensions: extensions, appID: appID)
        rules.append(rule)
        save()
        return rule
    }

    func update(_ rule: OpenRule) {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[index] = rule
        save()
    }

    func remove(_ rule: OpenRule) {
        rules.removeAll { $0.id == rule.id }
        save()
    }

    /// "Always Open With": moves the extension out of any other rule and into this app's.
    func setApp(_ appID: String, forExtension ext: String) {
        let ext = ext.lowercased()
        clear(ext, saving: false)
        if let index = rules.firstIndex(where: { $0.appID == appID }) {
            rules[index].extensions.append(ext)
        } else {
            rules.append(OpenRule(extensions: [ext], appID: appID))
        }
        save()
    }

    /// Goes back to the macOS default for the extension.
    func clear(_ ext: String, saving: Bool = true) {
        let ext = ext.lowercased()
        for index in rules.indices { rules[index].extensions.removeAll { $0 == ext } }
        // A rule emptied this way goes; one you're still filling in (no app yet) stays.
        rules.removeAll { $0.extensions.isEmpty && !$0.appID.isEmpty }
        if saving { save() }
    }

    /// Extensions listed by more than one rule (only the first one counts).
    func duplicates(in rule: OpenRule) -> [String] {
        let earlier = rules.prefix { $0.id != rule.id }.flatMap(\.extensions)
        return rule.extensions.filter(earlier.contains)
    }

    private func save() {
        guard let defaults, let data = try? JSONEncoder().encode(rules) else { return }
        defaults.set(data, forKey: Self.key)
    }

    /// Starting points for a new rule.
    static let presets: [(name: String, extensions: [String])] = [
        ("Images", ["png", "jpg", "jpeg", "gif", "webp", "heic", "tif", "tiff", "bmp", "svg"]),
        ("Video", ["mp4", "mov", "m4v", "mkv", "webm", "avi"]),
        ("Audio", ["mp3", "m4a", "wav", "aif", "aiff", "flac", "aac", "ogg"]),
        ("PDF", ["pdf"]),
        ("Text and Markdown", ["txt", "md", "markdown", "log"]),
        ("Code", ["swift", "js", "jsx", "ts", "tsx", "py", "rb", "go", "rs", "c", "h", "cpp", "java", "kt", "sh",
                  "css", "scss", "html", "json", "yaml", "yml", "toml", "xml", "sql"]),
    ]
}

/// Opens files the way you've set up: your rules first, then whatever macOS uses.
@MainActor
enum FileOpener {
    /// Opens `urls`, each in its rule's app or else its macOS default. Folders aren't handled
    /// here; browsing them is up to the caller.
    static func open(_ urls: [URL]) {
        var byApp: [URL: [URL]] = [:]
        for url in urls {
            if let app = ruleApp(for: url) {
                byApp[app, default: []].append(url)
            } else {
                systemOpen(url)
            }
        }
        for (app, files) in byApp { open(files, with: app) }
    }

    static func open(_ urls: [URL], with app: URL) {
        guard !logsInstead(urls) else { return }
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Opens a file in its default app, or a web link in the browser.
    static func systemOpen(_ url: URL) {
        guard !logsInstead([url]) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Scripted runs (debug builds) never launch other apps: they log what would have opened.
    private static func logsInstead(_ urls: [URL]) -> Bool {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["EXPLORER_SNAPSHOT_DIR"] != nil else { return false }
        for url in urls {
            FileHandle.standardError.write(Data("[snapshot] open \(url.isFileURL ? url.path : url.absoluteString)\n".utf8))
        }
        return true
        #else
        return false
        #endif
    }

    /// The app your rules pick for a file, if any.
    static func ruleApp(for url: URL) -> URL? {
        OpenWithRules.shared.appID(forExtension: url.pathExtension).flatMap(appURL(for:))
    }

    /// What opening the file uses: your rule's app, or else the macOS default.
    static func defaultApp(for url: URL) -> URL? {
        ruleApp(for: url) ?? NSWorkspace.shared.urlForApplication(toOpen: url)
    }

    /// One file per extension (and folders apart from files): which apps open a file goes by
    /// its type, so asking about each of thousands of selected files would repeat the same
    /// Launch Services lookups. Files without an extension are typed by their contents, so a
    /// few of those are kept.
    static func oneOfEachKind(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var bare = 0
        return urls.filter { url in
            let ext = url.pathExtension.lowercased()
            if ext.isEmpty && !url.hasDirectoryPath {
                bare += 1
                return bare <= 8
            }
            return seen.insert((url.hasDirectoryPath ? "/" : "") + ext).inserted
        }
    }

    /// Apps that can open every one of `urls`, by name, one copy of each.
    static func apps(for urls: [URL]) -> [URL] {
        var common: [String: URL]?
        for url in urls {
            var found: [String: URL] = [:]
            for app in NSWorkspace.shared.urlsForApplications(toOpen: url) {
                guard let id = bundleID(app) else { continue }
                found[id] = found[id].map { preferred($0, app) } ?? app
            }
            common = common.map { $0.filter { found[$0.key] != nil } } ?? found
            if common?.isEmpty == true { break }
        }
        return sortedByName(Array((common ?? [:]).values))
    }

    /// Apps that can open files with this extension.
    static func apps(forExtension ext: String) -> [URL] {
        guard let type = UTType(filenameExtension: ext) else { return [] }
        var found: [String: URL] = [:]
        for app in NSWorkspace.shared.urlsForApplications(toOpen: type) {
            guard let id = bundleID(app) else { continue }
            found[id] = found[id].map { preferred($0, app) } ?? app
        }
        return sortedByName(Array(found.values))
    }

    static func appURL(for bundleID: String) -> URL? {
        bundleID.isEmpty ? nil : NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    static func bundleID(_ app: URL) -> String? {
        Bundle(url: app)?.bundleIdentifier
    }

    static func name(_ app: URL) -> String {
        FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
    }

    /// The app's icon at menu size.
    static func icon(_ app: URL) -> NSImage {
        if let cached = icons[app.path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: app.path)
        icon.size = NSSize(width: 16, height: 16)
        icons[app.path] = icon
        return icon
    }

    private static var icons: [String: NSImage] = [:]

    /// Asks for any app, for "Other…".
    static func chooseApp() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Choose"
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// With two copies of an app, the one in /Applications.
    private static func preferred(_ a: URL, _ b: URL) -> URL {
        b.path.hasPrefix("/Applications/") && !a.path.hasPrefix("/Applications/") ? b : a
    }

    private static func sortedByName(_ apps: [URL]) -> [URL] {
        apps.sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
    }
}
