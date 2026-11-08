import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// ffmpeg, when it's installed (Homebrew puts it in /opt/homebrew/bin), for videos macOS can't
/// read itself: MKV (OBS records to it), WebM, AVI and the like. It gives them a frame for the
/// thumbnail and preview, their details (length, size, codecs), and a copy macOS can play,
/// re-wrapped into MP4 without re-encoding, so it takes seconds rather than minutes.
enum FFmpeg {
    /// Extensions of videos AVFoundation and Quick Look don't open. Not "ts": that's TypeScript
    /// far more often than an MPEG transport stream.
    static let foreignVideo: Set<String> = ["mkv", "webm", "avi", "flv", "wmv", "ogv", "m2ts", "mts", "divx", "vob"]

    static func isForeignVideo(_ url: URL) -> Bool { foreignVideo.contains(url.pathExtension.lowercased()) }

    private static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin"]

    /// Where the tool is, or nil when it isn't installed.
    static let ffmpeg: URL? = locate("ffmpeg")
    static let ffprobe: URL? = locate("ffprobe")
    static var isInstalled: Bool { ffmpeg != nil }

    private static func locate(_ name: String) -> URL? {
        let paths = searchPaths + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return paths.lazy.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    // MARK: Running

    /// Runs a tool and returns what it wrote, or nil when it failed. Cancelling the task stops it.
    private static func run(_ tool: URL, _ arguments: [String]) async -> Data? {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try process.run()
                    } catch {
                        return continuation.resume(returning: nil)
                    }
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    continuation.resume(returning: process.terminationStatus == 0 ? data : nil)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    // MARK: Frames

    /// A frame from the video, at most `side` pixels across, taken a little way in (the first
    /// frame of a recording is often black).
    static func frame(_ url: URL, side: Int, duration: Double? = nil) async -> CGImage? {
        guard let ffmpeg else { return nil }
        let at = duration.map { min(1, $0 * 0.1) } ?? 1
        let scale = "scale='min(\(side),iw)':'min(\(side),ih)':force_original_aspect_ratio=decrease"
        let arguments = ["-nostdin", "-loglevel", "error", "-ss", String(format: "%.2f", at), "-i", url.path,
                         "-frames:v", "1", "-vf", scale, "-f", "image2pipe", "-vcodec", "png", "-"]
        guard let data = await run(ffmpeg, arguments), !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    // MARK: Details

    struct Probe: Sendable {
        var duration: Double?
        var width: Int?
        var height: Int?
        var frameRate: Double?
        var videoCodec: String?
        var videoBitrate: Double?
        var audioCodec: String?
        var sampleRate: Double?
        var channels: Int?
        var audioBitrate: Double?
        var title: String?
    }

    static func probe(_ url: URL) async -> Probe? {
        guard let ffprobe,
              let data = await run(ffprobe, ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", url.path]),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return parse(json)
    }

    /// ffprobe's JSON, read into what the inspector shows.
    static func parse(_ json: [String: Any]) -> Probe {
        var probe = Probe()
        func number(_ value: Any?) -> Double? {
            if let value = value as? Double { return value }
            if let value = value as? Int { return Double(value) }
            return (value as? String).flatMap(Double.init)
        }
        let format = json["format"] as? [String: Any] ?? [:]
        probe.duration = number(format["duration"])
        probe.title = (format["tags"] as? [String: Any])?["title"] as? String
        for stream in json["streams"] as? [[String: Any]] ?? [] {
            switch stream["codec_type"] as? String {
            case "video" where probe.videoCodec == nil && (stream["disposition"] as? [String: Any])?["attached_pic"] as? Int != 1:
                probe.videoCodec = codecName(stream["codec_name"] as? String)
                probe.width = stream["width"] as? Int
                probe.height = stream["height"] as? Int
                if let rate = stream["avg_frame_rate"] as? String ?? stream["r_frame_rate"] as? String {
                    let parts = rate.split(separator: "/").compactMap { Double($0) }
                    if parts.count == 2, parts[1] > 0, parts[0] > 0 { probe.frameRate = parts[0] / parts[1] }
                }
                probe.videoBitrate = number(stream["bit_rate"])
                if probe.duration == nil { probe.duration = number(stream["duration"]) }
            case "audio" where probe.audioCodec == nil:
                probe.audioCodec = codecName(stream["codec_name"] as? String)
                probe.sampleRate = number(stream["sample_rate"])
                probe.channels = stream["channels"] as? Int
                probe.audioBitrate = number(stream["bit_rate"])
            default:
                break
            }
        }
        // MKV often only states the overall rate; what isn't audio is (nearly all) video.
        if probe.videoBitrate == nil, let total = number(format["bit_rate"]) {
            probe.videoBitrate = total - (probe.audioBitrate ?? 0)
        }
        return probe
    }

    private static func codecName(_ name: String?) -> String? {
        guard let name else { return nil }
        let names = ["h264": "H.264", "hevc": "HEVC", "av1": "AV1", "vp9": "VP9", "vp8": "VP8", "mpeg4": "MPEG-4",
                     "aac": "AAC", "opus": "Opus", "vorbis": "Vorbis", "mp3": "MP3", "flac": "FLAC", "ac3": "AC-3",
                     "eac3": "E-AC-3", "pcm_s16le": "PCM", "prores": "ProRes"]
        return names[name] ?? name.uppercased()
    }

    // MARK: Playing

    /// A copy of the video macOS can play: its streams re-wrapped into MP4 (no re-encoding),
    /// kept in Caches until the file changes. Nil when its codecs can't go in an MP4.
    static func playableCopy(of url: URL, modified: Date?) async -> URL? {
        guard let ffmpeg else { return nil }
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TheExplorer/Playable", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let version = "\(url.path)|\(modified?.timeIntervalSinceReferenceDate ?? 0)"
        let name = SHA256.hash(data: Data(version.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        let copy = folder.appendingPathComponent(name + ".mp4")
        if FileManager.default.fileExists(atPath: copy.path) { return copy }
        trimCache(folder)
        let partial = folder.appendingPathComponent(name + ".partial.mp4")
        try? FileManager.default.removeItem(at: partial)
        let arguments = ["-nostdin", "-loglevel", "error", "-y", "-i", url.path, "-map", "0:v:0?", "-map", "0:a:0?",
                         "-c", "copy", "-movflags", "+faststart", partial.path]
        guard await run(ffmpeg, arguments) != nil, !Task.isCancelled else {
            try? FileManager.default.removeItem(at: partial)
            return nil
        }
        // Copying isn't enough if the codecs aren't ones macOS plays (VP9 in WebM, say).
        guard (try? await AVURLAsset(url: partial).load(.isPlayable)) == true else {
            try? FileManager.default.removeItem(at: partial)
            return nil
        }
        try? FileManager.default.moveItem(at: partial, to: copy)
        return copy
    }

    /// Keeps the playable copies under a few gigabytes, oldest out first.
    private static func trimCache(_ folder: URL, limit: Int64 = 4_000_000_000) {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentAccessDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys)) else { return }
        var entries = files.compactMap { url -> (URL, Int64, Date)? in
            guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
            return (url, Int64(values.fileSize ?? 0), values.contentAccessDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.1 }
        entries.sort { $0.2 < $1.2 }
        for (url, size, _) in entries where total > limit {
            try? FileManager.default.removeItem(at: url)
            total -= size
        }
    }
}
