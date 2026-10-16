import AVFoundation
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What a file holds, read from the file itself: an image's pixel size, a video's length,
/// resolution and codec, a PDF's pages, a playlist's segments…
struct MediaInfo: Sendable, Equatable {
    struct Row: Sendable, Equatable, Hashable {
        let label: String
        let value: String
    }

    /// The headline, shown under the name: "1920 × 1080 · 0:42".
    var summary: String?
    var rows: [Row] = []

    var isEmpty: Bool { summary == nil && rows.isEmpty }
}

enum MediaInfoReader {
    private static let cache = Cache()

    /// Details for `url`, cached until the file changes. Nil for kinds with nothing to add.
    static func read(_ url: URL, type: UTType?, modified: Date?) async -> MediaInfo? {
        let key = "\(url.path)|\(modified?.timeIntervalSinceReferenceDate ?? 0)"
        if let cached = await cache.value(for: key) { return cached }
        let info = await load(url, type: type)
        await cache.store(info, for: key)
        return info
    }

    private static func load(_ url: URL, type: UTType?) async -> MediaInfo? {
        let ext = url.pathExtension.lowercased()
        guard let type = type ?? UTType(filenameExtension: ext) else { return nil }
        if ext == "m3u8" { return playlist(url) }
        if type.conforms(to: .svg) { return svg(url) }
        if type.conforms(to: .image) { return image(url) }
        if type.conforms(to: .audiovisualContent) || type.conforms(to: .movie) || type.conforms(to: .audio) {
            return await media(url)
        }
        if type.conforms(to: .pdf) { return pdf(url) }
        if type.conforms(to: .font) { return font(url) }
        if type.conforms(to: .text) || type.conforms(to: .sourceCode) || type.conforms(to: .json) { return text(url) }
        return nil
    }

    // MARK: Images

    static func image(_ url: URL) -> MediaInfo? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        var info = MediaInfo()
        var width = properties[kCGImagePropertyPixelWidth] as? Int
        var height = properties[kCGImagePropertyPixelHeight] as? Int
        // Photos taken sideways are stored sideways; show the size as it appears.
        if let orientation = properties[kCGImagePropertyOrientation] as? Int, (5...8).contains(orientation) {
            swap(&width, &height)
        }
        if let width, let height {
            info.summary = "\(width) × \(height)"
            info.rows.append(.init(label: "dimensions", value: "\(width) × \(height) px"))
            if let ratio = aspectRatio(width, height) { info.rows.append(.init(label: "aspect", value: ratio)) }
            let megapixels = Double(width * height) / 1_000_000
            if megapixels >= 1 { info.rows.append(.init(label: "resolution", value: String(format: "%.1f MP", megapixels))) }
        }
        if let dpi = properties[kCGImagePropertyDPIWidth] as? Double, dpi > 0, Int(dpi.rounded()) != 72 {
            info.rows.append(.init(label: "density", value: "\(Int(dpi.rounded())) dpi"))
        }
        var color: [String] = []
        if let model = properties[kCGImagePropertyColorModel] as? String { color.append(model) }
        if let profile = properties[kCGImagePropertyProfileName] as? String { color.append(profile) }
        if !color.isEmpty { info.rows.append(.init(label: "color", value: color.joined(separator: " · "))) }
        if let depth = properties[kCGImagePropertyDepth] as? Int { info.rows.append(.init(label: "bit depth", value: "\(depth)-bit")) }
        if properties[kCGImagePropertyHasAlpha] as? Bool == true { info.rows.append(.init(label: "alpha", value: "yes")) }

        let frames = CGImageSourceGetCount(source)
        if frames > 1 {
            var value = "\(frames) frames"
            if let duration = animationDuration(source, frames: frames) {
                value += " · " + Format.duration(duration, precise: true)
                info.summary = (info.summary.map { $0 + " · " } ?? "") + Format.duration(duration, precise: true)
            }
            info.rows.append(.init(label: "animation", value: value))
        }

        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        if let model = tiff?[kCGImagePropertyTIFFModel] as? String {
            let make = (tiff?[kCGImagePropertyTIFFMake] as? String).map { $0 + " " } ?? ""
            info.rows.append(.init(label: "camera", value: model.hasPrefix(make.trimmingCharacters(in: .whitespaces)) ? model : make + model))
        }
        if let lens = exif?[kCGImagePropertyExifLensModel] as? String { info.rows.append(.init(label: "lens", value: lens)) }
        var exposure: [String] = []
        if let time = exif?[kCGImagePropertyExifExposureTime] as? Double, time > 0 {
            exposure.append(time < 1 ? "1/\(Int((1 / time).rounded()))s" : String(format: "%.1fs", time))
        }
        if let f = exif?[kCGImagePropertyExifFNumber] as? Double { exposure.append(String(format: "f/%.1f", f)) }
        if let iso = (exif?[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first { exposure.append("ISO \(iso)") }
        if let focal = exif?[kCGImagePropertyExifFocalLength] as? Double { exposure.append("\(Int(focal.rounded()))mm") }
        if !exposure.isEmpty { info.rows.append(.init(label: "exposure", value: exposure.joined(separator: " "))) }
        if let taken = exif?[kCGImagePropertyExifDateTimeOriginal] as? String {
            info.rows.append(.init(label: "taken", value: taken.replacingOccurrences(of: ":", with: "-", options: [], range: taken.startIndex..<(taken.index(taken.startIndex, offsetBy: 10, limitedBy: taken.endIndex) ?? taken.endIndex))))
        }
        return info.isEmpty ? nil : info
    }

    private static func animationDuration(_ source: CGImageSource, frames: Int) -> Double? {
        let containers: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
            (kCGImagePropertyHEICSDictionary, kCGImagePropertyHEICSUnclampedDelayTime, kCGImagePropertyHEICSDelayTime),
        ]
        var total = 0.0
        for index in 0..<min(frames, 2000) {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else { continue }
            for (container, unclamped, clamped) in containers {
                if let frame = properties[container] as? [CFString: Any] {
                    total += (frame[unclamped] as? Double) ?? (frame[clamped] as? Double) ?? 0
                    break
                }
            }
        }
        return total > 0 ? total : nil
    }

    /// "16:9" for common shapes; nil for odd ones, where it says nothing useful.
    static func aspectRatio(_ width: Int, _ height: Int) -> String? {
        guard width > 0, height > 0 else { return nil }
        let ratio = Double(width) / Double(height)
        let common: [(String, Double)] = [("1:1", 1), ("16:9", 16 / 9), ("9:16", 9 / 16), ("4:3", 4 / 3), ("3:4", 3 / 4),
                                          ("3:2", 1.5), ("2:3", 2 / 3), ("21:9", 21 / 9), ("16:10", 1.6), ("10:16", 0.625),
                                          ("4:5", 0.8), ("5:4", 1.25), ("2:1", 2), ("1:2", 0.5)]
        return common.first { abs($0.1 - ratio) / $0.1 < 0.01 }?.0
    }

    static func svg(_ url: URL) -> MediaInfo? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let head = String(decoding: (try? handle.read(upToCount: 8192)) ?? Data(), as: UTF8.self)
        guard let tag = head.range(of: "<svg").map({ head[$0.lowerBound...] }),
              let end = tag.firstIndex(of: ">") else { return nil }
        let attributes = String(tag[..<end])
        func attribute(_ name: String) -> String? {
            guard let range = attributes.range(of: #"\s\#(name)\s*=\s*["']([^"']*)["']"#, options: .regularExpression) else { return nil }
            let match = String(attributes[range])
            guard let open = match.firstIndex(where: { $0 == "\"" || $0 == "'" }) else { return nil }
            return String(match[match.index(after: open)...].dropLast())
        }
        var info = MediaInfo()
        let viewBox = attribute("viewBox")?.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
        let width = attribute("width").flatMap(points) ?? viewBox.flatMap { $0.count == 4 ? $0[2] : nil }
        let height = attribute("height").flatMap(points) ?? viewBox.flatMap { $0.count == 4 ? $0[3] : nil }
        if let width, let height {
            let size = "\(clean(width)) × \(clean(height))"
            info.summary = size
            info.rows.append(.init(label: "size", value: size))
            if let ratio = aspectRatio(Int(width.rounded()), Int(height.rounded())) { info.rows.append(.init(label: "aspect", value: ratio)) }
        }
        if let viewBox, viewBox.count == 4 {
            info.rows.append(.init(label: "viewBox", value: viewBox.map(clean).joined(separator: " ")))
        }
        return info.isEmpty ? nil : info
    }

    /// "24", "24px", "24pt" → 24; percentages and other units say nothing about size.
    private static func points(_ value: String) -> Double? {
        let number = value.trimmingCharacters(in: .whitespaces)
        if number.hasSuffix("%") || number.hasSuffix("em") { return nil }
        return Double(number.trimmingCharacters(in: CharacterSet.letters))
    }

    private static func clean(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }

    // MARK: Video and audio

    static func media(_ url: URL) async -> MediaInfo? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return nil }
        var info = MediaInfo()
        var summary: [String] = []
        let seconds = duration.seconds
        if seconds.isFinite && seconds > 0 {
            summary.append(Format.duration(seconds))
            info.rows.append(.init(label: "duration", value: Format.duration(seconds, precise: true)))
        }

        if let video = try? await asset.loadTracks(withMediaType: .video).first {
            if let (size, transform) = try? await video.load(.naturalSize, .preferredTransform) {
                let shown = size.applying(transform)
                let width = Int(abs(shown.width).rounded())
                let height = Int(abs(shown.height).rounded())
                summary.insert("\(width) × \(height)", at: 0)
                var value = "\(width) × \(height)"
                if let ratio = aspectRatio(width, height) { value += " (\(ratio))" }
                info.rows.append(.init(label: "resolution", value: value))
            }
            if let rate = try? await video.load(.nominalFrameRate), rate > 0 {
                info.rows.append(.init(label: "frame rate", value: rate.rounded() == rate ? "\(Int(rate)) fps" : String(format: "%.2f fps", rate)))
            }
            if let format = try? await video.load(.formatDescriptions).first {
                var codec = codecName(CMFormatDescriptionGetMediaSubType(format))
                if let extensions = CMFormatDescriptionGetExtensions(format) as? [CFString: Any],
                   let transfer = extensions[kCMFormatDescriptionExtension_TransferFunction] as? String,
                   transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
                    || transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String) {
                    codec += " · HDR"
                }
                info.rows.append(.init(label: "video", value: codec))
            }
            if let rate = try? await video.load(.estimatedDataRate), rate > 0 {
                info.rows.append(.init(label: "video bitrate", value: Format.bitrate(Double(rate))))
            }
        }

        if let audio = try? await asset.loadTracks(withMediaType: .audio).first,
           let format = try? await audio.load(.formatDescriptions).first {
            var parts = [codecName(CMFormatDescriptionGetMediaSubType(format))]
            if let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
                if description.mSampleRate > 0 {
                    let khz = description.mSampleRate / 1000
                    parts.append(khz.rounded() == khz ? "\(Int(khz)) kHz" : String(format: "%.1f kHz", khz))
                }
                switch description.mChannelsPerFrame {
                case 0: break
                case 1: parts.append("mono")
                case 2: parts.append("stereo")
                case let channels: parts.append("\(channels) channels")
                }
            }
            info.rows.append(.init(label: "audio", value: parts.joined(separator: " · ")))
            if let rate = try? await audio.load(.estimatedDataRate), rate > 0 {
                info.rows.append(.init(label: "audio bitrate", value: Format.bitrate(Double(rate))))
            }
        }

        if let metadata = try? await asset.load(.commonMetadata) {
            for (key, label) in [(AVMetadataKey.commonKeyTitle, "title"), (.commonKeyArtist, "artist"), (.commonKeyAlbumName, "album")] {
                if let item = AVMetadataItem.metadataItems(from: metadata, withKey: key, keySpace: .common).first,
                   let value = try? await item.load(.stringValue), !value.isEmpty {
                    info.rows.append(.init(label: label, value: value))
                }
            }
        }
        info.summary = summary.isEmpty ? nil : summary.joined(separator: " · ")
        return info.isEmpty ? nil : info
    }

    static func codecName(_ code: FourCharCode) -> String {
        let names: [String: String] = [
            "avc1": "H.264", "avc3": "H.264", "hvc1": "HEVC", "hev1": "HEVC", "av01": "AV1", "vp09": "VP9", "vp08": "VP8",
            "ap4h": "ProRes 4444", "ap4x": "ProRes 4444 XQ", "apch": "ProRes 422 HQ", "apcn": "ProRes 422",
            "apcs": "ProRes 422 LT", "apco": "ProRes 422 Proxy", "aprn": "ProRes RAW", "mp4v": "MPEG-4", "jpeg": "Motion JPEG",
            "mp4a": "AAC", "aac ": "AAC", "aach": "HE-AAC", "lpcm": "PCM", "sowt": "PCM", "twos": "PCM", "alac": "Apple Lossless",
            ".mp3": "MP3", "ac-3": "Dolby Digital", "ec-3": "Dolby Digital Plus", "opus": "Opus", "fLaC": "FLAC",
        ]
        let text = String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }, encoding: .macOSRoman) ?? "?"
        return names[text] ?? text.trimmingCharacters(in: .whitespaces).uppercased()
    }

    // MARK: HLS playlists

    /// An HLS playlist: total length and segments, or the variants of a master playlist.
    static func playlist(_ url: URL) -> MediaInfo? {
        guard let text = try? String(contentsOf: url, encoding: .utf8), text.hasPrefix("#EXTM3U") else { return nil }
        var info = MediaInfo()
        var duration = 0.0
        var segments = 0
        var variants: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("#EXTINF:") {
                segments += 1
                duration += Double(line.dropFirst(8).prefix { $0 != "," }) ?? 0
            } else if line.hasPrefix("#EXT-X-STREAM-INF:") {
                let resolution = line.range(of: #"RESOLUTION=\d+x\d+"#, options: .regularExpression).map { String(line[$0].dropFirst(11)) }
                let bandwidth = line.range(of: #"BANDWIDTH=\d+"#, options: .regularExpression).flatMap { Double(line[$0].dropFirst(10)) }
                variants.append([resolution?.replacingOccurrences(of: "x", with: " × "), bandwidth.map(Format.bitrate)]
                    .compactMap { $0 }.joined(separator: " · "))
            }
        }
        if !variants.isEmpty {
            info.summary = "\(variants.count) variants"
            for (index, variant) in variants.enumerated() {
                info.rows.append(.init(label: "variant \(index + 1)", value: variant.isEmpty ? "–" : variant))
            }
        } else if segments > 0 {
            info.summary = Format.duration(duration)
            info.rows.append(.init(label: "duration", value: Format.duration(duration, precise: true)))
            info.rows.append(.init(label: "segments", value: "\(segments) · ~" + Format.duration(duration / Double(segments), precise: true) + " each"))
        }
        return info.isEmpty ? nil : info
    }

    // MARK: Documents

    static func pdf(_ url: URL) -> MediaInfo? {
        guard let document = CGPDFDocument(url as CFURL) else { return nil }
        var info = MediaInfo()
        let pages = document.numberOfPages
        info.summary = pages == 1 ? "1 page" : "\(pages) pages"
        if let page = document.page(at: 1) {
            let box = page.getBoxRect(.mediaBox)
            let rotated = page.rotationAngle % 180 != 0
            let size = rotated ? CGSize(width: box.height, height: box.width) : box.size
            info.rows.append(.init(label: "page size", value: paperName(size) ?? String(format: "%.1f × %.1f in", size.width / 72, size.height / 72)))
        }
        if document.isEncrypted { info.rows.append(.init(label: "encrypted", value: document.isUnlocked ? "yes" : "locked")) }
        return info
    }

    private static func paperName(_ size: CGSize) -> String? {
        let papers: [(String, CGSize)] = [("Letter", CGSize(width: 612, height: 792)), ("Legal", CGSize(width: 612, height: 1008)),
                                          ("A4", CGSize(width: 595, height: 842)), ("A3", CGSize(width: 842, height: 1191)),
                                          ("A5", CGSize(width: 420, height: 595)), ("Tabloid", CGSize(width: 792, height: 1224))]
        for (name, paper) in papers {
            if abs(size.width - paper.width) < 3 && abs(size.height - paper.height) < 3 { return name }
            if abs(size.width - paper.height) < 3 && abs(size.height - paper.width) < 3 { return name + " landscape" }
        }
        return nil
    }

    static func font(_ url: URL) -> MediaInfo? {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor], !descriptors.isEmpty else { return nil }
        let families = Set(descriptors.compactMap { CTFontDescriptorCopyAttribute($0, kCTFontFamilyNameAttribute) as? String })
        let styles = descriptors.compactMap { CTFontDescriptorCopyAttribute($0, kCTFontStyleNameAttribute) as? String }
        var info = MediaInfo()
        info.summary = families.sorted().joined(separator: ", ")
        info.rows.append(.init(label: "family", value: families.sorted().joined(separator: ", ")))
        if !styles.isEmpty {
            info.rows.append(.init(label: styles.count == 1 ? "style" : "\(styles.count) styles", value: styles.prefix(6).joined(separator: ", ") + (styles.count > 6 ? "…" : "")))
        }
        return info
    }

    /// Line count for text up to a few MB (counting is a fast byte scan).
    static func text(_ url: URL) -> MediaInfo? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count <= 20_000_000 else { return nil }
        guard !data.prefix(8192).contains(0) else { return nil }
        var lines = data.reduce(into: 0) { count, byte in if byte == 0x0A { count += 1 } }
        if let last = data.last, last != 0x0A { lines += 1 }
        var info = MediaInfo()
        info.summary = lines == 1 ? "1 line" : "\(lines.formatted()) lines"
        return info
    }

    private actor Cache {
        private var values: [String: MediaInfo?] = [:]
        private var order: [String] = []

        func value(for key: String) -> MediaInfo?? { values[key] }

        func store(_ info: MediaInfo?, for key: String) {
            if values.updateValue(info, forKey: key) == nil { order.append(key) }
            if order.count > 500 { values[order.removeFirst()] = nil }
        }
    }
}
