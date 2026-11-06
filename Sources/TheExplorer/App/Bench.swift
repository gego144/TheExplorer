#if DEBUG
import AppKit

/// Everyday navigation, timed: real clicks and key presses through the app's own window (see
/// InputDriver), each measured from input to screen by LatencyMeter. Run with the `bench` scene
/// in a folder holding "Alpha" and "Beta" folders (scripts/bench-fixture.sh makes one).
@MainActor
enum Bench {
    private struct Step {
        let label: String
        let input: () async -> Void
    }

    static func run(rounds: Int, workspace: Workspace, log: @escaping (String) -> Void) async {
        let meter = LatencyMeter.shared
        meter.enable()
        meter.clear()
        let home = workspace.selected.currentURL

        func key(_ spec: String) -> () async -> Void { { InputDriver.press(spec) } }
        func press(_ name: String) -> () async -> Void {
            {
                if let (_, frame) = RowGeometry.frame(named: name) {
                    await InputDriver.click(at: CGPoint(x: frame.midX, y: frame.midY))
                } else {
                    log("bench: nothing named \(name) on screen")
                }
            }
        }
        func row(_ name: String, clicks: Int = 1) -> () async -> Void {
            {
                if let (_, frame) = RowGeometry.frame(named: name) {
                    await InputDriver.click(at: CGPoint(x: frame.minX + 80, y: frame.midY), count: clicks)
                } else {
                    log("bench: no row \(name) on screen")
                }
            }
        }

        let steps: [Step] = [
            Step(label: "new tab (click +)", input: press("newtab-button")),
            Step(label: "switch tab (click)", input: press("tab-0")),
            Step(label: "switch tab back (click)", input: press("tab-1")),
            Step(label: "close tab (⌘W)", input: key("cmd+w")),
            Step(label: "new tab (⌘T)", input: key("cmd+t")),
            Step(label: "close tab again (⌘W)", input: key("cmd+w")),
            Step(label: "select row (click)", input: row("Beta")),
            Step(label: "arrow down", input: key("down")),
            Step(label: "arrow down again", input: key("down")),
            Step(label: "open folder (double-click)", input: row("Alpha", clicks: 2)),
            Step(label: "back (⌘[)", input: key("cmd+[")),
            Step(label: "forward (⌘])", input: key("cmd+]")),
            Step(label: "up (⌘↑)", input: key("cmd+up")),
            Step(label: "sidebar place (click)", input: press("sidebar-Downloads")),
            Step(label: "back from sidebar (⌘[)", input: key("cmd+[")),
            Step(label: "gallery (⌥⌘2)", input: key("opt+cmd+2")),
            Step(label: "list (⌥⌘1)", input: key("opt+cmd+1")),
            Step(label: "command bar (⌘K)", input: key("cmd+k")),
            Step(label: "close command bar (esc)", input: key("esc")),
        ]

        var results: [String: [LatencyMeter.Sample]] = [:]
        for round in 1...rounds {
            workspace.selected.navigate(to: home)
            try? await Task.sleep(for: .milliseconds(600))
            for step in steps {
                meter.begin(label: step.label)
                await step.input()
                if let sample = await meter.waitForSample() {
                    results[step.label, default: []].append(sample)
                    if ProcessInfo.processInfo.environment["EXPLORER_BENCH_TRACE"] == "1" {
                        let turns = sample.turns.map { String(format: "%.0f+%.1f", $0.0 * 1000, $0.1 * 1000) }.joined(separator: " ")
                        log(String(format: "[trace] %@ busy %.1fms cpu %.1fms turns: ", step.label, sample.busy * 1000, sample.cpu * 1000) + turns)
                    }
                } else {
                    log("bench: round \(round) \(step.label) never settled")
                }
                // Let any trailing work (thumbnails, sizes) finish so steps don't overlap.
                try? await Task.sleep(for: .milliseconds(250))
            }
        }

        func ms(_ value: Double) -> String { String(format: "%5.0f", value * 1000) }
        func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        func worst(_ values: [Double]) -> Double { values.max() ?? 0 }
        log("[bench] \(rounds) rounds · times in ms · response = first frame that changed, done = screen settled")
        log("[bench] " + "step".padding(toLength: 28, withPad: " ", startingAt: 0)
            + "  resp med  resp max  done med  done max  busy med  longest")
        for step in steps {
            guard let samples = results[step.label], !samples.isEmpty else { continue }
            let line = step.label.padding(toLength: 28, withPad: " ", startingAt: 0)
                + "     \(ms(median(samples.map(\.response))))     \(ms(worst(samples.map(\.response))))"
                + "     \(ms(median(samples.map(\.done))))     \(ms(worst(samples.map(\.done))))"
                + "     \(ms(median(samples.map(\.busy))))    \(ms(worst(samples.map(\.longest))))"
            log("[bench] " + line)
        }
    }
}
#endif
