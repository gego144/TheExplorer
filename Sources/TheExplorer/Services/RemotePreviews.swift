import AVFoundation
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// A preview of an S3 or Google Drive file, made without downloading it to disk.
enum RemotePreview: @unchecked Sendable {
    case image(CGImage)
    case text(String, truncated: Bool)
}

/// Previews for the inspector, fetched with as little as each kind of file needs:
///
/// - Google Drive makes its own thumbnails (images, videos, PDFs, Docs, Sheets, Slides…), so
///   only that small image is fetched. Text files show their first 32 KB instead.
/// - S3 has no thumbnails. Text shows its first 32 KB (a range request); videos stream a
///   single frame through a temporary signed link; images and PDFs up to a size are read
///   into memory and shrunk; bigger images show the thumbnail embedded in their first
///   megabyte, which cameras and phones write.
///
/// Nothing touches the disk, and previews are kept in memory by file version.
@MainActor
enum RemotePreviews {
    private final class Entry {
        let preview: RemotePreview?
        init(_ preview: RemotePreview?) { self.preview = preview }
    }

    private static let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 120
        return cache
    }()

    /// Pixels on the long side of image previews.
    nonisolated static let side = 900
    nonisolated static let textBytes: Int64 = 32_768
    /// S3 images and PDFs up to these sizes are read whole; past them, only images, and only
    /// their embedded thumbnail.
    nonisolated static let imageLimit: Int64 = 25_000_000
    nonisolated static let pdfLimit: Int64 = 20_000_000
    nonisolated static let headBytes: Int64 = 1_048_576
    /// How much of a text file the card shows.
    nonisolated static let previewLines = 150
    nonisolated static let previewCharacters = 12_000

    enum Plan: Equatable {
        case driveThumbnail, text, image, imageHead, video, pdf
    }

    /// How a file would be previewed, or nil when it wouldn't be. Decided without the network,
    /// so the inspector only makes room for previews that will come.
    static func plan(for url: URL, size: Int64?) -> Plan? {
        if let location = DriveLocation(url: url) {
            guard !location.isFolder, let file = DriveStore.shared.file(location) else { return nil }
            if !file.isGoogleDoc, isText(UTType(filenameExtension: (file.name as NSString).pathExtension)), (size ?? 1) > 0 { return .text }
            return file.thumbnailLink != nil ? .driveThumbnail : nil
        }
        guard let location = S3Location(url: url), location.bucket != nil, !location.prefix.isEmpty,
              !location.prefix.hasSuffix("/"), (size ?? 1) > 0 else { return nil }
        guard let type = UTType(filenameExtension: url.pathExtension) else { return nil }
        if isText(type) { return .text }
        if type.conforms(to: .image) { return (size ?? 0) <= imageLimit ? .image : .imageHead }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .pdf), (size ?? 0) <= pdfLimit { return .pdf }
        return nil
    }

    static func isText(_ type: UTType?) -> Bool {
        guard let type else { return false }
        return type.conforms(to: .text) || type.conforms(to: .sourceCode) || type.conforms(to: .json)
            || type.conforms(to: .propertyList) || type.conforms(to: .xml) || type.conforms(to: .commaSeparatedText)
    }

    private static func key(_ url: URL, _ version: String) -> NSString { (url.absoluteString + "|" + version) as NSString }

    /// A preview already made for this version of the file, if any. The outer optional is
    /// whether one was tried; the inner, whether it worked.
    static func cached(_ url: URL, version: String) -> RemotePreview?? {
        cache.object(forKey: key(url, version)).map(\.preview)
    }

    static func load(_ url: URL, size: Int64?, version: String) async -> RemotePreview? {
        if let hit = cached(url, version: version) { return hit }
        guard let plan = plan(for: url, size: size) else { return nil }
        let preview = try? await make(plan, url: url, size: size)
        if !Task.isCancelled { cache.setObject(Entry(preview), forKey: key(url, version)) }
        return preview
    }

    private static func make(_ plan: Plan, url: URL, size: Int64?) async throws -> RemotePreview? {
        if let location = DriveLocation(url: url) {
            guard let client = DriveStore.shared.client(for: location.accountID) else { return nil }
            var file = try await DriveStore.shared.details(location)
            if plan == .text {
                let data = try await client.data(file.contentID, range: 0...(textBytes - 1))
                return text(from: data, truncated: Int64(data.count) >= textBytes)
            }
            guard let link = file.thumbnailLink else { return nil }
            let data: Data
            do {
                data = try await client.thumbnail(link, size: side)
            } catch {
                // Thumbnail links only last a few hours; a fresh listing has a new one.
                file = try await client.file(location.id)
                DriveStore.shared.remember([file], in: nil, accountID: location.accountID)
                guard let fresh = file.thumbnailLink else { return nil }
                data = try await client.thumbnail(fresh, size: side)
            }
            return await decoded(data)
        }

        guard let location = S3Location(url: url), let bucket = location.bucket,
              let client = S3Store.shared.client(for: location.connectionID) else { return nil }
        let key = location.prefix
        switch plan {
        case .text:
            let data = try await client.data(bucket: bucket, key: key, range: 0...(textBytes - 1))
            return text(from: data, truncated: Int64(data.count) >= textBytes || (size ?? 0) > textBytes)
        case .image, .pdf:
            let data = try await client.data(bucket: bucket, key: key)
            return plan == .pdf ? await pdfPage(data) : await decoded(data)
        case .imageHead:
            let data = try await client.data(bucket: bucket, key: key, range: 0...(headBytes - 1))
            return await decoded(data, embeddedOnly: true)
        case .video:
            let link = try await client.shareURL(bucket: bucket, key: key, expires: 900)
            return try await videoFrame(link)
        case .driveThumbnail:
            return nil
        }
    }

    /// Text from the start of a file, unless it's binary: whole lines, and only as many as the
    /// card shows, since laying out thousands would stall the main thread.
    nonisolated static func text(from data: Data, truncated cut: Bool) -> RemotePreview? {
        guard !data.prefix(8192).contains(0) else { return nil }
        var text = String(decoding: data, as: UTF8.self)
        // A character cut in half at the end of the range.
        if cut { while text.last == "\u{FFFD}" { text.removeLast() } }
        var lines = 0
        var capped = false
        for index in text.indices where text[index] == "\n" {
            lines += 1
            if lines == previewLines || text.utf8.distance(from: text.startIndex, to: index) > previewCharacters {
                text = String(text[..<index])
                capped = true
                break
            }
        }
        // One enormous line (minified JSON) is cut by length.
        if !capped, text.count > previewCharacters {
            text = String(text.prefix(previewCharacters))
            capped = true
        }
        if cut && !capped, let newline = text.lastIndex(of: "\n") { text = String(text[..<newline]) }
        return .text(text, truncated: cut || capped)
    }

    /// A shrunk image, made off the main thread. With `embeddedOnly`, only a thumbnail the
    /// file carries (the data is just its start, so the full image isn't there).
    private static func decoded(_ data: Data, embeddedOnly: Bool = false) async -> RemotePreview? {
        await Task.detached(priority: .userInitiated) { () -> RemotePreview? in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            var options: [CFString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: side,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            if embeddedOnly {
                options[kCGImageSourceCreateThumbnailFromImageIfAbsent] = false
            } else {
                options[kCGImageSourceCreateThumbnailFromImageAlways] = true
            }
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map(RemotePreview.image)
        }.value
    }

    private static func pdfPage(_ data: Data) async -> RemotePreview? {
        await Task.detached(priority: .userInitiated) { () -> RemotePreview? in
            guard let page = PDFDocument(data: data)?.page(at: 0) else { return nil }
            let image = page.thumbnail(of: CGSize(width: side, height: side), for: .mediaBox)
            return image.cgImage(forProposedRect: nil, context: nil, hints: nil).map(RemotePreview.image)
        }.value
    }

    /// A frame from about a second in (past any fade from black), read over the network. It
    /// takes the nearest keyframe rather than decoding up to an exact time, so only the start
    /// of the video is fetched.
    private static func videoFrame(_ link: URL) async throws -> RemotePreview? {
        let asset = AVURLAsset(url: link)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: side, height: side)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        let time = CMTime(seconds: duration.isFinite && duration > 0 ? min(1, duration * 0.1) : 0, preferredTimescale: 600)
        return .image(try await generator.image(at: time).image)
    }
}
