import AppKit
import UniformTypeIdentifiers

enum Format {
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

    static func date(_ date: Date?) -> String {
        guard let date else { return "—" }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today at " + date.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday at " + date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    /// Compact absolute date: "Today 11:47 PM", "Jun 6 1:53 PM", "Jun 6, 2024".
    static func compactDate(_ date: Date?) -> String {
        guard let date else { return "—" }
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return "Today \(time)" }
        if calendar.isDateInYesterday(date) { return "Yesterday \(time)" }
        if calendar.isDate(date, equalTo: Date(), toGranularity: .year) {
            return date.formatted(.dateTime.month(.abbreviated).day()) + " \(time)"
        }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    static func relative(_ date: Date?) -> String {
        guard let date else { return "" }
        return date.formatted(.relative(presentation: .named))
    }

    /// Path with the home directory abbreviated to ~.
    static func path(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
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
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    var isRoot: Bool { standardizedFileURL.path == "/" }
}
