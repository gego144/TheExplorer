import SwiftUI

/// The "Actions" submenu for the right-click menu: actions that apply to the selection, then
/// a way to add or edit them.
struct ActionsMenu: View {
    let urls: Set<URL>
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let ordered = urls.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        let items = ordered.compactMap(FileItem.init(url:))
        let actions = ActionsStore.shared.applicable(to: items)
        Menu("Actions") {
            ForEach(actions) { action in
                Button(Self.title(action, items: items)) { ActionRunner.shared.run(action, on: ordered) }
            }
            if !actions.isEmpty { Divider() }
            Button(ActionsStore.shared.actions.isEmpty ? "Add an Action…" : "Edit Actions…") {
                Prefs.shared.settingsTab = .actions
                openSettings()
            }
        }
    }

    /// "Convert to HLS (m3u8)", or "… (2 of 3)" when it only applies to some of the selection.
    static func title(_ action: FileAction, items: [FileItem]) -> String {
        let matching = items.filter(action.applies).count
        return matching < items.count ? "\(action.name) (\(matching) of \(items.count))" : action.name
    }
}

// MARK: - Status bar

/// Shows running and recently finished actions in the status bar; click for their output.
struct ActionActivity: View {
    private var runner: ActionRunner { .shared }
    @State private var showing = false
    /// Finished runs started before this are no longer shown in the bar.
    @State private var dismissedBefore = Date.distantPast

    var body: some View {
        if let run = runner.runs.first, run.state == .running || run.started > dismissedBefore {
            Button { showing.toggle() } label: {
                HStack(spacing: 5) {
                    icon(run)
                    Text(label(run)).lineLimit(1).truncationMode(.middle)
                }
                .foregroundStyle(color(run))
            }
            .buttonStyle(PillButtonStyle())
            .frame(maxWidth: 320)
            .help("Show action output")
            .popover(isPresented: $showing, arrowEdge: .top) {
                ActionRunsView(onClear: { dismissedBefore = Date() })
            }
            .task(id: run.state) {
                // Successes fade out of the bar after a while; failures stay until you look.
                guard run.state == .succeeded else { return }
                try? await Task.sleep(for: .seconds(8))
                if !showing { dismissedBefore = Date() }
            }
        }
    }

    @ViewBuilder private func icon(_ run: ActionRunner.Run) -> some View {
        switch run.state {
        case .running: ProgressView().controlSize(.mini)
        case .succeeded: Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
        case .failed: Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9))
        case .cancelled: Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
        }
    }

    private func label(_ run: ActionRunner.Run) -> String {
        let others = runner.activeCount - (run.state == .running ? 1 : 0)
        let more = others > 0 ? " +\(others)" : ""
        switch run.state {
        case .running:
            let step = run.total > 1 ? " · \(run.completed + 1) of \(run.total)" : ""
            let item = run.current.map { " · \($0.lastPathComponent)" } ?? ""
            return run.name + step + item + more
        case .succeeded: return run.name + " done" + more
        case .failed: return run.name + " failed" + more
        case .cancelled: return run.name + " stopped" + more
        }
    }

    private func color(_ run: ActionRunner.Run) -> Color {
        switch run.state {
        case .failed: Theme.danger
        case .running: Theme.text
        default: Theme.textSecondary
        }
    }
}

/// Every recent run with its output, newest first.
struct ActionRunsView: View {
    let onClear: () -> Void
    private var runner: ActionRunner { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionCaption(title: "Actions")
                Spacer()
                if runner.runs.contains(where: { $0.state != .running }) {
                    Button("Clear") {
                        runner.clearFinished()
                        onClear()
                    }
                    .buttonStyle(SubtleButtonStyle())
                }
            }
            FittedScrollView(maxHeight: 440) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(runner.runs) { run in
                        RunCard(run: run)
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 460)
        .background(Theme.background)
        .preferredColorScheme(.dark)
    }
}

private struct RunCard: View {
    let run: ActionRunner.Run

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(run.name).font(.system(size: 12, weight: .semibold))
                Text(status)
                    .font(Theme.monoSmall)
                    .foregroundStyle(run.state == .running ? Theme.text : (isFailure ? Theme.danger : Theme.textTertiary))
                Spacer()
                if run.state == .running {
                    Button("Stop") { ActionRunner.shared.cancel(run.id) }
                        .buttonStyle(SubtleButtonStyle())
                }
            }
            Text(run.items.count == 1 ? run.items[0].lastPathComponent : "\(run.items.count) items: " + run.items.map(\.lastPathComponent).joined(separator: ", "))
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
            if !run.output.isEmpty {
                FittedScrollView(maxHeight: 160, anchor: .bottom) {
                    Text(run.output)
                        .font(Theme.monoSmall)
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .background(Theme.field, in: .rect(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
            }
        }
        .padding(10)
        .background(Theme.surface, in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
    }

    private var isFailure: Bool {
        if case .failed = run.state { return true }
        return false
    }

    private var status: String {
        let elapsed = (run.finished ?? Date()).timeIntervalSince(run.started)
        let time = elapsed < 60 ? String(format: "%.1fs", elapsed) : "\(Int(elapsed) / 60)m \(Int(elapsed) % 60)s"
        switch run.state {
        case .running: return run.total > 1 ? "\(run.completed) of \(run.total) done" : "running"
        case .succeeded: return "done in \(time)"
        case .failed(let code): return "failed (exit \(code)) after \(time)"
        case .cancelled: return "stopped after \(time)"
        }
    }
}

/// A scroll view as tall as its content, up to `maxHeight`. A plain ScrollView has no height of
/// its own, so in a popover or a window sized to fit it collapses to nothing.
private struct FittedScrollView<Content: View>: View {
    let maxHeight: CGFloat
    var anchor: UnitPoint?
    @ViewBuilder let content: Content
    @State private var height: CGFloat = 0

    var body: some View {
        ScrollView {
            content.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        }
        .defaultScrollAnchor(anchor)
        .frame(height: min(max(height, 1), maxHeight))
    }
}

// MARK: - Settings

/// The Actions tab in Settings: your actions in order, with add, edit, reorder and delete.
struct ActionsSettings: View {
    private var store: ActionsStore { .shared }
    @State private var editing: FileAction?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionCaption(title: "Actions")
                Spacer()
                ChromeMenu(style: .button) {
                    Button("Blank Action") { editing = FileAction(name: "", command: "") }
                    Divider()
                    ForEach(FileAction.templates, id: \.name) { template in
                        Button(template.name) {
                            var action = template
                            action.id = UUID()
                            editing = action
                        }
                    }
                } label: {
                    Label("New Action", systemImage: "plus")
                        .font(.system(size: 11.5, weight: .semibold))
                }
            }
            VStack(spacing: 0) {
                if store.actions.isEmpty {
                    VStack(spacing: 6) {
                        Text("No actions yet")
                            .font(.system(size: 12.5, weight: .medium))
                        Text("An action is a shell command you can run on files from the right-click menu, like turning a video into an HLS stream with ffmpeg.")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity)
                } else {
                    ForEach(Array(store.actions.enumerated()), id: \.element.id) { index, action in
                        if index > 0 { Rectangle().fill(Theme.border).frame(height: 1).padding(.leading, 12) }
                        ActionRow(action: action, isFirst: index == 0, isLast: index == store.actions.count - 1) {
                            editing = action
                        }
                    }
                }
            }
            .panel(padding: 0)
            Text("Run them from the right-click menu or the Actions menu (⌃⌥1–9 for the first nine). Commands run in zsh in the item’s folder, with your login profile, so tools like ffmpeg from Homebrew work.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .sheet(item: $editing) { action in
            ActionEditor(action: action) { editing = nil }
        }
    }
}

private struct ActionRow: View {
    let action: FileAction
    let isFirst: Bool
    let isLast: Bool
    let onEdit: () -> Void
    @State private var hovering = HoverPreview.on

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(action.name).font(.system(size: 12.5, weight: .medium))
                Text(action.summary)
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer()
            HStack(spacing: 4) {
                small("chevron.up", help: "Move up") { ActionsStore.shared.move(action, by: -1) }.disabled(isFirst)
                small("chevron.down", help: "Move down") { ActionsStore.shared.move(action, by: 1) }.disabled(isLast)
                small("trash", help: "Delete", destructive: true) { ActionsStore.shared.remove(action) }
            }
            .opacity(hovering ? 1 : 0.5)
            Button("Edit", action: onEdit).buttonStyle(SubtleButtonStyle())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(hovering ? Theme.hoverFill.opacity(0.6) : .clear)
        .hoverTracking { hovering = $0 }
        .animation(Theme.hoverAnimation, value: hovering)
        .onTapGesture(count: 2, perform: onEdit)
    }

    private func small(_ symbol: String, help: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).frame(width: 16, height: 16)
        }
        .buttonStyle(GhostButtonStyle(padding: 2, tint: Theme.textSecondary, destructive: destructive))
        .help(help)
    }
}

/// Edits one action in a sheet. Nothing is saved until you press Save.
struct ActionEditor: View {
    @State private var action: FileAction
    @State private var extensions: String
    let onDone: () -> Void

    init(action: FileAction, onDone: @escaping () -> Void) {
        _action = State(initialValue: action)
        _extensions = State(initialValue: action.extensions.joined(separator: ", "))
        self.onDone = onDone
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(ActionsStore.shared.actions.contains { $0.id == action.id } ? "Edit Action" : "New Action")
                .font(.system(size: 14, weight: .semibold))

            field("Name") {
                TextField("Convert to HLS", text: $action.name)
                    .textFieldStyle(.plain)
                    .formField()
            }

            field("Runs on") {
                Segmented(selection: $action.target, options: [(.files, "Files"), (.folders, "Folders"), (.filesAndFolders, "Both")])
                    .fixedSize()
            }

            if action.target != .folders {
                field("File types", hint: "Extensions, separated by commas. Leave empty for any file.") {
                    TextField("mp4, mov", text: $extensions)
                        .textFieldStyle(.plain)
                        .formField()
                }
            }

            field("With several selected") {
                Segmented(selection: $action.mode, options: [(.eachItem, "Run for each item"), (.allItems, "Run once with all")])
                    .fixedSize()
            }

            field("Command") {
                Hovering { hovering in
                    CommandEditor(text: $action.command)
                        .padding(6)
                        .frame(height: 130)
                        .background(Theme.field, in: .rect(cornerRadius: Theme.controlRadius + 1))
                        .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius + 1)
                            .strokeBorder(hovering ? Theme.borderHover : Theme.fieldBorder))
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Runs in zsh in the item’s folder. Variables:")
                variable("$FILE", "full path")
                variable("$FILENAME", "name with extension")
                variable("$NAME", "name without extension")
                variable("$EXT", "extension")
                variable("$DIR", "enclosing folder")
                variable("\"$@\"", "every selected path (with “Run once with all”)")
            }
            .font(.system(size: 11))
            .foregroundStyle(Theme.textTertiary)

            HStack {
                Spacer()
                Button("Cancel", action: onDone)
                    .buttonStyle(SubtleButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    action.extensions = FileAction.parseExtensions(extensions)
                    action.name = action.name.trimmingCharacters(in: .whitespaces)
                    ActionsStore.shared.save(action)
                    onDone()
                }
                .buttonStyle(AccentButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(action.name.trimmingCharacters(in: .whitespaces).isEmpty
                          || action.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 500)
        .background(Theme.background)
        .preferredColorScheme(.dark)
    }

    private func field(_ title: String, hint: String? = nil, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.textSecondary)
            content()
            if let hint {
                Text(hint).font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private func variable(_ name: String, _ meaning: String) -> some View {
        HStack(spacing: 6) {
            Text(name).font(Theme.monoSmall).foregroundStyle(Theme.textSecondary).frame(width: 74, alignment: .leading)
            Text(meaning)
        }
    }
}

/// A plain-text editor for shell commands. SwiftUI's TextEditor follows the system's smart
/// quotes and dashes, which would turn " into “ and break the command; this turns all of that off.
private struct CommandEditor: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        let textView = scrollView.documentView as! NSTextView
        textView.delegate = context.coordinator
        textView.string = text
        textView.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        textView.textColor = NSColor(Theme.text)
        textView.insertionPointColor = NSColor(Theme.text)
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let textView = scrollView.documentView as! NSTextView
        if textView.string != text { textView.string = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}


extension ActionRunner.Run {
    var name: String { action.name }
}
