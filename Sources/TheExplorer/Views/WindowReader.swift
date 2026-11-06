import AppKit
import SwiftUI

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
