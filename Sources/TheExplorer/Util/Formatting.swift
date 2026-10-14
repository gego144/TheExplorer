import AppKit
import UniformTypeIdentifiers

enum Format {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
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

    static func relative(_ date: Date?) -> String {
        guard let date else { return "" }
        return date.formatted(.relative(presentation: .named))
    }

    /// Path with the home directory abbreviated to ~.
    static func path(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
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
