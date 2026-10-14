import AppKit
import UniformTypeIdentifiers

/// A single entry on disk, captured with the metadata the UI needs.
struct FileItem: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let isPackage: Bool
    let isSymlink: Bool
    let isHidden: Bool
    /// Logical size for files. `nil` for folders (computed separately).
    let fileSize: Int64?
    /// Allocated size on disk for files.
    let allocatedSize: Int64?
    let created: Date?
    let modified: Date?
    let contentType: UTType?

    var id: URL { url }
    var path: String { url.path }

    /// A folder you can browse into. Packages (like .app) behave like files.
    var isFolder: Bool { isDirectory && !isPackage }

    var kindDescription: String {
        if isFolder { return "Folder" }
        if isSymlink && contentType == nil { return "Alias" }
        return FileItem.describe(contentType, isPackage: isPackage)
    }

    var fileExtension: String { url.pathExtension.lowercased() }

    static let resourceKeys: [URLResourceKey] = [
        .nameKey, .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isHiddenKey,
        .fileSizeKey, .totalFileAllocatedSizeKey, .creationDateKey,
        .contentModificationDateKey, .contentTypeKey,
    ]

    init(url: URL, name: String, isDirectory: Bool, isPackage: Bool = false, isSymlink: Bool = false,
         isHidden: Bool = false, fileSize: Int64? = nil, allocatedSize: Int64? = nil,
         created: Date? = nil, modified: Date? = nil, contentType: UTType? = nil) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.isSymlink = isSymlink
        self.isHidden = isHidden
        self.fileSize = fileSize
        self.allocatedSize = allocatedSize
        self.created = created
        self.modified = modified
        self.contentType = contentType
    }

    /// Reads metadata for `url`. Returns nil if the item no longer exists.
    init?(url: URL) {
        guard let values = try? url.resourceValues(forKeys: Set(FileItem.resourceKeys)) else { return nil }
        self.init(url: url, values: values)
    }

    init(url: URL, values: URLResourceValues) {
        let isDir = values.isDirectory ?? false
        let isPackage = values.isPackage ?? false
        self.init(
            url: url,
            name: values.name ?? url.lastPathComponent,
            isDirectory: isDir,
            isPackage: isPackage,
            isSymlink: values.isSymbolicLink ?? false,
            isHidden: values.isHidden ?? url.lastPathComponent.hasPrefix("."),
            fileSize: isDir && !isPackage ? nil : values.fileSize.map(Int64.init),
            allocatedSize: values.totalFileAllocatedSize.map(Int64.init),
            created: values.creationDate,
            modified: values.contentModificationDate,
            contentType: values.contentType
        )
    }

    private static let typeDescriptionCache = NSCache<NSString, NSString>()

    static func describe(_ type: UTType?, isPackage: Bool) -> String {
        guard let type else { return isPackage ? "Package" : "Document" }
        if let cached = typeDescriptionCache.object(forKey: type.identifier as NSString) {
            return cached as String
        }
        let description = type.localizedDescription ?? type.preferredFilenameExtension?.uppercased() ?? "Document"
        typeDescriptionCache.setObject(description as NSString, forKey: type.identifier as NSString)
        return description
    }
}

enum KindFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case folders = "Folders"
    case files = "Files"

    var id: String { rawValue }

    func matches(isFolder: Bool) -> Bool {
        switch self {
        case .all: true
        case .folders: isFolder
        case .files: !isFolder
        }
    }
}
