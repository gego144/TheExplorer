import AppKit
import Testing
@testable import TheExplorer

/// Settings › Shortcuts: changed keys are kept, move from another command, and reset.
@MainActor
struct ShortcutsTests {
    private func store() -> (Shortcuts, UserDefaults) {
        let defaults = UserDefaults(suiteName: "shortcuts-\(UUID().uuidString)")!
        return (Shortcuts(defaults: defaults), defaults)
    }

    @Test func defaultsUntilChanged() {
        let (shortcuts, _) = store()
        #expect(shortcuts.shortcut(.find) == .cmd("f"))
        #expect(shortcuts.shortcut(.find)?.display == "⌘F")
        #expect(shortcuts.shortcut(.moveToTrash)?.display == "⌘⌫")
        #expect(shortcuts.shortcut(.copyToOtherPane)?.display == "F5")
        #expect(shortcuts.keyboardShortcut(.nextTab) != nil)
        #expect(!shortcuts.isChanged(.find))
    }

    @Test func changesAreKeptAcrossLaunches() {
        let (shortcuts, defaults) = store()
        shortcuts.set(Shortcut(key: "e", command: true, shift: true), for: .find)
        shortcuts.set(nil, for: .quickLook)
        let reopened = Shortcuts(defaults: defaults)
        #expect(reopened.shortcut(.find)?.display == "⇧⌘E")
        #expect(reopened.shortcut(.quickLook) == nil)
        #expect(reopened.isChanged(.quickLook))
    }

    @Test func keysTakenFromAnotherCommandLeaveItWithout() {
        let (shortcuts, _) = store()
        let taken = shortcuts.set(.cmd("k"), for: .find)
        #expect(taken == .goAnywhere)
        #expect(shortcuts.shortcut(.goAnywhere) == nil)
        #expect(shortcuts.shortcut(.find) == .cmd("k"))
        // Resetting Find gives ⌘F back; ⌘K stays free until Go Anywhere is reset too.
        shortcuts.reset(.find)
        #expect(shortcuts.shortcut(.find) == .cmd("f"))
        shortcuts.reset(.goAnywhere)
        #expect(shortcuts.shortcut(.goAnywhere) == .cmd("k"))
        #expect(shortcuts.changes.isEmpty)
    }

    @Test func resettingTakesItsDefaultBack() {
        let (shortcuts, _) = store()
        shortcuts.set(.cmd("y"), for: .find)          // Quick Look loses ⌘Y
        shortcuts.set(.cmd("f"), for: .quickLook)     // and takes ⌘F, which Find no longer uses
        shortcuts.reset(.find)                         // Find wants ⌘F back from Quick Look
        #expect(shortcuts.shortcut(.find) == .cmd("f"))
        #expect(shortcuts.shortcut(.quickLook) == nil)
        shortcuts.resetAll()
        #expect(shortcuts.shortcut(.quickLook) == .cmd("y"))
    }

    @Test func systemKeysAreReserved() {
        #expect(Shortcuts.reserved(.cmd("q")) == "Quit")
        #expect(Shortcuts.reserved(.cmd(",")) == "Settings")
        #expect(Shortcuts.reserved(.cmd("3")) == "going to a tab")
        #expect(Shortcuts.reserved(Shortcut(key: "z", command: true, shift: true)) == "Redo")
        #expect(Shortcuts.reserved(.cmd("e")) == nil)
        #expect(Shortcuts.reserved(Shortcut(key: "q", command: true, shift: true)) == nil)
        // No default clashes with them.
        #expect(ShortcutCommand.allCases.allSatisfy { Shortcuts.reserved($0.defaultShortcut) == nil })
        // And no two commands share a default.
        #expect(Set(ShortcutCommand.allCases.map(\.defaultShortcut)).count == ShortcutCommand.allCases.count)
    }

    @Test func recordingReadsTheKeysPressed() {
        func press(_ characters: String, keyCode: UInt16, _ flags: NSEvent.ModifierFlags) -> Shortcut? {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                                         context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                         isARepeat: false, keyCode: keyCode)!
            return Shortcut(event: event)
        }
        #expect(press("e", keyCode: 14, [.command, .shift])?.display == "⇧⌘E")
        #expect(press("\u{F700}", keyCode: 126, [.command, .option])?.display == "⌥⌘↑")
        #expect(press("\u{F708}", keyCode: 96, [])?.display == "F5")
        // A letter alone would get in the way of typing; so would Space or an arrow alone.
        #expect(press("e", keyCode: 14, []) == nil)
        #expect(press("e", keyCode: 14, [.shift]) == nil)
        #expect(press(" ", keyCode: 49, []) == nil)
        #expect(press("\u{F701}", keyCode: 125, []) == nil)
    }
}
