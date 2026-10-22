import AVFoundation
import AppKit
import QuickLookThumbnailing

/// Thumbnails for the gallery: Quick Look's for files on this Mac (photos, videos, PDFs, and
/// whatever else it can draw), Drive's own for Drive files, and a cheap image or frame for S3.
///
/// Only tiles on screen ask, and a tile scrolled away cancels its request. Images are kept in
/// memory by file version and size, up to a budget, so scrolling back is instant.
@MainActor
enum Thumbnails {
    final class Entry {
        let image: CGImage?
        /// A video's length, in seconds.
        let duration: Double?
        init(image: CGImage?, duration: Double?) {
            self.image = image
            self.duration = duration
        }
    }

    private static let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        // Decoded pixels: 4 bytes each.
        cache.totalCostLimit = 300_000_000
        return cache
    }()

    /// Drive and S3 thumbnails are network requests; a few at a time keeps them quick to start
    /// and leaves the connection free for whatever else is happening.
    private static let remoteSlots = Slots(6)

    /// Sizes are rounded up to one of a few steps, so changing the tile size a little reuses
    /// what's cached.
    static func step(_ pixels: CGFloat) -> Int {
        let steps = [256, 384, 512, 768, 1024]
        return steps.first { CGFloat($0) >= pixels } ?? steps.last!
    }

    private static func key(_ item: FileItem, _ side: Int) -> NSString {
        let version = "\(item.modified?.timeIntervalSinceReferenceDate ?? 0)|\(item.fileSize ?? -1)"
        return "\(item.url.absoluteString)|\(version)|\(side)" as NSString
    }

    /// What's already made for this version of the file at this size, if anything.
    static func cached(_ item: FileItem, side: Int) -> Entry? {
        cache.object(forKey: key(item, side))
    }

    static func load(_ item: FileItem, side: Int) async -> Entry {
        let key = key(item, side)
        if let hit = cache.object(forKey: key) { return hit }
        let entry: Entry
        if RemoteFiles.isRemote(item.url) {
            let image = await remoteSlots.run { await RemotePreviews.thumbnail(item.url, size: item.fileSize, side: side) }
            entry = Entry(image: image, duration: DriveStore.shared.file(at: item.url)?.duration)
        } else {
            async let image = localThumbnail(item.url, side: side)
            async let duration = isVideo(item) ? videoDuration(item.url) : nil
            entry = Entry(image: await image, duration: await duration)
        }
        guard !Task.isCancelled else { return entry }
        let cost = entry.image.map { $0.width * $0.height * 4 } ?? 0
        cache.setObject(entry, forKey: key, cost: cost)
        return entry
    }

    nonisolated static func isVideo(_ item: FileItem) -> Bool {
        guard let type = item.contentType ?? UTType(filenameExtension: item.fileExtension) else { return false }
        return type.conforms(to: .movie) || type.conforms(to: .video)
    }

    /// Quick Look's thumbnail, without the icon it falls back to (the tile draws that itself).
    /// Cancelling the task cancels the request, so tiles flung past don't queue up work.
    private nonisolated static func localThumbnail(_ url: URL, side: Int) async -> CGImage? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side), scale: 1,
                                                   representationTypes: .thumbnail)
        let generator = QLThumbnailGenerator.shared
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                generator.generateBestRepresentation(for: request) { representation, _ in
                    continuation.resume(returning: representation?.cgImage)
                }
            }
        } onCancel: {
            generator.cancel(request)
        }
    }

    private nonisolated static func videoDuration(_ url: URL) async -> Double? {
        guard let duration = try? await AVURLAsset(url: url).load(.duration).seconds, duration.isFinite, duration > 0 else { return nil }
        return duration
    }

    /// "0:42", "12:05", "1:02:33".
    nonisolated static func durationText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let (hours, minutes, secs) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }
}

/// Lets a few tasks run at once; the rest wait their turn, and a cancelled one gives up its place.
@MainActor
final class Slots {
    private var free: Int
    private var waiting: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []

    init(_ count: Int) { free = count }

    func run<T>(_ work: () async -> T?) async -> T? {
        guard await acquire() else { return nil }
        defer { release() }
        guard !Task.isCancelled else { return nil }
        return await work()
    }

    private func acquire() async -> Bool {
        if free > 0 {
            free -= 1
            return true
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiting.append((id, continuation))
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(returning: false)
    }

    private func release() {
        // Newest first: the tiles you've just scrolled to are the ones you're looking at.
        if let next = waiting.popLast() {
            next.continuation.resume(returning: true)
        } else {
            free += 1
        }
    }
}
