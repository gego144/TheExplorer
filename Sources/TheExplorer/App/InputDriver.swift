#if DEBUG
import AppKit
import QuartzCore
import SwiftUI

/// Debug-only input for scripted scenes: real key presses, typing, clicks and scrolling,
/// delivered straight to the app's own window as AppKit events. Nothing goes through the
/// system event stream, so the person's mouse and keyboard are never touched, and no
/// permissions are needed. Because these are real events, they exercise the same paths as a
/// person using the app (focus, gestures, key equivalents, scroll handling).
@MainActor
enum InputDriver {
    static var window: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.canBecomeMain && $0.contentView != nil }
    }

    // MARK: Keys

    /// Presses a key combination like "cmd+k", "down", "return", "esc" or "shift+cmd+n".
    static func press(_ spec: String) {
        var flags: NSEvent.ModifierFlags = []
        var key = ""
        for part in spec.lowercased().split(separator: "+") {
            switch part {
            case "cmd": flags.insert(.command)
            case "shift": flags.insert(.shift)
            case "opt", "alt": flags.insert(.option)
            case "ctrl": flags.insert(.control)
            default: key = String(part)
            }
        }
        let (characters, keyCode) = Self.key(key)
        send(characters: characters, keyCode: keyCode, flags: flags)
    }

    /// Types text into whatever has focus, one key at a time.
    static func type(_ text: String) async {
        for character in text {
            send(characters: String(character), keyCode: 0, flags: character.isUppercase ? .shift : [])
            try? await Task.sleep(for: .milliseconds(30))
        }
    }

    private static func key(_ name: String) -> (String, UInt16) {
        func special(_ value: Int) -> String { String(UnicodeScalar(UInt16(value)).map(Character.init) ?? " ") }
        switch name {
        case "return", "enter": return ("\r", 36)
        case "esc", "escape": return ("\u{1b}", 53)
        case "tab": return ("\t", 48)
        case "space": return (" ", 49)
        case "delete", "backspace": return ("\u{7f}", 51)
        case "up": return (special(NSUpArrowFunctionKey), 126)
        case "down": return (special(NSDownArrowFunctionKey), 125)
        case "left": return (special(NSLeftArrowFunctionKey), 123)
        case "right": return (special(NSRightArrowFunctionKey), 124)
        default: return (name, 0)
        }
    }

    private static func send(characters: String, keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        guard let window else { return }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters.lowercased(), isARepeat: false, keyCode: keyCode
            ) else { continue }
            // Key equivalents (⌘K…) go through the menu, as they would for a real press.
            if type == .keyDown, !flags.isDisjoint(with: [.command, .control]), NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
                continue
            }
            window.sendEvent(event)
        }
    }

    // MARK: Mouse

    /// Clicks at a point in SwiftUI's window coordinates (top-left origin).
    static func click(at point: CGPoint, count: Int = 1, flags: NSEvent.ModifierFlags = []) async {
        guard let window, let content = window.contentView else { return }
        let location = NSPoint(x: point.x, y: content.bounds.height - point.y)
        for click in 1...count {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(
                    with: type, location: location, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: click, pressure: 1
                ) else { continue }
                window.sendEvent(event)
            }
            try? await Task.sleep(for: .milliseconds(count > 1 ? 60 : 10))
        }
    }

    // MARK: Scrolling

    struct ScrollReport: CustomStringConvertible {
        var frames = 0
        var scrolled: CGFloat = 0
        var gaps: [Double] = []
        /// Longest time spent stuck at the bottom before more rows arrived (a page load).
        var longestWait: Double = 0

        var description: String {
            let sorted = gaps.sorted()
            func ms(_ value: Double) -> String { String(format: "%.0fms", value * 1000) }
            let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
            // Steps are paced at ~16ms; anything past 33ms dropped at least one frame.
            let hitches = gaps.filter { $0 > 0.033 }.count
            return "scrolled \(Int(scrolled))pt in \(frames) steps · frame p95 \(ms(p95)) max \(ms(sorted.last ?? 0)) · hitches(>33ms) \(hitches) · longest wait at bottom \(ms(longestWait))"
        }
    }

    /// Scrolls the main list like a steady trackpad scroll, one step per frame, and measures
    /// how long each frame took. With no distance it keeps going until the list stops growing.
    static func scroll(points: CGFloat?, step: CGFloat = 60) async -> ScrollReport {
        var report = ScrollReport()
        guard let scrollView = mainScrollView() else { return report }
        // Negative distances scroll up.
        let direction: CGFloat = (points ?? 1) < 0 ? -1 : 1
        let target = points.map(abs) ?? .infinity
        var stuck = 0
        var stuckSince: CFTimeInterval?
        var last = CACurrentMediaTime()
        while report.scrolled < target && stuck < 150 {
            let before = scrollView.contentView.bounds.origin.y
            if let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                     wheel1: Int32(-step * direction), wheel2: 0, wheel3: 0),
               let event = NSEvent(cgEvent: cgEvent) {
                scrollView.scrollWheel(with: event)
            }
            try? await Task.sleep(for: .milliseconds(16))
            let now = CACurrentMediaTime()
            report.gaps.append(now - last)
            last = now
            report.frames += 1
            let moved = abs(scrollView.contentView.bounds.origin.y - before)
            if moved < 0.5 {
                stuck += 1
                if stuckSince == nil { stuckSince = now }
            } else {
                if let since = stuckSince { report.longestWait = max(report.longestWait, now - since) }
                stuckSince = nil
                stuck = 0
                report.scrolled += moved
            }
        }
        return report
    }

    /// The largest scroll view in the window: the file list.
    static func mainScrollView() -> NSScrollView? {
        guard let content = window?.contentView else { return nil }
        var found: [NSScrollView] = []
        func visit(_ view: NSView) {
            if let scrollView = view as? NSScrollView { found.append(scrollView) }
            view.subviews.forEach(visit)
        }
        visit(content)
        return found.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }
}

/// Where list rows are on screen, so scenes can click a row or its folder arrow by name.
@MainActor
enum RowGeometry {
    static var frames: [URL: CGRect] = [:]
    static var depths: [URL: Int] = [:]

    static func frame(named name: String) -> (URL, CGRect)? {
        frames.filter { $0.key.lastPathComponent == name }.min { $0.value.minY < $1.value.minY }.map { ($0.key, $0.value) }
    }
}

extension View {
    /// Records a row's frame for RowGeometry.
    func debugRowFrame(_ row: ListRow) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            RowGeometry.frames[row.id] = frame
            RowGeometry.depths[row.id] = row.depth
        }
    }
}
#endif
