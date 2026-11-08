import AppKit
import Observation
import SwiftUI

/// The status bar, drawn by AppKit: the keys worth knowing, what's going on, and what's
/// listed and selected (free space is at the foot of the sidebar). Transfers, actions and Google Drive's usage, which have popovers of their own,
/// stay SwiftUI in a small view of their own that changes only when they do.
///
/// It changes with every move and every selection; in SwiftUI that was ~2ms each.
final class StatusBarView: NSView {
    private let workspace: Workspace
    private let theme = TableTheme()
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
    private let spinner = NSProgressIndicator()
    private let activities: RegionHostingView

    /// What it shows.
    private struct Shown: Equatable {
        var summary = ""
        var status: String?
        var spinning = false
    }

    private var shown = Shown()
    private var generation = 0
    /// While a listing has taken long enough to show the spinner for.
    private var slowLoad: (pane: ObjectIdentifier, url: URL)?
    private var slowLoadCheck: DispatchWorkItem?
    private var pendingCheck: (pane: ObjectIdentifier, url: URL)?

    init(workspace: Workspace, values: RegionValues) {
        self.workspace = workspace
        activities = RegionHostingView(rootView: AnyView(StatusActivities(workspace: workspace).modifier(RegionStyle(values: values))))
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(Theme.background).cgColor
        spinner.style = .spinning
        spinner.controlSize = .mini
        spinner.isDisplayedWhenStopped = false
        addSubview(spinner)
        addSubview(activities)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    // MARK: Following the active pane

    private func refresh() {
        generation += 1
        let current = generation
        let read = withObservationTracking { readShown() } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.generation == current else { return }
                self.refresh()
            }
        }
        guard read != shown else { return }
        let relayout = read.status != shown.status || read.spinning != shown.spinning || read.summary.count != shown.summary.count
        shown = read
        if read.spinning { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        if relayout { needsLayout = true }
        needsDisplay = true
    }

    private func readShown() -> Shown {
        let model = workspace.selected
        var shown = Shown(summary: StatusText.summary(of: model))
        if let status = model.transferStatus {
            shown.status = status
            shown.spinning = true
        } else if let status = model.historyStatus {
            shown.status = status
        } else if model.isLoading || (model.isSearching && model.search.isRunning) {
            // Only once it's taken a moment: most folders list in a few milliseconds, and a
            // spinner flashing on every move is noise.
            shown.spinning = isSlow(model)
        } else {
            slowLoad = nil
        }
        return shown
    }

    private func isSlow(_ model: BrowserModel) -> Bool {
        let pane = ObjectIdentifier(model)
        let url = model.currentURL
        if let slowLoad, slowLoad.pane == pane, slowLoad.url == url { return true }
        if let pending = pendingCheck, pending.pane == pane, pending.url == url { return false }
        pendingCheck = (pane, url)
        slowLoadCheck?.cancel()
        let check = DispatchWorkItem { [weak self, weak model] in
            self?.pendingCheck = nil
            guard let self, let model, model.isLoading || (model.isSearching && model.search.isRunning),
                  model.currentURL == url, self.workspace.selected === model else { return }
            self.pendingCheck = nil
            self.slowLoad = (pane, url)
            self.refresh()
        }
        slowLoadCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: check)
        return false
    }

    // MARK: Layout and drawing

    /// The keys worth knowing, along the left.
    private static let hints = [("⌘F", "Find"), ("⌘K", "Go anywhere"), ("Space", "Preview"), ("⌘⌫", "Move to Trash")]

    private var hintsEnd: CGFloat {
        var x: CGFloat = 16
        for (key, label) in Self.hints {
            x += ceil(TextLines.shared.line(key, font: font, color: theme.body).width) + 5
            x += ceil(TextLines.shared.line(label, font: font, color: theme.textTertiary).width) + 18
        }
        return x
    }

    /// Where the summary (and before it, what's going on) starts, from the right.
    private var summaryStart: CGFloat {
        bounds.width - 16 - ceil(TextLines.shared.line(shown.summary, font: font, color: theme.textSecondary).width)
    }

    private var statusStart: CGFloat {
        guard let status = shown.status else { return summaryStart - (shown.spinning ? 22 : 0) }
        let width = min(320, ceil(TextLines.shared.line(status, font: font, color: theme.textSecondary).width))
        return summaryStart - 16 - width - (shown.spinning ? 18 : 0)
    }

    override func layout() {
        super.layout()
        let midY = bounds.midY + 0.5
        spinner.frame = NSRect(x: statusStart, y: midY - 6, width: 12, height: 12)
        // The activities sit left of the summary, right-aligned in their view; a fixed left
        // edge keeps that view from being resized (and laid out again) as the summary changes.
        let left = max(bounds.width * 0.45, hintsEnd)
        let frame = NSRect(x: left, y: 1, width: max(0, statusStart - 12 - left), height: bounds.height - 1)
        if activities.frame != frame { activities.frame = frame }
    }

    override func draw(_ dirtyRect: NSRect) {
        theme.border.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        let midY = bounds.midY + 0.5
        var x: CGFloat = 16
        for (key, label) in Self.hints where x < bounds.width * 0.45 {
            x += FileCellView.drawText(key, font: font, color: theme.body, x: x, midY: midY, width: 80) + 5
            x += FileCellView.drawText(label, font: font, color: theme.textTertiary, x: x, midY: midY, width: 160) + 18
        }
        if let status = shown.status {
            let start = statusStart + (shown.spinning ? 18 : 0)
            FileCellView.drawText(status, font: font, color: theme.textSecondary, x: start, midY: midY,
                                  width: summaryStart - 16 - start, truncation: .byTruncatingMiddle)
        }
        FileCellView.drawText(shown.summary, font: font, color: theme.textSecondary, x: summaryStart, midY: midY, width: bounds.width - summaryStart)
    }
}

/// Transfers, actions and Google Drive's usage, at the right of the status bar.
private struct StatusActivities: View {
    let workspace: Workspace

    var body: some View {
        HStack(spacing: 10) {
            TransferActivity { [weak workspace] folder, placed in workspace?.selected.navigate(to: folder, selecting: placed) }
            ActionActivity()
            let model = workspace.selected
            if model.destination == .drive, let account = model.drive.location?.accountID {
                DriveUsageIndicator(accountID: account)
            }
        }
        .font(.system(size: 11))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
    }
}

/// What the status bar says about the active pane's list.
enum StatusText {
    @MainActor
    static func summary(of model: BrowserModel) -> String {
        if model.isSearching {
            let count = model.search.visibleHits.count
            return "\(count.formatted()) \(count == 1 ? "result" : "results")"
        }
        switch model.destination {
        case .recents, .newFiles:
            let list = model.destination == .recents ? model.recents : model.newFiles
            let count = list.rows.count
            var text = "\(count.formatted()) \(count == 1 ? "item" : "items")"
            if !list.selection.isEmpty { text += " · \(list.selection.count.formatted()) selected" }
            return text
        case .storage:
            guard let result = StorageModel.shared.result else { return "" }
            return "\(Format.bytes(result.root.size)) · \(result.root.fileCount.formatted()) files scanned"
        case .s3:
            if model.s3.isSearching {
                let count = model.s3.searchRows.count
                var text = "\(count.formatted())\(count >= S3Browser.searchLimit ? "+" : "") \(count == 1 ? "result" : "results")"
                if model.s3.isSearchRunning { text += " · \(model.s3.searchChecked.formatted()) names read" }
                if !model.s3.selection.isEmpty { text += " · \(model.s3.selection.count.formatted()) selected" }
                return text
            }
            let (folders, files) = model.s3.counts
            var text = "\(folders.formatted()) \(folders == 1 ? "folder" : "folders") · \(files.formatted()) \(files == 1 ? "file" : "files")"
            if model.s3.hasMore { text += "+" }
            if !model.s3.selection.isEmpty { text += " · \(model.s3.selection.count.formatted()) selected" }
            return text
        case .drive:
            let drive = model.drive
            var text: String
            if drive.isSearching {
                text = "\(drive.rows.count.formatted())\(drive.hasMore ? "+" : "") \(drive.rows.count == 1 ? "result" : "results")"
            } else {
                let (folders, files) = drive.counts
                text = "\(folders.formatted()) \(folders == 1 ? "folder" : "folders") · \(files.formatted()) \(files == 1 ? "file" : "files")"
                if drive.hasMore { text += "+" }
            }
            if !drive.selection.isEmpty { text += " · \(drive.selection.count.formatted()) selected" }
            return text
        case .folder:
            let folders = model.folderCount, files = model.fileCount
            var text = "\(folders.formatted()) \(folders == 1 ? "folder" : "folders"), \(files.formatted()) \(files == 1 ? "file" : "files")"
            if model.hiddenCount > 0 { text += " · \(model.hiddenCount.formatted()) hidden" }
            let selection = model.selection
            if !selection.isEmpty {
                let sizes = FolderSizeStore.shared
                // A few selected are looked up; thousands (after ⌘A) are found in one pass.
                let selected = selection.count < 200 ? selection.compactMap { model.row(for: $0) } : model.rows.filter { selection.contains($0.id) }
                let bytes = selected.compactMap { $0.size ?? sizes.size(for: $0.item.path)?.bytes }.reduce(0, +)
                text += " · \(selected.count.formatted()) selected" + (bytes > 0 ? " (\(Format.bytes(bytes)))" : "")
            }
            return text
        }
    }
}
