import SwiftUI
import UniformTypeIdentifiers

/// The Workbench look in Jestr's colors (main-website globals.css): near-black surfaces,
/// white as the action color, monospaced numbers. Color is kept for meaning (types, sizes).
enum Theme {
    static let background = Color(hex: 0x0E0E0E)   // main-background
    static let surface = Color(hex: 0x1A1A1A)      // section
    static let raised = Color(hex: 0x222222)       // sidebar-item-active
    static let field = Color(hex: 0x080808)        // default-background
    static let border = Color(hex: 0x2E2E2E)       // border-subtle
    static let fieldBorder = Color(hex: 0x373737)  // border-subtle-light
    static let hover = Color(hex: 0x1C1C1C)        // calendar-weekend-hover

    static let text = Color(hex: 0xFFFFFF)          // text-primary
    static let textSecondary = Color(hex: 0x999999) // text-muted
    static let textTertiary = Color(hex: 0x696969)  // social-icon

    static let accent = Color(hex: 0xE7E7E7)        // primary / offwhite
    static let accentSoft = Color(hex: 0x2E2E2E)    // section-active
    static let accentStrong = Color(hex: 0x545454)  // border-emphasis
    static let warning = Color(hex: 0xE3C37D)       // yellow
    static let danger = Color(hex: 0xE27676)        // content-red

    static let hot = Color(hex: 0xE08240)           // content-orange

    /// Size heat: light for small, yellow for big, orange for the heaviest things in view.
    static func heatColor(_ fraction: Double) -> Color {
        fraction < 0.25 ? accent : (fraction < 0.6 ? warning : hot)
    }

    /// Stable colors for pinned items and treemap tiles.
    static let palette: [Color] = [
        Color(hex: 0x6EB8FF), warning, Color(hex: 0xC9BBFF), danger, Color(hex: 0x54D3A0),
        hot, Color(hex: 0xE35F9F), Color(hex: 0x90E3FF),
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
        if type.conforms(to: .application) || type.conforms(to: .applicationBundle) { return ("APP", Color(hex: 0x54D3A0)) }
        // .ts is TypeScript far more often than an MPEG stream.
        if ["ts", "mts", "cts"].contains(ext) { return (label, Theme.warning) }
        if type.conforms(to: .image) { return (label, Color(hex: 0xC9BBFF)) }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return (label, Color(hex: 0xE35F9F)) }
        if type.conforms(to: .audio) { return (label, Theme.hot) }
        if type.conforms(to: .pdf) { return (label, Theme.danger) }
        if type.conforms(to: .archive) || type.conforms(to: .diskImage) { return (label, Color(hex: 0xFFCB83)) }
        if type.conforms(to: .sourceCode) || type.conforms(to: .script) || type.conforms(to: .json)
            || ["yml", "yaml", "toml", "lock", "xml", "plist"].contains(ext) { return (label, Theme.warning) }
        if type.conforms(to: .text) || type.conforms(to: .presentation) || type.conforms(to: .spreadsheet) {
            return (label, Color(hex: 0x6EB8FF))
        }
        return (label, Theme.textSecondary)
    }
}

// MARK: - Controls

/// Small square icon button used in bars.
struct IconButton: View {
    let systemImage: String
    var help: String = ""
    var isOn = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
        }
        .buttonStyle(IconButtonStyle(isOn: isOn))
        .help(help)
    }
}

/// Compact segmented control: a recessed track with the chosen option raised.
struct Segmented<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, title in
                Button {
                    selection = value
                } label: {
                    Text(title)
                }
                .buttonStyle(SegmentStyle(isSelected: selection == value))
            }
        }
        .padding(2)
        .background(Theme.field, in: .rect(cornerRadius: Theme.controlRadius + 1))
        .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius + 1).strokeBorder(Theme.fieldBorder))
    }

    private struct SegmentStyle: ButtonStyle {
        let isSelected: Bool

        func makeBody(configuration: Configuration) -> some View {
            Hovering { hovering in
                configuration.label
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8)
                    .frame(height: Theme.smallControlHeight - 4)
                    .foregroundStyle(isSelected || hovering ? Theme.text : Theme.textSecondary)
                    .background(isSelected ? Theme.raisedHover : (hovering ? Theme.raised : .clear),
                                in: .rect(cornerRadius: Theme.controlRadius - 1))
                    .clickable(!isSelected)
            }
        }
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
    var track: Color = Theme.border
    /// Leaves out fills too small to read (in dense lists they'd just be dots).
    var hidesTiny = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                if !(hidesTiny && fraction < 0.04) {
                    Capsule()
                        .fill(color ?? Theme.heatColor(fraction))
                        .frame(width: max(fraction > 0 ? height : 0, proxy.size.width * min(1, fraction)))
                }
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
