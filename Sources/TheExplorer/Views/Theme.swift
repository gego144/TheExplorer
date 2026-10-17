import SwiftUI
import UniformTypeIdentifiers

/// The Workbench look: dense dark surfaces, a light action color, monospaced numbers, and color
/// kept for meaning (types, sizes). The colors come from the theme picked in Settings ›
/// General; the default is Jestr's (main-website globals.css).
///
/// The tokens read a plain stored palette rather than observing Prefs, so drawing a list row
/// costs nothing extra. Changing the theme rebuilds the windows instead (see Prefs.themeRevision).
enum Theme {
    nonisolated(unsafe) private(set) static var colors = ThemePalette.dark

    /// Switches every color at once; windows redraw when Prefs bumps its theme revision.
    static func apply(_ palette: ThemePalette) {
        colors = palette
        TypeChip.clearCache()
    }

    static var colorScheme: ColorScheme { colors.isDark ? .dark : .light }

    static var background: Color { colors.background }
    static var surface: Color { colors.surface }
    static var raised: Color { colors.raised }
    static var field: Color { colors.field }
    static var border: Color { colors.border }
    static var fieldBorder: Color { colors.fieldBorder }
    static var hover: Color { colors.hover }

    static var text: Color { colors.text }
    static var textSecondary: Color { colors.textSecondary }
    static var textTertiary: Color { colors.textTertiary }
    /// Running text in previews, a little softer than headings.
    static var body: Color { colors.body }

    static var accent: Color { colors.accent }
    static var accentSoft: Color { colors.accentSoft }
    static var accentStrong: Color { colors.accentStrong }
    static var warning: Color { colors.warning }
    static var danger: Color { colors.danger }
    static var hot: Color { colors.hot }

    /// Hues for meaning: file types, git status, JSON values.
    static var blue: Color { colors.blue }
    static var purple: Color { colors.purple }
    static var pink: Color { colors.pink }
    static var green: Color { colors.green }
    static var cyan: Color { colors.cyan }
    static var cream: Color { colors.cream }

    /// How dark the window gets behind the large preview.
    static var scrim: Color { .black.opacity(colors.isDark ? 0.55 : 0.28) }

    /// Size heat: light for small, yellow for big, orange for the heaviest things in view.
    static func heatColor(_ fraction: Double) -> Color {
        fraction < 0.25 ? accent : (fraction < 0.6 ? warning : hot)
    }

    /// Stable colors for pinned items and treemap tiles.
    static var palette: [Color] { [blue, warning, purple, danger, green, hot, pink, cyan] }

    static func paletteColor(for key: String) -> Color {
        var hash: UInt64 = 5381
        for byte in key.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        switch hash % 8 {
        case 0: return blue
        case 1: return warning
        case 2: return purple
        case 3: return danger
        case 4: return green
        case 5: return hot
        case 6: return pink
        default: return cyan
        }
    }

    static let mono = Font.system(size: 11, design: .monospaced)
    static let monoSmall = Font.system(size: 10, design: .monospaced)
    static let label = Font.system(size: 12.5)
    static let caption = Font.system(size: 10, weight: .semibold)
}

/// Every color the app draws with, for one theme.
struct ThemePalette: Equatable {
    var isDark: Bool
    var background, surface, raised, field, border, fieldBorder, hover: Color
    var text, textSecondary, textTertiary, body: Color
    var accent, accentSoft, accentStrong: Color
    var hoverFill, raisedHover, pressedFill, borderHover: Color
    var warning, danger, hot, blue, purple, pink, green, cyan, cream: Color

    /// Jestr's near-black neutrals, white as the action color.
    static let dark = ThemePalette(
        isDark: true,
        background: Color(hex: 0x0E0E0E), surface: Color(hex: 0x1A1A1A), raised: Color(hex: 0x222222),
        field: Color(hex: 0x080808), border: Color(hex: 0x2E2E2E), fieldBorder: Color(hex: 0x373737), hover: Color(hex: 0x1C1C1C),
        text: Color(hex: 0xFFFFFF), textSecondary: Color(hex: 0x999999), textTertiary: Color(hex: 0x696969), body: Color(hex: 0xD6D6D6),
        accent: Color(hex: 0xE7E7E7), accentSoft: Color(hex: 0x2E2E2E), accentStrong: Color(hex: 0x545454),
        hoverFill: Color(hex: 0x1F1F1F), raisedHover: Color(hex: 0x2B2B2B), pressedFill: Color(hex: 0x333333), borderHover: Color(hex: 0x474747),
        warning: Color(hex: 0xE3C37D), danger: Color(hex: 0xE27676), hot: Color(hex: 0xE08240),
        blue: Color(hex: 0x6EB8FF), purple: Color(hex: 0xC9BBFF), pink: Color(hex: 0xE35F9F),
        green: Color(hex: 0x54D3A0), cyan: Color(hex: 0x90E3FF), cream: Color(hex: 0xFFCB83)
    )

    /// Softer charcoal greys, for less contrast than near-black.
    static let graphite = ThemePalette(
        isDark: true,
        background: Color(hex: 0x1C1C1E), surface: Color(hex: 0x262628), raised: Color(hex: 0x2F2F32),
        field: Color(hex: 0x151517), border: Color(hex: 0x38383B), fieldBorder: Color(hex: 0x424246), hover: Color(hex: 0x28282A),
        text: Color(hex: 0xF4F4F5), textSecondary: Color(hex: 0xA3A3A8), textTertiary: Color(hex: 0x76767B), body: Color(hex: 0xDADADC),
        accent: Color(hex: 0xEDEDEE), accentSoft: Color(hex: 0x3B3B3F), accentStrong: Color(hex: 0x5E5E63),
        hoverFill: Color(hex: 0x2A2A2D), raisedHover: Color(hex: 0x38383C), pressedFill: Color(hex: 0x404044), borderHover: Color(hex: 0x535358),
        warning: Color(hex: 0xE3C37D), danger: Color(hex: 0xE27676), hot: Color(hex: 0xE08240),
        blue: Color(hex: 0x6EB8FF), purple: Color(hex: 0xC9BBFF), pink: Color(hex: 0xE35F9F),
        green: Color(hex: 0x54D3A0), cyan: Color(hex: 0x90E3FF), cream: Color(hex: 0xFFCB83)
    )

    /// Deep navy, with cool blue-grey text.
    static let midnight = ThemePalette(
        isDark: true,
        background: Color(hex: 0x0B0E14), surface: Color(hex: 0x141924), raised: Color(hex: 0x1B2130),
        field: Color(hex: 0x070A0F), border: Color(hex: 0x232A3A), fieldBorder: Color(hex: 0x2C3446), hover: Color(hex: 0x171C27),
        text: Color(hex: 0xEEF2F9), textSecondary: Color(hex: 0x8F99AE), textTertiary: Color(hex: 0x616B82), body: Color(hex: 0xCDD4E2),
        accent: Color(hex: 0xDCE4F2), accentSoft: Color(hex: 0x242C3F), accentStrong: Color(hex: 0x4B5772),
        hoverFill: Color(hex: 0x181E2B), raisedHover: Color(hex: 0x232A3B), pressedFill: Color(hex: 0x2B3346), borderHover: Color(hex: 0x3D475E),
        warning: Color(hex: 0xE6C887), danger: Color(hex: 0xEB7F86), hot: Color(hex: 0xEC9150),
        blue: Color(hex: 0x7CBDFF), purple: Color(hex: 0xC4B8FF), pink: Color(hex: 0xEA6FAA),
        green: Color(hex: 0x5CD8A8), cyan: Color(hex: 0x8FDDF7), cream: Color(hex: 0xFFD08F)
    )

    /// Light greys and white cards, near-black as the action color, and deeper hues so they
    /// read on white.
    static let light = ThemePalette(
        isDark: false,
        background: Color(hex: 0xF5F5F4), surface: Color(hex: 0xFFFFFF), raised: Color(hex: 0xEAEAE8),
        field: Color(hex: 0xFFFFFF), border: Color(hex: 0xE1E1DF), fieldBorder: Color(hex: 0xD3D3D1), hover: Color(hex: 0xEDEDEC),
        text: Color(hex: 0x141414), textSecondary: Color(hex: 0x5C5C5C), textTertiary: Color(hex: 0x8C8C8C), body: Color(hex: 0x2B2B2B),
        accent: Color(hex: 0x1C1C1C), accentSoft: Color(hex: 0xE3E3E1), accentStrong: Color(hex: 0xB5B5B3),
        hoverFill: Color(hex: 0xEBEBEA), raisedHover: Color(hex: 0xDFDFDD), pressedFill: Color(hex: 0xD5D5D3), borderHover: Color(hex: 0xC2C2C0),
        warning: Color(hex: 0xA97B12), danger: Color(hex: 0xC64545), hot: Color(hex: 0xC4601A),
        blue: Color(hex: 0x2C78C9), purple: Color(hex: 0x7059CF), pink: Color(hex: 0xBE3B7B),
        green: Color(hex: 0x23926A), cyan: Color(hex: 0x1F8FB0), cream: Color(hex: 0xA8701A)
    )
}

/// The theme setting. System follows macOS: Dark in dark mode, Light in light mode.
enum ThemeChoice: String, CaseIterable, Identifiable {
    case system, dark, graphite, midnight, light

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .dark: "Dark"
        case .graphite: "Graphite"
        case .midnight: "Midnight"
        case .light: "Light"
        }
    }

    func palette(systemIsDark: Bool) -> ThemePalette {
        switch self {
        case .system: systemIsDark ? .dark : .light
        case .dark: .dark
        case .graphite: .graphite
        case .midnight: .midnight
        case .light: .light
        }
    }
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

    /// Colors depend on the theme, so a new theme starts a new cache.
    static func clearCache() { styleCache = [:] }

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
        // Google Docs, Sheets and Slides from Drive, which have no extension of their own.
        if let mime = type.preferredMIMEType, mime.hasPrefix(DriveFile.googlePrefix) {
            switch mime.dropFirst(DriveFile.googlePrefix.count) {
            case "document": return ("DOC", Theme.blue)
            case "spreadsheet": return ("SHEET", Theme.green)
            case "presentation": return ("SLIDE", Theme.warning)
            case "form": return ("FORM", Theme.purple)
            case "drawing": return ("DRAW", Theme.pink)
            default: return ("GOOGLE", Theme.textSecondary)
            }
        }
        if type.conforms(to: .application) || type.conforms(to: .applicationBundle) { return ("APP", Theme.green) }
        // .ts is TypeScript far more often than an MPEG stream.
        if ["ts", "mts", "cts"].contains(ext) { return (label, Theme.warning) }
        if type.conforms(to: .image) { return (label, Theme.purple) }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return (label, Theme.pink) }
        if type.conforms(to: .audio) { return (label, Theme.hot) }
        if type.conforms(to: .pdf) { return (label, Theme.danger) }
        if type.conforms(to: .archive) || type.conforms(to: .diskImage) { return (label, Theme.cream) }
        if type.conforms(to: .sourceCode) || type.conforms(to: .script) || type.conforms(to: .json)
            || ["yml", "yaml", "toml", "lock", "xml", "plist"].contains(ext) { return (label, Theme.warning) }
        if type.conforms(to: .text) || type.conforms(to: .presentation) || type.conforms(to: .spreadsheet) {
            return (label, Theme.blue)
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
