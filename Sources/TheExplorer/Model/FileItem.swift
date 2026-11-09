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

    /// The kind in a word or two, for the list's Kind column: "Swift", "PNG image", "Word".
    /// The full name (`kindDescription`) is in the tooltip and the details.
    var shortKind: String {
        if isFolder { return "Folder" }
        if isSymlink && contentType == nil { return "Alias" }
        return FileItem.shortKind(extension: fileExtension, type: contentType, isPackage: isPackage)
    }

    private static let shortKindCache = NSCache<NSString, NSString>()

    static func shortKind(extension ext: String, type: UTType?, isPackage: Bool) -> String {
        let key = "\(ext)|\(type?.identifier ?? "")|\(isPackage)" as NSString
        if let cached = shortKindCache.object(forKey: key) { return cached as String }
        let kind = makeShortKind(ext, type, isPackage)
        shortKindCache.setObject(kind as NSString, forKey: key)
        return kind
    }

    private static func makeShortKind(_ ext: String, _ type: UTType?, _ isPackage: Bool) -> String {
        if let known = shortKinds[ext] { return known }
        if let type {
            if type.conforms(to: .application) { return "App" }
            // The format, then what it is: "PNG image", "MP4 video", "MP3 audio".
            let format = ext.isEmpty ? nil : (formatNames[ext] ?? ext.uppercased())
            if let format, format.count <= 5 {
                if type.conforms(to: .image) { return "\(format) image" }
                if type.conforms(to: .movie) || type.conforms(to: .video) { return "\(format) video" }
                if type.conforms(to: .audio) { return "\(format) audio" }
            }
            // macOS's own name, without the words every kind ends in.
            var name = type.localizedDescription ?? ""
            for suffix in [" source code", " header code", " script", " text file", " text", " document", " file", " source", " media"]
            where name.lowercased().hasSuffix(suffix) && name.count > suffix.count {
                name = String(name.dropLast(suffix.count))
                break
            }
            name = name.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, name.count <= 16, !type.identifier.hasPrefix("dyn.") {
                return name.prefix(1).uppercased() + name.dropFirst()
            }
        }
        if isPackage { return "Package" }
        if !ext.isEmpty && ext.count <= 6 { return ext.uppercased() }
        return "Document"
    }

    /// Display names for formats whose extension reads oddly in capitals.
    private static let formatNames = ["jpg": "JPEG", "jpeg": "JPEG", "tif": "TIFF", "mpg": "MPEG", "mpeg": "MPEG", "m4v": "M4V"]

    /// Common kinds macOS names at length, or not at all, or wrongly (".ts" isn't a video here).
    private static let shortKinds: [String: String] = {
        var kinds: [String: String] = [:]
        func add(_ name: String, _ extensions: String...) { extensions.forEach { kinds[$0] = name } }
        add("Swift", "swift"); add("TypeScript", "ts", "tsx", "mts", "cts"); add("JavaScript", "js", "jsx", "mjs", "cjs")
        add("Python", "py", "pyi"); add("Ruby", "rb"); add("Go", "go"); add("Rust", "rs"); add("C", "c"); add("C header", "h")
        add("C++", "cpp", "cc", "cxx"); add("C++ header", "hpp", "hh"); add("Objective-C", "m", "mm"); add("Java", "java")
        add("Kotlin", "kt", "kts"); add("C#", "cs"); add("PHP", "php"); add("Shell script", "sh", "bash", "zsh", "fish")
        add("Dart", "dart"); add("Lua", "lua"); add("Vue", "vue"); add("Svelte", "svelte"); add("GraphQL", "graphql", "gql")
        add("HTML", "html", "htm"); add("CSS", "css"); add("Sass", "scss", "sass"); add("JSON", "json", "jsonc")
        add("YAML", "yaml", "yml"); add("TOML", "toml"); add("XML", "xml"); add("SQL", "sql"); add("Markdown", "md", "markdown", "mdx")
        add("Text", "txt"); add("Log", "log"); add("CSV", "csv"); add("TSV", "tsv"); add("Property list", "plist")
        add("Config", "conf", "cfg", "ini"); add("Lockfile", "lock"); add("Shader", "shader", "hlsl", "glsl", "metal")
        add("PDF", "pdf"); add("Word", "doc", "docx"); add("Excel", "xls", "xlsx"); add("PowerPoint", "ppt", "pptx")
        add("Keynote", "key"); add("Pages", "pages"); add("Numbers", "numbers"); add("Rich text", "rtf"); add("EPUB", "epub")
        add("ZIP archive", "zip"); add("TAR archive", "tar"); add("GZip archive", "gz", "tgz"); add("7-Zip archive", "7z")
        add("RAR archive", "rar"); add("Disk image", "dmg", "iso"); add("Installer", "pkg")
        add("Font", "ttf", "otf", "woff", "woff2"); add("MKV video", "mkv"); add("WebM video", "webm")
        add("Photoshop", "psd"); add("Sketch", "sketch"); add("Figma", "fig"); add("Blender", "blend")
        add("3D model", "glb", "gltf", "fbx", "obj", "usdz"); add("Certificate", "pem", "crt", "cer")
        add("Database", "sqlite", "db"); add("Calendar", "ics"); add("Contact", "vcf"); add("Library", "dylib", "a")
        add("Windows app", "exe")
        return kinds
    }()
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
