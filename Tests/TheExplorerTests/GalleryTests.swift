import AppKit
import Testing
@testable import TheExplorer

@MainActor
struct GalleryTests {
    @Test func videoLengthsReadLikeAClock() {
        #expect(Thumbnails.durationText(9.6) == "0:10")
        #expect(Thumbnails.durationText(83) == "1:23")
        #expect(Thumbnails.durationText(3753) == "1:02:33")
    }

    @Test func driveVideosKnowTheirLength() {
        let file = DriveFile(json: ["id": "clip", "name": "IMG_0353.MOV", "mimeType": "video/quicktime",
                                    "videoMediaMetadata": ["durationMillis": "83000"]])
        #expect(file?.duration == 83)
        #expect(DriveFile(json: ["id": "photo", "name": "IMG_0341.HEIC"])?.duration == nil)
    }

    @Test func thumbnailSizesComeInSteps() {
        #expect(Thumbnails.step(200) == 256)
        #expect(Thumbnails.step(256) == 256)
        #expect(Thumbnails.step(600) == 768)
        #expect(Thumbnails.step(5000) == 1024)
    }

    @Test func localPhotosGetAThumbnail() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("GalleryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("red.png")
        let image = NSImage(size: NSSize(width: 64, height: 48), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        let rep = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
        let item = try #require(FileItem(url: url))
        let entry = await Thumbnails.load(item, side: 256)
        #expect(entry.image != nil)
        #expect(Thumbnails.cached(item, side: 256)?.image != nil)
        #expect(entry.duration == nil)
    }
}
