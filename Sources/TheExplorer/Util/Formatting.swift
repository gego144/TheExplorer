import AppKit
import UniformTypeIdentifiers

enum Format {
    private static let displayNames: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 2000
        return cache
    }()

    /// The name Finder shows for a path ("Downloads" in its own language, "Macintosh HD" for /).
    /// Remembered: asking LaunchServices each time a tab or pin was drawn took a millisecond or
    /// more per name. A renamed folder has a new path, so it's looked up afresh.
    static func displayName(_ path: String) -> String {
        if let name = displayNames.object(forKey: path as NSString) { return name as String }
        let name = FileManager.default.displayName(atPath: path)
        displayNames.setObject(name as NSString, forKey: path as NSString)
        return name
    }

    /// Decimal units like Finder, one decimal below 100: "0 B", "512 B", "4.2 KB", "266 MB", "12.4 GB".
    static func bytes(_ value: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var scaled = Double(max(0, value))
        var unit = 0
        while scaled >= 999.5 && unit < units.count - 1 {
            scaled /= 1000
            unit += 1
        }
        if unit == 0 { return "\(Int(scaled)) B" }
        return String(format: scaled < 99.95 ? "%.1f %@" : "%.0f %@", scaled, units[unit])
    }

    /// Date formatters made once: building a format for each date (Date.formatted) cost a
    /// fraction of a millisecond a time, several times per selection change in the inspector.
    private static func formatter(_ setup: (DateFormatter) -> Void) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        setup(formatter)
        return formatter
    }

    private static let timeOnly = formatter { $0.dateStyle = .none; $0.timeStyle = .short }
    private static let dateAndTime = formatter { $0.dateStyle = .medium; $0.timeStyle = .short }
    private static let monthDay = formatter { $0.setLocalizedDateFormatFromTemplate("MMMd") }
    private static let monthDayYear = formatter { $0.setLocalizedDateFormatFromTemplate("MMMdy") }
    private static let calendar = Calendar.autoupdatingCurrent

    static func date(_ date: Date?) -> String {
        guard let date else { return "—" }
        if calendar.isDateInToday(date) { return "Today at " + timeOnly.string(from: date) }
        if calendar.isDateInYesterday(date) { return "Yesterday at " + timeOnly.string(from: date) }
        return dateAndTime.string(from: date)
    }

    /// Compact absolute date: "Today 11:47 PM", "Jun 6 1:53 PM", "Jun 6, 2024".
    static func compactDate(_ date: Date?) -> String {
        guard let date else { return "—" }
        if calendar.isDateInToday(date) { return "Today " + timeOnly.string(from: date) }
        if calendar.isDateInYesterday(date) { return "Yesterday " + timeOnly.string(from: date) }
        if calendar.isDate(date, equalTo: Date(), toGranularity: .year) {
            return monthDay.string(from: date) + " " + timeOnly.string(from: date)
        }
        return monthDayYear.string(from: date)
    }

    /// A list's date: "Today 1:02 AM", "Yesterday", "Nov 5", "Oct 19, 2024".
    static func listDate(_ date: Date?) -> String {
        guard let date else { return "—" }
        if calendar.isDateInToday(date) { return "Today " + timeOnly.string(from: date) }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if calendar.isDate(date, equalTo: Date(), toGranularity: .year) { return monthDay.string(from: date) }
        return monthDayYear.string(from: date)
    }

    static func relative(_ date: Date?) -> String {
        guard let date else { return "" }
        return date.formatted(.relative(presentation: .named))
    }

    /// Path with the home directory abbreviated to ~.
    static func path(_ path: String) -> String {
        #if DEBUG
        if let demo = URL.demoHome {
            for home in [demo.path, demo.resolvingSymlinksInPath().path] {
                if path == home { return "~" }
                if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
            }
            return path
        }
        #endif
        return (path as NSString).abbreviatingWithTildeInPath
    }

    /// "0:42", "3:07", "1:02:05"; `precise` keeps tenths under a minute ("0:04.3").
    static func duration(_ seconds: Double, precise: Bool = false) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        if precise && seconds < 60 && seconds.rounded() != seconds {
            return String(format: "0:%04.1f", seconds)
        }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = total / 60 % 60
        let secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }

    /// "8.2 Mbps", "320 kbps".
    static func bitrate(_ bitsPerSecond: Double) -> String {
        if bitsPerSecond >= 1_000_000 { return String(format: "%.1f Mbps", bitsPerSecond / 1_000_000) }
        return "\(Int((bitsPerSecond / 1000).rounded())) kbps"
    }

    static func percent(_ part: Int64, of whole: Int64) -> String {
        guard whole > 0 else { return "" }
        let value = Double(part) / Double(whole)
        return value < 0.001 ? "<0.1%" : value.formatted(.percent.precision(.fractionLength(value < 0.1 ? 1 : 0)))
    }
}

/// Icon cache. Folders and packages get per-path icons (they can be customised);
/// regular files share an icon per content type.
@MainActor
enum Icons {
    private static let cache = NSCache<NSString, NSImage>()

    static func icon(for item: FileItem) -> NSImage {
        if item.isDirectory || item.contentType == nil {
            return icon(forPath: item.path)
        }
        let key = "type:" + item.contentType!.identifier as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image = NSWorkspace.shared.icon(for: item.contentType!)
        cache.setObject(image, forKey: key)
        return image
    }

    static func icon(forPath path: String) -> NSImage {
        let key = path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(image, forKey: key)
        return image
    }
}

extension URL {
    static let home: URL = {
        #if DEBUG
        if let demoHome { return demoHome }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser
    }()

    #if DEBUG
    /// EXPLORER_DEMO_HOME stands in for the home folder in "~" paths, so README screenshots
    /// read "~/Projects/…" while showing a demo folder rather than anything of yours.
    static let demoHome: URL? = ProcessInfo.processInfo.environment["EXPLORER_DEMO_HOME"]
        .map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
    #endif

    /// Whether this is /. Standardizing a path asks the disk about it, so that's only done for
    /// paths that could still turn out to be / ("/a/..").
    var isRoot: Bool {
        let path = path
        if path == "/" { return true }
        return path.contains("..") && standardizedFileURL.path == "/"
    }
}
