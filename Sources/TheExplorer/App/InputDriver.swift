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
    /// Where events go; scenes can point this at another window (e.g. a sheet under test).
    static var targetWindow: NSWindow?

    static var window: NSWindow? {
        targetWindow ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain && $0.contentView != nil }
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
            send(characters: String(character), keyCode: keyCodes[character.lowercased()] ?? 0, flags: character.isUppercase ? .shift : [])
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
        case "f5": return (special(NSF5FunctionKey), 96)
        case "f6": return (special(NSF6FunctionKey), 97)
        default: return (name, keyCodes[name] ?? 0)
        }
    }

    /// ANSI key codes, so shortcuts that match on the physical key (like ⌃⌥1) work.
    private static let keyCodes: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
        "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46,
        ".": 47, "`": 50,
    ]

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

    /// Real mouse events are numbered in sequence; SwiftUI's gestures can tell when they aren't.
    private static var eventNumber = 1000
    private static func nextEventNumber() -> Int {
        eventNumber += 1
        return eventNumber
    }

    /// Clicks at a point in SwiftUI's window coordinates (top-left origin).
    static func click(at point: CGPoint, count: Int = 1, flags: NSEvent.ModifierFlags = []) async {
        guard let window, let content = window.contentView else { return }
        let location = NSPoint(x: point.x, y: content.bounds.height - point.y)
        for click in 1...count {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(
                    with: type, location: location, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: nextEventNumber(), clickCount: click, pressure: 1
                ) else { continue }
                // Through the app, as a real click is, so NSApp.currentEvent is set (SwiftUI's
                // double-click recognition depends on it). This never activates the app.
                NSApp.sendEvent(event)
            }
            try? await Task.sleep(for: .milliseconds(count > 1 ? 60 : 10))
        }
    }

    /// A right-click at a point in the window, for context menus.
    static func rightClick(at point: CGPoint) async {
        guard let window, let content = window.contentView else { return }
        let location = NSPoint(x: point.x, y: content.bounds.height - point.y)
        for type in [NSEvent.EventType.rightMouseDown, .rightMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: nextEventNumber(), clickCount: 1, pressure: 1
            ) else { continue }
            NSApp.sendEvent(event)
        }
    }

    /// Moves the pointer over a point (hover) and then presses, drags and releases there, all
    /// as events to the app's own window. Nothing moves the real cursor.
    static func pressAndDrag(at point: CGPoint) async {
        guard let window, let content = window.contentView else { return }
        let location = NSPoint(x: point.x, y: content.bounds.height - point.y)
        for (type, offset) in [(NSEvent.EventType.mouseMoved, 0.0), (.leftMouseDown, 0), (.leftMouseDragged, 6), (.leftMouseDragged, 14), (.leftMouseUp, 14)] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: NSPoint(x: location.x + offset, y: location.y - offset), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: nextEventNumber(), clickCount: type == .mouseMoved ? 0 : 1, pressure: 1
            ) else { continue }
            NSApp.sendEvent(event)
            try? await Task.sleep(for: .milliseconds(type == .mouseMoved ? 150 : 30))
        }
    }

    /// Presses at a point in the window, drags by `dx` points in small steps, and lets go.
    static func drag(from point: CGPoint, by dx: CGFloat) async {
        guard let window, let content = window.contentView else { return }
        let start = NSPoint(x: point.x, y: content.bounds.height - point.y)
        let steps = 12
        var events: [(NSEvent.EventType, CGFloat)] = [(.leftMouseDown, 0)]
        events += (1...steps).map { (.leftMouseDragged, dx * CGFloat($0) / CGFloat(steps)) }
        events.append((.leftMouseUp, dx))
        for (type, offset) in events {
            guard let event = NSEvent.mouseEvent(
                with: type, location: NSPoint(x: start.x + offset, y: start.y), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: nextEventNumber(), clickCount: 1, pressure: 1
            ) else { continue }
            NSApp.sendEvent(event)
            try? await Task.sleep(for: .milliseconds(16))
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

    /// The topmost on-screen row whose path ends in `name` ("Theme.swift", or "debug-rows/Sources"
    /// for a row inside an archive).
    static func frame(named name: String) -> (URL, CGRect)? {
        frames.filter { $0.key.lastPathComponent == name || $0.key.path.hasSuffix("/" + name) }
            .min { $0.value.minY < $1.value.minY }.map { ($0.key, $0.value) }
    }
}

extension View {
    /// Records a row's frame for RowGeometry.
    func debugRowFrame(_ row: ListRow) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            RowGeometry.frames[row.id] = frame
            RowGeometry.depths[row.id] = row.depth
        }
        // Rows that scroll away or leave with a folder change must not be clicked by name later.
        .onDisappear { RowGeometry.frames[row.id] = nil }
    }

    /// Records the frame of a row that isn't a file on disk (e.g. inside an archive) under `name`.
    func debugRowFrame(named path: String) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            RowGeometry.frames[URL(fileURLWithPath: "/debug-rows/" + path)] = frame
        }
        .onDisappear { RowGeometry.frames[URL(fileURLWithPath: "/debug-rows/" + path)] = nil }
    }
}
#endif
