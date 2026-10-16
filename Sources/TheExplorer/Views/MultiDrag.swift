import AppKit
import SwiftUI

/// Drags a multi-selection as one. SwiftUI's `.draggable` carries a single item, so dragging
/// several selected rows would only move the one under the mouse. When a press lands on a row
/// that's part of a selection of several, this holds back the mouse movement (so `.draggable`
/// never starts a second drag; macOS allows one session at a time) and starts an AppKit
/// session with every selected item. Every other drag is left to `.draggable`.
@MainActor
final class MultiDragSource: NSObject, NSDraggingSource {
    /// The list's rows in order and its selection, refreshed every time the list redraws.
    private var rows: [ListRow] = []
    private var selection: Set<URL> = []
    /// Where the rows on screen are, in window coordinates (top-left origin), and the list's
    /// window, so a press can be matched to a row.
    var frames: [URL: CGRect] = [:]
    weak var window: NSWindow?
    private var pressed: (url: URL, location: NSPoint, window: NSWindow)?
    private var monitor: Any?

    /// How far the mouse moves before a press becomes a drag, so clicks stay clicks.
    private static let threshold: CGFloat = 4

    func update(rows: [ListRow], selection: Set<URL>) {
        self.rows = rows
        self.selection = selection
    }

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            // Returning nil swallows the event, so don't fall back to passing it on.
            guard let self else { return event }
            return self.handle(event)
        }
    }

    func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        pressed = nil
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .leftMouseDown:
            pressed = nil
            guard selection.count > 1, let window, event.window === window, let content = window.contentView else { return event }
            let point = CGPoint(x: event.locationInWindow.x, y: content.bounds.height - event.locationInWindow.y)
            if let url = frames.first(where: { $0.value.contains(point) })?.key, selection.contains(url) {
                pressed = (url, event.locationInWindow, window)
            }
            return event
        case .leftMouseDragged:
            guard let pressed, event.window === pressed.window else { return event }
            // Swallowed either way, so .draggable never sees the movement.
            let distance = hypot(event.locationInWindow.x - pressed.location.x, event.locationInWindow.y - pressed.location.y)
            guard distance >= Self.threshold else { return nil }
            self.pressed = nil
            beginSession(with: event, from: pressed.window)
            return nil
        default:
            pressed = nil
            return event
        }
    }

    /// The selected rows in on-screen order.
    static func dragged(rows: [ListRow], selection: Set<URL>) -> [URL] {
        rows.lazy.map(\.id).filter(selection.contains)
    }

    private func beginSession(with event: NSEvent, from window: NSWindow) {
        guard let view = window.contentView else { return }
        let urls = Self.dragged(rows: rows, selection: selection)
        let point = view.convert(event.locationInWindow, from: nil)
        let generic = NSWorkspace.shared.icon(for: .data)
        let items = urls.enumerated().map { index, url in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            // A small fanned pile under the cursor; real icons for the first few.
            let image = index < 8 && url.isFileURL ? NSWorkspace.shared.icon(forFile: url.path) : generic
            let offset = CGFloat(min(index, 4)) * 3
            item.setDraggingFrame(NSRect(x: point.x - 16 + offset, y: point.y - 16 - offset, width: 32, height: 32), contents: image)
            return item
        }
        let session = view.beginDraggingSession(with: items, event: event, source: self)
        session.draggingFormation = .pile
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .move, .generic]
    }
}

/// Reports the window a view is in (and changes to it).
struct WindowReader: NSViewRepresentable {
    let onChange: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView { Reader(onChange: onChange) }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class Reader: NSView {
        let onChange: (NSWindow?) -> Void

        init(onChange: @escaping (NSWindow?) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onChange(window)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
