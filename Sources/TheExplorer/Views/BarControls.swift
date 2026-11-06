import AppKit
import SwiftUI

/// A small icon button drawn by AppKit, in the looks the SwiftUI button styles have: `.icon`
/// (IconButtonStyle: a square that fills on hover, raised while on) and `.ghost`
/// (GhostButtonStyle: a quiet glyph that brightens on hover).
final class BarButton: NSView {
    enum Style {
        case icon
        case ghost
    }

    var symbol: String { didSet { if symbol != oldValue { needsDisplay = true } } }
    var isOn = false { didSet { if isOn != oldValue { needsDisplay = true } } }
    var isEnabled = true { didSet { if isEnabled != oldValue { needsDisplay = true } } }
    var action: () -> Void = {}
    /// For symbols with a mark cut out of a filled shape ("xmark.circle.fill"): the color the
    /// mark is drawn in, so it shows.
    var cutout: NSColor?
    /// Shown on the press instead of running `action`.
    var popUpMenu: (() -> NSMenu)?

    private let style: Style
    private let symbolSize: CGFloat
    private let weight: NSFont.Weight
    private let theme: TableTheme
    private let pressedFill = NSColor(Theme.pressedFill)
    private var hovering = HoverPreview.on
    private var pressed = false
    private var tracking: NSTrackingArea?

    init(_ symbol: String, style: Style = .icon, size: CGFloat = 12, weight: NSFont.Weight = .semibold, help: String = "", theme: TableTheme) {
        self.symbol = symbol
        self.style = style
        symbolSize = size
        self.weight = weight
        self.theme = theme
        super.init(frame: .zero)
        toolTip = help.isEmpty ? nil : help
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let active = isEnabled && hovering
        let fill: NSColor?
        switch style {
        case .icon:
            fill = !isEnabled ? nil : pressed ? pressedFill : hovering ? (isOn ? pressedFill : theme.raisedHover) : (isOn ? theme.accentSoft : nil)
        case .ghost:
            fill = pressed ? pressedFill : (active ? theme.raisedHover : nil)
        }
        if let fill {
            fill.setFill()
            let radius = style == .icon ? Theme.controlRadius : Theme.chipRadius
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        }
        let color: NSColor = switch style {
        case .icon: !isEnabled ? theme.textTertiary.withAlphaComponent(0.5) : (isOn || active ? theme.text : theme.textSecondary)
        case .ghost: !isEnabled ? theme.textTertiary.withAlphaComponent(0.4) : (active ? theme.text : theme.textTertiary)
        }
        let image: NSImage
        if let cutout {
            let config = NSImage.SymbolConfiguration(pointSize: symbolSize, weight: weight).applying(.init(paletteColors: [cutout, color]))
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) ?? NSImage()
        } else {
            image = theme.symbol(symbol, size: symbolSize, weight: weight, color: color)
        }
        image.draw(in: NSRect(x: bounds.midX - image.size.width / 2, y: bounds.midY - image.size.height / 2,
                              width: image.size.width, height: image.size.height))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .cursorUpdate, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = HoverPreview.on
        needsDisplay = true
    }

    override func cursorUpdate(with event: NSEvent) {
        (isEnabled ? NSCursor.pointingHand : NSCursor.arrow).set()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        if let popUpMenu {
            hovering = true
            needsDisplay = true
            popUpMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.maxY + 4), in: self)
            hovering = false
            needsDisplay = true
            return
        }
        pressed = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled, popUpMenu == nil else { return }
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        if inside != pressed {
            pressed = inside
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard pressed else { return }
        pressed = false
        needsDisplay = true
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }
}

/// A compact segmented control drawn by AppKit, as Segmented looks: a recessed track with the
/// chosen option raised.
final class BarSegmented: NSView {
    var options: [String] { didSet { if options != oldValue { invalidateIntrinsicContentSize(); needsDisplay = true } } }
    var selected = 0 { didSet { if selected != oldValue { needsDisplay = true } } }
    var onSelect: (Int) -> Void = { _ in }

    private let theme: TableTheme
    private let font = NSFont.systemFont(ofSize: 11, weight: .medium)
    private let field = NSColor(Theme.field)
    private let fieldBorder = NSColor(Theme.fieldBorder)
    private let raised = NSColor(Theme.raised)
    private var hovered: Int?
    private var tracking: NSTrackingArea?

    init(_ options: [String], theme: TableTheme) {
        self.options = options
        self.theme = theme
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var segmentWidths: [CGFloat] {
        options.map { ceil(TextLines.shared.line($0, font: font, color: theme.text).width) + 16 }
    }

    var width: CGFloat { segmentWidths.reduce(0, +) + CGFloat(max(0, options.count - 1)) * 2 + 4 }
    static let height = Theme.smallControlHeight

    private func segmentRects() -> [NSRect] {
        var x: CGFloat = 2
        return segmentWidths.map { width in
            let rect = NSRect(x: x, y: 2, width: width, height: Self.height - 4)
            x += width + 2
            return rect
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = Theme.controlRadius + 1
        field.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius - 0.5, yRadius: radius - 0.5)
        fieldBorder.setStroke()
        ring.stroke()
        for (index, rect) in segmentRects().enumerated() {
            let isSelected = index == selected
            let isHovered = hovered == index || HoverPreview.on
            if isSelected || isHovered {
                (isSelected ? theme.raisedHover : raised).setFill()
                NSBezierPath(roundedRect: rect, xRadius: Theme.controlRadius - 1, yRadius: Theme.controlRadius - 1).fill()
            }
            FileCellView.drawText(options[index], font: font, color: isSelected || isHovered ? theme.text : theme.textSecondary,
                                  x: rect.minX, midY: rect.midY, width: rect.width, alignment: .center)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    private func segment(at event: NSEvent) -> Int? {
        let point = convert(event.locationInWindow, from: nil)
        return segmentRects().firstIndex { $0.contains(point) }
    }

    override func mouseMoved(with event: NSEvent) {
        let index = segment(at: event)
        guard index != hovered else { return }
        hovered = index
        needsDisplay = true
        (index != nil && index != selected ? NSCursor.pointingHand : NSCursor.arrow).set()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        needsDisplay = true
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        guard let index = segment(at: event), index != selected else { return }
        selected = index
        onSelect(index)
    }
}

/// A quiet raised button drawn by AppKit, as SubtleButtonStyle looks: a title, maybe with a
/// symbol before it, on a raised chip with a border.
final class SubtleButton: NSView {
    var title: String { didSet { if title != oldValue { needsDisplay = true } } }
    var symbol: String? { didSet { if symbol != oldValue { needsDisplay = true } } }
    var action: () -> Void = {}
    /// The one main action in a view: filled with the text color, the title in the background's.
    var prominent = false

    private let theme: TableTheme
    private let font = NSFont.systemFont(ofSize: 12, weight: .medium)
    private let raised = NSColor(Theme.raised)
    private let pressedFill = NSColor(Theme.pressedFill)
    private var hovering = HoverPreview.on
    private var pressed = false
    private var tracking: NSTrackingArea?

    init(_ title: String, symbol: String? = nil, help: String? = nil, theme: TableTheme) {
        self.title = title
        self.symbol = symbol
        self.theme = theme
        super.init(frame: .zero)
        toolTip = help
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var image: NSImage? { symbol.map { theme.symbol($0, size: 11, weight: .medium, color: titleColor) } }
    private var titleColor: NSColor { prominent ? theme.background : theme.body }

    var width: CGFloat {
        let text = title.isEmpty ? 0 : ceil(TextLines.shared.line(title, font: font, color: theme.text).width)
        let icon = image.map { $0.size.width + (title.isEmpty ? 0 : 5) } ?? 0
        return text + icon + (title.isEmpty ? 16 : 24)
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds, xRadius: Theme.controlRadius, yRadius: Theme.controlRadius)
        if prominent {
            (pressed ? theme.text.withAlphaComponent(0.8) : (hovering ? theme.text.withAlphaComponent(0.9) : theme.text)).setFill()
        } else {
            (pressed ? pressedFill : (hovering ? theme.raisedHover : raised)).setFill()
        }
        shape.fill()
        var x: CGFloat = title.isEmpty ? 8 : 12
        if let image {
            image.draw(in: NSRect(x: x, y: bounds.midY - image.size.height / 2, width: image.size.width, height: image.size.height))
            x += image.size.width + 5
        }
        if !title.isEmpty {
            FileCellView.drawText(title, font: font, color: titleColor, x: x, midY: bounds.midY, width: bounds.width - x)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .cursorUpdate, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = HoverPreview.on
        needsDisplay = true
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }

    override func mouseDown(with event: NSEvent) {
        pressed = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        if inside != pressed {
            pressed = inside
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard pressed else { return }
        pressed = false
        needsDisplay = true
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }
}

/// A word in a bar that acts as a button ("List", "Details", "Modified ↓"): quiet text, the
/// text color while on, a fill on hover. With `popUpMenu` it opens a menu instead.
final class QuietButton: NSView {
    var title: String { didSet { if title != oldValue { invalidateIntrinsicContentSize(); needsDisplay = true } } }
    var isOn = false { didSet { if isOn != oldValue { needsDisplay = true } } }
    var action: () -> Void = {}
    var popUpMenu: (() -> NSMenu)?

    private let theme: TableTheme
    private let font = NSFont.systemFont(ofSize: 12)
    private let pressedFill = NSColor(Theme.pressedFill)
    private var hovering = HoverPreview.on
    private var pressed = false
    private var tracking: NSTrackingArea?

    init(_ title: String, help: String? = nil, theme: TableTheme) {
        self.title = title
        self.theme = theme
        super.init(frame: .zero)
        toolTip = help
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var width: CGFloat { ceil(TextLines.shared.line(title, font: font, color: theme.text).width) + 20 }

    override func draw(_ dirtyRect: NSRect) {
        if pressed || hovering {
            (pressed ? pressedFill : theme.hoverFill).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: Theme.controlRadius, yRadius: Theme.controlRadius).fill()
        }
        FileCellView.drawText(title, font: font, color: isOn || hovering ? theme.text : theme.textSecondary,
                              x: 0, midY: bounds.midY, width: bounds.width, alignment: .center)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .cursorUpdate, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = HoverPreview.on
        needsDisplay = true
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }

    override func mouseDown(with event: NSEvent) {
        if let popUpMenu {
            popUpMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.maxY + 4), in: self)
            hovering = false
            needsDisplay = true
            return
        }
        pressed = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard popUpMenu == nil else { return }
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        if inside != pressed {
            pressed = inside
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard pressed else { return }
        pressed = false
        needsDisplay = true
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }
}
