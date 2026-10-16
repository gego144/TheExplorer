import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import TheExplorer

/// Sample files made on the fly, removed when the test ends.
private final class Samples {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MediaInfoTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func url(_ name: String) -> URL { root.appendingPathComponent(name) }

    func write(_ name: String, _ text: String) throws -> URL {
        let url = url(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func image(_ name: String, type: UTType, width: Int, height: Int, frames: Int = 1,
               properties: [CFString: Any] = [:], frameProperties: [CFString: Any] = [:]) throws -> URL {
        let url = url(name)
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.9, green: 0.5, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, frames, nil))
        CGImageDestinationSetProperties(destination, properties as CFDictionary)
        for _ in 0..<frames { CGImageDestinationAddImage(destination, image, frameProperties as CFDictionary) }
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    func pdf(_ name: String, pages: Int, size: CGSize) -> URL {
        let url = url(name)
        var box = CGRect(origin: .zero, size: size)
        let context = CGContext(url as CFURL, mediaBox: &box, nil)!
        for _ in 0..<pages {
            context.beginPDFPage(nil)
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    /// A second of 320×240 H.264 at 30 fps.
    func video(_ name: String) async throws -> URL {
        let url = url(name)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 240,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 320,
            kCVPixelBufferHeightKey as String: 240,
        ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<30 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 30, timescale: 30))
        await writer.finishWriting()
        #expect(writer.status == .completed)
        return url
    }
}

private func info(_ url: URL) async -> MediaInfo? {
    await MediaInfoReader.read(url, type: UTType(filenameExtension: url.pathExtension), modified: Date())
}

private func value(_ info: MediaInfo?, _ label: String) -> String? {
    info?.rows.first { $0.label == label }?.value
}

struct MediaInfoTests {
    @Test func imageDimensions() async throws {
        let samples = try Samples()
        let png = try samples.image("hero.png", type: .png, width: 1280, height: 720)
        let result = await info(png)
        #expect(result?.summary == "1280 × 720")
        #expect(value(result, "dimensions") == "1280 × 720 px")
        #expect(value(result, "aspect") == "16:9")
    }

    @Test func sidewaysPhotosShowTheirShownSize() async throws {
        let samples = try Samples()
        let jpeg = try samples.image("photo.jpg", type: .jpeg, width: 400, height: 300,
                                     frameProperties: [kCGImagePropertyOrientation: 6])
        #expect(await info(jpeg)?.summary == "300 × 400")
    }

    @Test func animatedGIFLength() async throws {
        let samples = try Samples()
        let gif = try samples.image("spinner.gif", type: .gif, width: 64, height: 64, frames: 3,
                                    frameProperties: [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.5]])
        let result = await info(gif)
        #expect(value(result, "animation") == "3 frames · 0:01.5")
        #expect(result?.summary == "64 × 64 · 0:01.5")
    }

    @Test func svgSize() async throws {
        let samples = try Samples()
        let icon = try samples.write("icon.svg", #"<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24"><path d="M0 0h24v24H0z"/></svg>"#)
        #expect(await info(icon)?.summary == "24 × 24")
        let viewBoxOnly = try samples.write("logo.svg", #"<svg viewBox="0 0 120 60" xmlns="http://www.w3.org/2000/svg"></svg>"#)
        let result = await info(viewBoxOnly)
        #expect(result?.summary == "120 × 60")
        #expect(value(result, "aspect") == "2:1")
    }

    @Test func videoDetails() async throws {
        let samples = try Samples()
        let movie = try await samples.video("clip.mov")
        let result = await info(movie)
        #expect(result?.summary == "320 × 240 · 0:01")
        #expect(value(result, "resolution") == "320 × 240 (4:3)")
        #expect(value(result, "video") == "H.264")
        #expect(value(result, "frame rate") == "30 fps")
        #expect(value(result, "duration") == "0:01")
    }

    @Test func hlsPlaylists() async throws {
        let samples = try Samples()
        let media = try samples.write("clip.m3u8", """
        #EXTM3U
        #EXT-X-TARGETDURATION:10
        #EXTINF:10.000000,
        clip0.ts
        #EXTINF:10.000000,
        clip1.ts
        #EXTINF:4.500000,
        clip2.ts
        #EXT-X-ENDLIST
        """)
        let result = await info(media)
        #expect(result?.summary == "0:25")
        #expect(value(result, "duration") == "0:24.5")
        #expect(value(result, "segments") == "3 · ~0:08.2 each")
        let master = try samples.write("master.m3u8", """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080
        1080p.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
        360p.m3u8
        """)
        let variants = await info(master)
        #expect(variants?.summary == "2 variants")
        #expect(value(variants, "variant 1") == "1920 × 1080 · 5.0 Mbps")
        #expect(value(variants, "variant 2") == "640 × 360 · 800 kbps")
    }

    @Test func pdfPages() async throws {
        let samples = try Samples()
        let a4 = samples.pdf("doc.pdf", pages: 3, size: CGSize(width: 595, height: 842))
        let result = await info(a4)
        #expect(result?.summary == "3 pages")
        #expect(value(result, "page size") == "A4")
        #expect(value(result, "pages") == nil)
    }

    @Test func textLines() async throws {
        let samples = try Samples()
        let code = try samples.write("main.swift", "import Foundation\n\nprint(1)\n")
        #expect(await info(code)?.summary == "3 lines")
    }

    @Test func formatting() {
        #expect(MediaInfoReader.aspectRatio(1080, 1920) == "9:16")
        #expect(MediaInfoReader.aspectRatio(1000, 333) == nil)
        #expect(MediaInfoReader.codecName(0x6876_6331) == "HEVC") // hvc1
        #expect(Format.duration(3725) == "1:02:05")
        #expect(Format.duration(42) == "0:42")
        #expect(Format.bitrate(8_200_000) == "8.2 Mbps")
    }
}
