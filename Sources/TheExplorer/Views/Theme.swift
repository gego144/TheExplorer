import SwiftUI
import UniformTypeIdentifiers

/// The Workbench look: graphite surfaces, one mint accent, monospaced numbers.
enum Theme {
    static let background = Color(hex: 0x0D0F12)
    static let surface = Color(hex: 0x161A20)
    static let raised = Color(hex: 0x1D222A)
    static let field = Color(hex: 0x0D0F12)
    static let border = Color(hex: 0x222831)
    static let fieldBorder = Color(hex: 0x2A313B)
    static let hover = Color(hex: 0x1A1F26)

    static let text = Color(hex: 0xEEF2F7)
    static let textSecondary = Color(hex: 0x9AA3B2)
    static let textTertiary = Color(hex: 0x5C6573)

    static let accent = Color(hex: 0x3DF5C0)
    static let accentSoft = Color(hex: 0x123B33)
    static let accentStrong = Color(hex: 0x1A5C4F)
    static let warning = Color(hex: 0xF5D63D)
    static let danger = Color(hex: 0xFF7A6B)

    static let hot = Color(hex: 0xF5603D)

    /// Size heat: mint for small, amber for big, coral for the heaviest things in view.
    static func heatColor(_ fraction: Double) -> Color {
        fraction < 0.25 ? accent : (fraction < 0.6 ? warning : hot)
    }

    /// Stable colors for pinned items and treemap tiles.
    static let palette: [Color] = [
        accent, warning, Color(hex: 0x9B7BFF), Color(hex: 0xFF7A6B), Color(hex: 0x5AB4FF),
        Color(hex: 0xF59E3D), Color(hex: 0xE76FD1), Color(hex: 0x7BD88F),
    ]

    static func paletteColor(for key: String) -> Color {
        var hash: UInt64 = 5381
        for byte in key.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return palette[Int(hash % UInt64(palette.count))]
    }

    static let mono = Font.system(size: 11, design: .monospaced)
    static let monoSmall = Font.system(size: 10, design: .monospaced)
    static let label = Font.system(size: 12.5)
    static let caption = Font.system(size: 10, weight: .semibold)
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

// MARK: - Type chips

/// Short colored label for what a thing is: DIR, PDF, SWIFT, PNG…
struct TypeChip: View {
    let item: FileItem

    var body: some View {
        let style = TypeChip.style(for: item)
        Text(style.label)
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .lineLimit(1)
            .foregroundStyle(style.color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .frame(minWidth: 34)
            .background(style.color.opacity(0.14), in: .rect(cornerRadius: 4))
            .help(item.kindDescription)
    }

    private static var styleCache: [String: (label: String, color: Color)] = [:]

    /// Memoized per type and extension: the UTType conformance checks are too slow to repeat
    /// for every row on every redraw or sort.
    static func style(for item: FileItem) -> (label: String, color: Color) {
        if item.isFolder { return ("DIR", Theme.accent) }
        let key = "\(item.isSymlink ? "l" : "")\(item.isPackage ? "p" : "")|\(item.contentType?.identifier ?? "")|\(item.fileExtension)"
        if let cached = styleCache[key] { return cached }
        let style = computeStyle(for: item)
        styleCache[key] = style
        return style
    }

    private static func computeStyle(for item: FileItem) -> (label: String, color: Color) {
        if item.isSymlink && item.contentType == nil { return ("LINK", Theme.textSecondary) }
        let ext = item.fileExtension
        let label = ext.isEmpty ? (item.isPackage ? "PKG" : "FILE") : String(ext.uppercased().prefix(5))
        guard let type = item.contentType else { return (label, Theme.textSecondary) }
        if type.conforms(to: .application) || type.conforms(to: .applicationBundle) { return ("APP", Color(hex: 0x7BD88F)) }
        if type.conforms(to: .image) { return (label, Color(hex: 0x9B7BFF)) }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return (label, Color(hex: 0xE76FD1)) }
        if type.conforms(to: .audio) { return (label, Color(hex: 0xF59E3D)) }
        if type.conforms(to: .pdf) { return (label, Theme.danger) }
        if type.conforms(to: .archive) || type.conforms(to: .diskImage) { return (label, Color(hex: 0xC9A27E)) }
        if type.conforms(to: .sourceCode) || type.conforms(to: .script) || type.conforms(to: .json)
            || ["yml", "yaml", "toml", "lock", "xml", "plist"].contains(ext) { return (label, Theme.warning) }
        if type.conforms(to: .text) || type.conforms(to: .presentation) || type.conforms(to: .spreadsheet) {
            return (label, Color(hex: 0x8EA2FF))
        }
        return (label, Theme.textSecondary)
    }
}

// MARK: - Controls

/// Small square icon button used in the command bar.
struct IconButton: View {
    let systemImage: String
    var help: String = ""
    var isOn = false
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 26)
                .foregroundStyle(isOn ? Theme.accent : (isEnabled ? Theme.textSecondary : Theme.textTertiary.opacity(0.6)))
                .background(isOn ? Theme.accentSoft : (hovering && isEnabled ? Theme.hover.opacity(1.6) : Theme.raised),
                            in: .rect(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Compact segmented control in the Workbench style.
struct Segmented<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.0) { value, title in
                Button {
                    selection = value
                } label: {
                    Text(title)
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .foregroundStyle(selection == value ? Theme.text : Theme.textSecondary)
                        .background(selection == value ? Theme.raised : .clear)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .background(Theme.field, in: .rect(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.fieldBorder))
        .clipShape(.rect(cornerRadius: 7))
    }
}

/// Uppercase section caption ("PINNED", "VIEWS"…).
struct SectionCaption: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(Theme.textTertiary)
    }
}

/// Thin horizontal bar showing a fraction, used for sizes and disk usage.
struct HeatBar: View {
    let fraction: Double
    var height: CGFloat = 4
    /// Fixed fill; when nil the fill follows the heat scale.
    var color: Color?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.border)
                Capsule()
                    .fill(color ?? Theme.heatColor(fraction))
                    .frame(width: max(fraction > 0 ? height : 0, proxy.size.width * min(1, fraction)))
            }
        }
        .frame(height: height)
    }
}

extension View {
    /// Rounded card surface used for the inspector and panels.
    func panel(padding: CGFloat = 12) -> some View {
        self
            .padding(padding)
            .background(Theme.surface, in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
    }
}

enum RelativeTime {
    /// "now", "5m", "3h", "2d", "3w", then "Jun 6" / "Jun 2024".
    static func short(_ date: Date?) -> String {
        guard let date else { return "—" }
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
        if seconds < 86_400 * 7 { return "\(Int(seconds / 86_400))d" }
        if seconds < 86_400 * 28 { return "\(Int(seconds / (86_400 * 7)))w" }
        let sameYear = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
        return sameYear ? date.formatted(.dateTime.month(.abbreviated).day()) : date.formatted(.dateTime.month(.abbreviated).year())
    }
}
