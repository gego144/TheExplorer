import Foundation
import Testing
@testable import TheExplorer

/// Videos macOS can't read (MKV…) go through ffmpeg.
struct FFmpegTests {
    @Test func whichVideosNeedFFmpeg() {
        for name in ["rec.mkv", "clip.WEBM", "old.avi"] { #expect(FFmpeg.isForeignVideo(URL(fileURLWithPath: "/m/" + name))) }
        // MP4 and MOV are macOS's own; .ts is TypeScript far more often than video.
        for name in ["rec.mp4", "clip.mov", "index.ts", "notes.txt"] { #expect(!FFmpeg.isForeignVideo(URL(fileURLWithPath: "/m/" + name))) }
    }

    /// ffprobe's JSON for an OBS recording, read into what the inspector shows.
    @Test func readsAProbe() throws {
        let json = """
        {"streams": [
          {"codec_type": "video", "codec_name": "h264", "width": 1920, "height": 1080, "avg_frame_rate": "60/1",
           "disposition": {"attached_pic": 0}},
          {"codec_type": "audio", "codec_name": "aac", "sample_rate": "48000", "channels": 2, "bit_rate": "160000"}
        ],
        "format": {"duration": "51.8", "bit_rate": "20160000", "tags": {"title": "Demo"}}}
        """
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let probe = FFmpeg.parse(object)
        #expect(probe.duration == 51.8)
        #expect(probe.width == 1920 && probe.height == 1080)
        #expect(probe.frameRate == 60)
        #expect(probe.videoCodec == "H.264" && probe.audioCodec == "AAC")
        #expect(probe.sampleRate == 48000 && probe.channels == 2)
        // MKV gives only the overall rate: the video's is what isn't audio.
        #expect(probe.videoBitrate == 20_000_000)
        #expect(probe.title == "Demo")
    }

    @Test func readsARealFileWhenFFmpegIsInstalled() async throws {
        guard FFmpeg.isInstalled else { return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ffmpeg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let video = folder.appendingPathComponent("test.mkv")
        // Two seconds of test pattern, as an MKV.
        let make = Process()
        make.executableURL = FFmpeg.ffmpeg
        make.arguments = ["-nostdin", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc=duration=2:size=320x240:rate=30",
                          "-c:v", "libx264", "-pix_fmt", "yuv420p", video.path]
        try make.run()
        make.waitUntilExit()
        try #require(make.terminationStatus == 0)
        let probe = try #require(await FFmpeg.probe(video))
        #expect(probe.width == 320 && probe.height == 240)
        #expect(abs((probe.duration ?? 0) - 2) < 0.2)
        let frame = try #require(await FFmpeg.frame(video, side: 160, duration: probe.duration))
        #expect(frame.width == 160)
        let copy = try #require(await FFmpeg.playableCopy(of: video, modified: Date()))
        #expect(copy.pathExtension == "mp4")
        try? FileManager.default.removeItem(at: copy)
    }
}
