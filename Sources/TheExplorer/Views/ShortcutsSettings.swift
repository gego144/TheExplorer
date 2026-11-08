import AppKit
import SwiftUI

/// Settings › Shortcuts: every menu command's keys, each changeable. Click a shortcut and press
/// new keys (esc cancels, ⌫ leaves the command without one). Keys another command had move
/// here, and that command is named so nothing changes silently. The keys that can't be changed
/// are listed at the end, so the whole set is in one place.
struct ShortcutsSettings: View {
    @State private var filter = ""
    /// Said under a row after a change: which command gave up its keys, or why keys weren't taken.
    @State private var note: (command: ShortcutCommand, text: String, isWarning: Bool)?
    @Bindable private var shortcuts = Shortcuts.shared
    private var recording: ShortcutCommand? {
        get { shortcuts.recording }
        nonmutating set { shortcuts.recording = newValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                TextField("Filter commands or keys", text: $filter)
                    .textFieldStyle(.plain)
                    .formField()
                Button("Restore Defaults") {
                    shortcuts.resetAll()
                    note = nil
                }
                .buttonStyle(SubtleButtonStyle())
                .disabled(shortcuts.changes.isEmpty)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(ShortcutCommand.Group.allCases, id: \.self) { group in
                        let commands = ShortcutCommand.allCases.filter { $0.group == group && matches($0) }
                        if !commands.isEmpty {
                            section(group.rawValue) {
                                ForEach(Array(commands.enumerated()), id: \.element) { index, command in
                                    if index > 0 { divider }
                                    row(command)
                                }
                            }
                        }
                    }
                    let fixed = Shortcuts.fixed.filter { filter.isEmpty || "\($0.title) \($0.keys)".localizedCaseInsensitiveContains(filter) }
                    if !fixed.isEmpty {
                        section("Built in") {
                            ForEach(Array(fixed.enumerated()), id: \.offset) { index, entry in
                                if index > 0 { divider }
                                HStack {
                                    Text(entry.title).foregroundStyle(Theme.textSecondary)
                                    Spacer()
                                    Text(entry.keys).foregroundStyle(Theme.textTertiary)
                                }
                                .font(.system(size: 12.5))
                                .padding(.horizontal, 12)
                                .frame(height: 34)
                            }
                        }
                    }
                }
                .padding(.bottom, 4)
                .thinScrollers()
            }
            .scrollIndicators(.automatic)
            .frame(height: 460)
        }
        .onChange(of: shortcuts.recording) { if recording != nil { note = nil } }
        .onDisappear { recording = nil }
    }

    private func matches(_ command: ShortcutCommand) -> Bool {
        guard !filter.isEmpty else { return true }
        return command.title.localizedCaseInsensitiveContains(filter)
            || (shortcuts.shortcut(command)?.display.localizedCaseInsensitiveContains(filter) ?? false)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionCaption(title: title)
            VStack(spacing: 0) { content() }
                .panel(padding: 0)
        }
    }

    private var divider: some View {
        Rectangle().fill(Theme.border).frame(height: 1).padding(.leading, 12)
    }

    private func row(_ command: ShortcutCommand) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(command.title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.text)
                Spacer()
                if shortcuts.isChanged(command) {
                    Button {
                        shortcuts.reset(command)
                        note = nil
                    } label: {
                        Image(systemName: "arrow.uturn.backward").font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(GhostButtonStyle(padding: 4))
                    .help("Back to \(command.defaultShortcut.display)")
                }
                ShortcutRecorder(shortcut: shortcuts.shortcut(command), isRecording: recording == command) {
                    recording = recording == command ? nil : command
                } onRecord: { result in
                    recording = nil
                    switch result {
                    case .set(let shortcut):
                        if let owner = Shortcuts.reserved(shortcut) {
                            note = (command, "\(shortcut.display) is \(owner), which can't be changed.", true)
                        } else if let taken = shortcuts.set(shortcut, for: command) {
                            note = (command, "Taken from “\(taken.title)”, which now has no shortcut.", true)
                        }
                    case .clear:
                        shortcuts.set(nil, for: command)
                    case .refused(let reason):
                        note = (command, reason, true)
                    case .cancelled:
                        break
                    }
                }
            }
            if let note, note.command == command {
                Text(note.text)
                    .font(.system(size: 11))
                    .foregroundStyle(note.isWarning ? Theme.warning : Theme.textTertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}

/// A command's keys, as a pill; click it, then press new ones.
private struct ShortcutRecorder: View {
    enum Result {
        case set(Shortcut)
        case clear
        case refused(String)
        case cancelled
    }

    let shortcut: Shortcut?
    let isRecording: Bool
    let onClick: () -> Void
    let onRecord: (Result) -> Void
    @State private var monitor: Any?
    @State private var hovering = false

    var body: some View {
        Button(action: onClick) {
            Text(isRecording ? "Press keys…" : (shortcut?.display ?? "None"))
                .font(.system(size: 12, weight: isRecording ? .regular : .medium))
                .foregroundStyle(isRecording || shortcut == nil ? Theme.textTertiary : Theme.text)
                .frame(minWidth: 84)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(isRecording ? Theme.track : (hovering ? Theme.controlHover : Theme.control),
                            in: .rect(cornerRadius: Theme.controlRadius))
                .overlay {
                    if isRecording {
                        RoundedRectangle(cornerRadius: Theme.controlRadius).strokeBorder(Theme.accent.opacity(0.6))
                    }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(isRecording ? "Press the new keys · esc to cancel · ⌫ for none" : "Click, then press new keys")
        .onChange(of: isRecording) { startOrStop() }
        .onDisappear { stop() }
    }

    private func startOrStop() {
        guard isRecording else { return stop() }
        stop()
        // Keys go here, not to the menus or the field, while recording.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            if event.keyCode == 53 && flags.isEmpty {
                onRecord(.cancelled)
            } else if event.keyCode == 51 && flags.isEmpty {
                onRecord(.clear)
            } else if let shortcut = Shortcut(event: event) {
                onRecord(.set(shortcut))
            } else {
                onRecord(.refused("Add ⌘ or ⌃ to a letter, number or symbol, so typing still works."))
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
