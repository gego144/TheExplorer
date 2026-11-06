import AppKit
import QuartzCore

/// Measures how long each click and key press takes to show on screen.
///
/// An interaction starts at the input's own timestamp (when the hardware saw it, so time spent
/// waiting behind a busy main thread counts). From then on every turn of the main run loop is
/// timed; turns that did real work (layout, drawing, applying results) are the interaction's
/// work. Two numbers come out:
///
/// - **response**: until the end of the first turn that did work, rounded up to the screen
///   refresh that shows it. This is when something visibly reacts.
/// - **done**: until the last turn of work before the screen goes quiet (results that arrive
///   later, like a folder's listing, count), rounded up the same way.
///
/// It also records the main thread's busy time and its longest single turn, which is what
/// shows up as a dropped frame. The display link only runs while an interaction is being
/// measured, so it costs nothing when idle.
@MainActor
final class LatencyMeter {
    static let shared = LatencyMeter()

    struct Sample: Sendable {
        let label: String
        /// Seconds from the input to the frame that first showed a change.
        let response: Double
        /// Seconds from the input to the frame after the last change.
        let done: Double
        /// Main-thread time spent on it.
        let busy: Double
        /// The longest single main-thread turn: anything past a frame is a dropped frame.
        let longest: Double
        /// From the input to the main thread starting on it.
        let queued: Double
        /// CPU time the main thread actually used meanwhile (busy minus time spent blocked).
        let cpu: Double
        /// The turns that did work, for tracing: start (from the input) and length, in seconds.
        let turns: [(Double, Double)]
    }

    private(set) var isEnabled = false
    private(set) var samples: [Sample] = []
    /// Called with each finished measurement.
    var onSample: ((Sample) -> Void)?
    /// What the next input is called in reports; scripted benchmarks set it.
    var nextLabel: String?

    private struct Pending {
        let label: String
        let start: CFTimeInterval
        var firstWorkEnd: CFTimeInterval?
        var lastWorkEnd: CFTimeInterval
        var firstTurnStart: CFTimeInterval?
        var busy: Double = 0
        var longest: Double = 0
        var cpuStart: Double = 0
        /// Each turn that did work: when it started (from the input) and how long it took.
        var turns: [(Double, Double)] = []
    }

    private var pending: Pending?
    private var turnStart: CFTimeInterval = 0
    private var observers: [CFRunLoopObserver] = []
    private var monitor: Any?
    private var displayLink: CADisplayLink?
    private var lastVsync: CFTimeInterval = 0
    private var frameDuration: CFTimeInterval = 1.0 / 60
    private var waiters: [UUID: CheckedContinuation<Sample?, Never>] = [:]

    /// A turn shorter than this did nothing visible (a timer firing, an idle display link tick).
    private static let workThreshold: Double = 0.0005
    /// The screen counts as settled after this long without work.
    private static let quietPeriod: Double = 0.15
    /// Interactions are cut off after this long.
    private static let limit: Double = 5

    func enable() {
        guard !isEnabled else { return }
        isEnabled = true
        let runLoop = CFRunLoopGetMain()
        // After waking: a turn begins.
        let wake = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, Int.min) { _, _ in
            MainActor.assumeIsolated { LatencyMeter.shared.turnStart = CACurrentMediaTime() }
        }
        // Before sleeping, after Core Animation has committed the turn's changes: it ends.
        let sleep = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, Int.max) { _, _ in
            MainActor.assumeIsolated { LatencyMeter.shared.turnEnded() }
        }
        for observer in [wake, sleep].compactMap({ $0 }) {
            CFRunLoopAddObserver(runLoop, observer, .commonModes)
            observers.append(observer)
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { event in
            LatencyMeter.shared.begin(event: event)
            return event
        }
    }

    /// Starts measuring an input. Real events arrive through the monitor; scripted ones call
    /// this directly, since they're sent straight to a window.
    func begin(event: NSEvent) {
        guard isEnabled else { return }
        begin(label: nextLabel ?? Self.describe(event), at: event.timestamp)
        nextLabel = nil
    }

    func begin(label: String, at time: CFTimeInterval = CACurrentMediaTime()) {
        guard isEnabled else { return }
        // A second input before the first settled (a double-click, mouse-up) is the same interaction.
        if pending != nil { return }
        pending = Pending(label: label, start: time, lastWorkEnd: time, cpuStart: Self.mainThreadCPU())
        startDisplayLink()
    }

    /// Waits for the measurement in progress to finish; nil if none is, or on timeout.
    func waitForSample(timeout: Double = 6) async -> Sample? {
        guard pending != nil else { return nil }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            waiters[id] = continuation
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeout))
                self.waiters.removeValue(forKey: id)?.resume(returning: nil)
            }
        }
    }

    func clear() { samples.removeAll() }

    /// Called right after a view pushes a frame to the screen in the middle of a turn
    /// (CATransaction.flush), so the response is when that frame went out rather than when
    /// the turn ended.
    func noteFlush() {
        guard var current = pending, current.firstWorkEnd == nil else { return }
        current.firstWorkEnd = CACurrentMediaTime()
        pending = current
    }

    // MARK: Turns and frames

    private func turnEnded() {
        let now = CACurrentMediaTime()
        guard var current = pending else { return }
        let start = max(turnStart, current.start)
        let duration = now - start
        if duration >= Self.workThreshold {
            if current.firstTurnStart == nil { current.firstTurnStart = start }
            current.busy += duration
            current.longest = max(current.longest, duration)
            current.lastWorkEnd = now
            if current.firstWorkEnd == nil { current.firstWorkEnd = now }
            if current.turns.count < 64 { current.turns.append((start - current.start, duration)) }
        }
        pending = current
    }

    private func startDisplayLink() {
        guard displayLink == nil, let screen = NSApp.windows.first(where: \.isVisible)?.screen ?? NSScreen.main else { return }
        let link = screen.displayLink(target: DisplayLinkTarget.shared, selector: #selector(DisplayLinkTarget.tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    fileprivate func tick(_ link: CADisplayLink) {
        lastVsync = link.timestamp
        frameDuration = max(1.0 / 240, link.targetTimestamp - link.timestamp)
        guard let current = pending else { return }
        let now = CACurrentMediaTime()
        let quiet = now - current.lastWorkEnd
        guard quiet >= Self.quietPeriod || now - current.start >= Self.limit else { return }
        finish(current)
    }

    /// The first screen refresh at or after `time`.
    private func presented(_ time: CFTimeInterval) -> CFTimeInterval {
        guard lastVsync > 0 else { return time }
        // Negative for times before the last refresh seen, which is fine: it's still the first
        // refresh at or after `time`.
        let frames = ((time - lastVsync) / frameDuration).rounded(.up)
        return lastVsync + frames * frameDuration
    }

    private func finish(_ current: Pending) {
        pending = nil
        displayLink?.invalidate()
        displayLink = nil
        let first = current.firstWorkEnd ?? current.lastWorkEnd
        let sample = Sample(label: current.label,
                            response: presented(first) - current.start,
                            done: presented(current.lastWorkEnd) - current.start,
                            busy: current.busy,
                            longest: current.longest,
                            queued: max(0, (current.firstTurnStart ?? current.start) - current.start),
                            cpu: Self.mainThreadCPU() - current.cpuStart,
                            turns: current.turns)
        samples.append(sample)
        if samples.count > 500 { samples.removeFirst(samples.count - 500) }
        onSample?(sample)
        let waiting = waiters.values
        waiters = [:]
        waiting.forEach { $0.resume(returning: sample) }
    }

    /// CPU seconds the main thread has used. Called on the main thread.
    static func mainThreadCPU() -> Double {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let thread = pthread_mach_thread_np(pthread_self())
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count) }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1e6
            + Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1e6
    }

    private static func describe(_ event: NSEvent) -> String {
        switch event.type {
        case .keyDown:
            var parts: [String] = []
            let flags = event.modifierFlags
            if flags.contains(.control) { parts.append("⌃") }
            if flags.contains(.option) { parts.append("⌥") }
            if flags.contains(.shift) { parts.append("⇧") }
            if flags.contains(.command) { parts.append("⌘") }
            return "key " + parts.joined() + (event.charactersIgnoringModifiers ?? "?")
        case .rightMouseDown: return "right-click"
        default: return event.clickCount > 1 ? "double-click" : "click"
        }
    }
}

/// The display link's target. CADisplayLink keeps its target alive, so this is a small
/// separate object rather than the meter.
private final class DisplayLinkTarget: NSObject {
    static let shared = DisplayLinkTarget()

    @objc func tick(_ link: CADisplayLink) {
        MainActor.assumeIsolated { LatencyMeter.shared.tick(link) }
    }
}

// MARK: - On-screen readout

/// A small readout in the corner of the screen showing the last interaction's times, colored by
/// how they feel: within a frame or two is instant, past 50ms is noticeable, past 100ms laggy.
/// Turned on with `defaults write <bundle id> showLatency -bool true` (or EXPLORER_LATENCY=1).
@MainActor
final class LatencyHUD {
    static let shared = LatencyHUD()
    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")

    static var isRequested: Bool {
        UserDefaults.standard.bool(forKey: "showLatency") || ProcessInfo.processInfo.environment["EXPLORER_LATENCY"] == "1"
    }

    func show() {
        guard panel == nil else { return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 44), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = NSColor(white: 0.08, alpha: 0.92)
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        label.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        label.textColor = .white
        label.maximumNumberOfLines = 2
        label.frame = NSRect(x: 10, y: 6, width: 280, height: 32)
        panel.contentView?.addSubview(label)
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.cornerRadius = 8
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.maxX - 316, y: screen.minY + 16))
        }
        label.stringValue = "Waiting for a click or key…"
        panel.orderFrontRegardless()
        self.panel = panel
        LatencyMeter.shared.onSample = { [weak self] sample in self?.update(sample) }
    }

    private func update(_ sample: LatencyMeter.Sample) {
        func ms(_ value: Double) -> String { "\(Int((value * 1000).rounded()))ms" }
        label.stringValue = "\(sample.label)\nresponse \(ms(sample.response)) · done \(ms(sample.done)) · busy \(ms(sample.busy))"
        label.textColor = sample.done <= 0.034 ? NSColor(red: 0.5, green: 0.9, blue: 0.6, alpha: 1)
            : sample.done <= 0.1 ? NSColor(red: 0.95, green: 0.8, blue: 0.4, alpha: 1)
            : NSColor(red: 0.95, green: 0.45, blue: 0.45, alpha: 1)
    }
}
