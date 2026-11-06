import AppKit
import UniformTypeIdentifiers

/// File icons by type, from the system, kept so tiles don't ask again.
@MainActor
enum FileIcons {
    private static var byType: [String: NSImage] = [:]

    static func icon(for item: FileItem) -> NSImage {
        let type = item.contentType ?? UTType(filenameExtension: item.fileExtension) ?? .data
        if let icon = byType[type.identifier] { return icon }
        let icon = NSWorkspace.shared.icon(for: type)
        byType[type.identifier] = icon
        return icon
    }
}
