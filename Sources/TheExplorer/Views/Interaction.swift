import SwiftUI

// How everything clickable responds to the pointer, in one place: a pointing-hand cursor,
// a hover state one step lighter than the resting state, a pressed state, and a dimmed,
// unresponsive disabled state. Every button style and clickable row builds on these.

extension Theme {
    /// Hover fill on the window background (rows, sidebar items, ghost buttons).
    static let hoverFill = Color(hex: 0x1F1F1F)
    /// Hover fill on raised controls (buttons, chips).
    static let raisedHover = Color(hex: 0x2B2B2B)
    /// Pressed fill.
    static let pressedFill = Color(hex: 0x333333)
    /// Hover border on raised controls.
    static let borderHover = Color(hex: 0x474747)

    /// Corner radii: small chips, controls, fields and cards.
    static let chipRadius: CGFloat = 5
    static let controlRadius: CGFloat = 6
    static let fieldRadius: CGFloat = 8
    static let cardRadius: CGFloat = 10

    /// Standard heights for controls in bars and forms.
    static let controlHeight: CGFloat = 26
    static let smallControlHeight: CGFloat = 22

    static let hoverAnimation = Animation.easeOut(duration: 0.1)
}

/// Debug runs can draw everything as hovered (EXPLORER_HOVER_PREVIEW=1), to check hover
/// states in screenshots, since scripted runs can't move the real pointer.
enum HoverPreview {
    #if DEBUG
    static let on = ProcessInfo.processInfo.environment["EXPLORER_HOVER_PREVIEW"] != nil
    #else
    static let on = false
    #endif
}

extension View {
    /// The pointing-hand cursor over something clickable (none while it's disabled).
    func clickable(_ enabled: Bool = true) -> some View {
        pointerStyle(enabled ? .link : nil)
    }

    /// Calls `onChange` as the pointer enters and leaves, over the whole frame (not only the
    /// drawn parts, which is what made some hovers miss).
    func hoverTracking(_ onChange: @escaping (Bool) -> Void) -> some View {
        contentShape(.rect).onHover(perform: onChange)
    }
}

/// Supplies whether the pointer is over `content`.
struct Hovering<Content: View>: View {
    @ViewBuilder let content: (Bool) -> Content
    @State private var hovering = HoverPreview.on

    var body: some View {
        content(hovering)
            .hoverTracking { hovering = $0 }
            .animation(Theme.hoverAnimation, value: hovering)
    }
}

// MARK: - Fields

extension View {
    /// The look of a text field in forms: recessed, with a brighter border on hover and focus.
    func formField() -> some View {
        modifier(FormField())
    }
}

private struct FormField: ViewModifier {
    @FocusState private var focused: Bool
    @State private var hovering = HoverPreview.on

    func body(content: Content) -> some View {
        content
            .focused($focused)
            .font(.system(size: 12))
            .padding(.horizontal, 8)
            .frame(height: Theme.controlHeight)
            .background(Theme.field, in: .rect(cornerRadius: Theme.controlRadius + 1))
            .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius + 1)
                .strokeBorder(focused ? Theme.accent.opacity(0.6) : (hovering ? Theme.borderHover : Theme.fieldBorder)))
            .hoverTracking { hovering = $0 }
            .animation(Theme.hoverAnimation, value: hovering)
            .animation(Theme.hoverAnimation, value: focused)
    }
}

// MARK: - Button styles

/// Square icon button for bars: no fill at rest, a fill on hover, filled when on.
struct IconButtonStyle: ButtonStyle {
    var isOn = false
    var size: CGFloat = Theme.controlHeight
    var symbolSize: CGFloat = 12

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, isOn: isOn, size: size, symbolSize: symbolSize)
    }

    private struct Styled: View {
        let configuration: Configuration
        let isOn: Bool
        let size: CGFloat
        let symbolSize: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = HoverPreview.on

        var body: some View {
            let active = isEnabled && hovering
            configuration.label
                .font(.system(size: symbolSize, weight: .semibold))
                .frame(width: size, height: size)
                .foregroundStyle(!isEnabled ? Theme.textTertiary.opacity(0.5) : (isOn || active ? Theme.text : Theme.textSecondary))
                .background(fill, in: .rect(cornerRadius: Theme.controlRadius))
                .hoverTracking { hovering = $0 }
                .clickable(isEnabled)
                .animation(Theme.hoverAnimation, value: hovering)
        }

        private var fill: Color {
            guard isEnabled else { return .clear }
            if configuration.isPressed { return Theme.pressedFill }
            if hovering { return isOn ? Theme.pressedFill : Theme.raisedHover }
            return isOn ? Theme.accentSoft : .clear
        }
    }
}

/// Quiet raised button for secondary actions.
struct SubtleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration)
    }

    private struct Styled: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = HoverPreview.on

        var body: some View {
            let active = isEnabled && hovering
            configuration.label
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(isEnabled ? Theme.text : Theme.textTertiary)
                .padding(.horizontal, 10)
                .frame(minHeight: Theme.smallControlHeight)
                .background(configuration.isPressed ? Theme.pressedFill : (active ? Theme.raisedHover : Theme.raised),
                            in: .rect(cornerRadius: Theme.controlRadius))
                .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius)
                    .strokeBorder(active ? Theme.borderHover : Theme.fieldBorder))
                .opacity(isEnabled ? 1 : 0.55)
                .hoverTracking { hovering = $0 }
                .clickable(isEnabled)
                .animation(Theme.hoverAnimation, value: hovering)
        }
    }
}

/// Filled light button for the one primary action in a view.
struct AccentButtonStyle: ButtonStyle {
    var large = false

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, large: large)
    }

    private struct Styled: View {
        let configuration: Configuration
        let large: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = HoverPreview.on

        var body: some View {
            configuration.label
                .font(.system(size: large ? 13 : 11.5, weight: .semibold))
                .foregroundStyle(Theme.background)
                .padding(.horizontal, large ? 16 : 11)
                .frame(minHeight: large ? 30 : Theme.smallControlHeight)
                .background(fill, in: .rect(cornerRadius: Theme.controlRadius))
                .opacity(isEnabled ? 1 : 0.4)
                .hoverTracking { hovering = $0 }
                .clickable(isEnabled)
                .animation(Theme.hoverAnimation, value: hovering)
        }

        private var fill: Color {
            if configuration.isPressed { return Theme.accent.opacity(0.75) }
            return isEnabled && hovering ? Theme.text : Theme.accent
        }
    }
}

/// Borderless text or icon button (close, eject, reorder, inline links): just its content
/// until hovered, then a soft fill.
struct GhostButtonStyle: ButtonStyle {
    var padding: CGFloat = 4
    /// The resting color; hover brightens it to the text color.
    var tint: Color = Theme.textTertiary
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, padding: padding, tint: tint, destructive: destructive)
    }

    private struct Styled: View {
        let configuration: Configuration
        let padding: CGFloat
        let tint: Color
        let destructive: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = HoverPreview.on

        var body: some View {
            let active = isEnabled && hovering
            configuration.label
                .foregroundStyle(!isEnabled ? Theme.textTertiary.opacity(0.4) : (active ? (destructive ? Theme.danger : Theme.text) : tint))
                .padding(padding)
                .background(configuration.isPressed ? Theme.pressedFill : (active ? Theme.raisedHover : .clear),
                            in: .rect(cornerRadius: Theme.chipRadius))
                .hoverTracking { hovering = $0 }
                .clickable(isEnabled)
                .animation(Theme.hoverAnimation, value: hovering)
        }
    }
}

/// A full-width row that acts as a button (sidebar items, suggestion lists, pickers).
struct RowButtonStyle: ButtonStyle {
    var isSelected = false
    var height: CGFloat = Theme.controlHeight

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, isSelected: isSelected, height: height)
    }

    private struct Styled: View {
        let configuration: Configuration
        let isSelected: Bool
        let height: CGFloat
        @State private var hovering = HoverPreview.on

        var body: some View {
            configuration.label
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
                .background(fill, in: .rect(cornerRadius: Theme.controlRadius))
                .hoverTracking { hovering = $0 }
                .clickable()
                .animation(Theme.hoverAnimation, value: hovering)
        }

        private var fill: Color {
            if configuration.isPressed { return Theme.pressedFill }
            if isSelected { return hovering ? Theme.raisedHover : Theme.raised }
            return hovering ? Theme.hoverFill : .clear
        }
    }
}

/// A path chip: plain text that fills on hover; the folder you're in stands out.
struct CrumbStyle: ButtonStyle {
    let isCurrent: Bool
    var highlighted = false

    func makeBody(configuration: Configuration) -> some View {
        Hovering { hovering in
            configuration.label
                .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                .lineLimit(1)
                .padding(.horizontal, 6)
                .frame(height: Theme.smallControlHeight)
                .foregroundStyle(isCurrent || hovering || highlighted ? Theme.text : Theme.textSecondary)
                .background(fill(hovering, pressed: configuration.isPressed), in: .rect(cornerRadius: Theme.chipRadius))
                .overlay {
                    if highlighted {
                        RoundedRectangle(cornerRadius: Theme.chipRadius).strokeBorder(Theme.accent.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    }
                }
                .clickable()
        }
    }

    private func fill(_ hovering: Bool, pressed: Bool) -> Color {
        if pressed { return Theme.pressedFill }
        if hovering || highlighted { return Theme.raisedHover }
        return isCurrent ? Theme.raised : .clear
    }
}

/// A small icon button floating over content (a preview), on its own raised chip.
struct FloatingIconStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Hovering { hovering in
            configuration.label
                .foregroundStyle(hovering ? Theme.text : Theme.textSecondary)
                .frame(width: 22, height: 22)
                .background((configuration.isPressed ? Theme.pressedFill : (hovering ? Theme.raisedHover : Theme.raised)).opacity(0.94),
                            in: .rect(cornerRadius: Theme.chipRadius))
                .overlay(RoundedRectangle(cornerRadius: Theme.chipRadius).strokeBorder(hovering ? Theme.borderHover : Theme.fieldBorder))
                .clickable()
        }
    }
}

/// A compact status-bar item that opens something (action output, transfers).
struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Hovering { hovering in
            configuration.label
                .padding(.horizontal, 7)
                .frame(height: 20)
                .background(configuration.isPressed ? Theme.pressedFill : (hovering ? Theme.raisedHover : .clear),
                            in: .rect(cornerRadius: Theme.chipRadius))
                .clickable()
        }
    }
}

// MARK: - Menus

/// A pull-down menu with a label that responds like a button. Menu labels are drawn by
/// AppKit, which ignores hover inside them, so the hover chrome sits around the menu instead.
struct ChromeMenu<Items: View, Label: View>: View {
    enum Style {
        /// A field-like picker: "All Time ⌃".
        case field
        /// A bare icon, filled on hover.
        case icon
        /// Bare text, like a path chip.
        case chip
        /// Looks like a SubtleButtonStyle button ("+ New Action").
        case button
    }

    var style: Style = .field
    @ViewBuilder let items: () -> Items
    @ViewBuilder let label: () -> Label
    @State private var hovering = HoverPreview.on

    var body: some View {
        Menu(content: items) {
            labelContent
                // Plain-styled menus only respond where the label draws something; make the
                // whole button clickable, not just its icon or text.
                .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .background(background, in: .rect(cornerRadius: Theme.controlRadius))
        .overlay {
            if style == .field || style == .button {
                RoundedRectangle(cornerRadius: Theme.controlRadius).strokeBorder(hovering ? Theme.borderHover : Theme.fieldBorder)
            }
        }
        .hoverTracking { hovering = $0 }
        .clickable()
        .animation(Theme.hoverAnimation, value: hovering)
        #if DEBUG
        .debugRowFrame(named: "menu-\(style)")
        #endif
    }

    @ViewBuilder private var labelContent: some View {
        switch style {
        case .field:
            HStack(spacing: 5) {
                label()
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 9)
            .frame(height: Theme.smallControlHeight)
        case .icon:
            label()
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(hovering ? Theme.text : Theme.textSecondary)
                .frame(width: Theme.controlHeight, height: Theme.controlHeight)
        case .button:
            label()
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 10)
                .frame(height: Theme.smallControlHeight)
        case .chip:
            label()
                .font(.system(size: 12))
                .foregroundStyle(hovering ? Theme.text : Theme.textSecondary)
                .padding(.horizontal, 6)
                .frame(height: Theme.smallControlHeight)
        }
    }

    private var background: Color {
        switch style {
        case .field: hovering ? Theme.raised : Theme.field
        case .button: hovering ? Theme.raisedHover : Theme.raised
        case .icon, .chip: hovering ? Theme.raisedHover : .clear
        }
    }
}

extension ChromeMenu where Label == Text {
    /// A field-style picker titled with the current choice.
    init(_ title: String, @ViewBuilder items: @escaping () -> Items) {
        self.init(style: .field, items: items) { Text(title) }
    }
}
