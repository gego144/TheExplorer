import AppKit
import Observation
import SwiftUI

/// A key and its modifiers, as stored and as shown ("⇧⌘F").
struct Shortcut: Codable, Hashable {
    /// A character ("f", "[", "1") or a named key ("down", "return", "delete", "tab", "f5"…).
    var key: String
    var command = false
    var shift = false
    var option = false
    var control = false

    static func cmd(_ key: String) -> Shortcut { Shortcut(key: key, command: true) }

    var modifiers: EventModifiers {
        var flags: EventModifiers = []
        if command { flags.insert(.command) }
        if shift { flags.insert(.shift) }
        if option { flags.insert(.option) }
        if control { flags.insert(.control) }
        return flags
    }

    private static let named: [String: (KeyEquivalent, String)] = [
        "down": (.downArrow, "↓"), "up": (.upArrow, "↑"), "left": (.leftArrow, "←"), "right": (.rightArrow, "→"),
        "return": (.return, "↩"), "delete": (.delete, "⌫"), "forwarddelete": (.deleteForward, "⌦"), "tab": (.tab, "⇥"),
        "space": (.space, "Space"), "escape": (.escape, "⎋"), "home": (.home, "↖"), "end": (.end, "↘"),
        "pageup": (.pageUp, "⇞"), "pagedown": (.pageDown, "⇟"),
    ]

    var keyEquivalent: KeyEquivalent? {
        if let (equivalent, _) = Self.named[key] { return equivalent }
        if key.hasPrefix("f"), key.count > 1, let number = Int(key.dropFirst()), (1...20).contains(number),
           let scalar = UnicodeScalar(NSF1FunctionKey + number - 1) {
            return KeyEquivalent(Character(scalar))
        }
        guard key.count == 1, let character = key.first else { return nil }
        return KeyEquivalent(character)
    }

    var keyboardShortcut: KeyboardShortcut? {
        keyEquivalent.map { KeyboardShortcut($0, modifiers: modifiers) }
    }

    /// "⌃⌥⇧⌘F", in the order macOS menus use.
    var display: String {
        var text = ""
        if control { text += "⌃" }
        if option { text += "⌥" }
        if shift { text += "⇧" }
        if command { text += "⌘" }
        if let (_, symbol) = Self.named[key] { return text + symbol }
        if key.hasPrefix("f"), key.count > 1, Int(key.dropFirst()) != nil { return text + key.uppercased() }
        return text + key.uppercased()
    }

    /// A key pressed while recording, or nil for one that can't be a shortcut. Letters, digits
    /// and punctuation need ⌘ or ⌃, so typing in a field or the list's type-to-select still works.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        command = flags.contains(.command)
        shift = flags.contains(.shift)
        option = flags.contains(.option)
        control = flags.contains(.control)
        let special: [UInt16: String] = [125: "down", 126: "up", 123: "left", 124: "right", 36: "return", 76: "return",
                                         51: "delete", 117: "forwarddelete", 48: "tab", 49: "space", 115: "home",
                                         119: "end", 116: "pageup", 121: "pagedown"]
        let functionKeys: [UInt16: Int] = [122: 1, 120: 2, 99: 3, 118: 4, 96: 5, 97: 6, 98: 7, 100: 8, 101: 9, 109: 10,
                                           103: 11, 111: 12, 105: 13, 107: 14, 113: 15]
        if let name = special[event.keyCode] {
            key = name
        } else if let number = functionKeys[event.keyCode] {
            key = "f\(number)"
        } else if let characters = event.charactersIgnoringModifiers?.lowercased(), characters.count == 1 {
            // With ⇧ held, the unshifted character ("1", not "!").
            key = (event.characters(byApplyingModifiers: []) ?? characters).lowercased()
            guard command || control, key.count == 1 else { return nil }
        } else {
            return nil
        }
        // Space and the arrows alone belong to the list.
        if !command && !control && !option && ["space", "up", "down", "left", "right", "return", "tab", "delete"].contains(key) { return nil }
    }

    init(key: String, command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false) {
        self.key = key
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
    }
}

/// Every command whose shortcut can be changed, with its default.
enum ShortcutCommand: String, CaseIterable, Identifiable {
    // File
    case newTab, openInNewTab, closeTab, newFolder, newFile, openInTerminal
    // Edit
    case copyPath, find, goAnywhere
    // Item
    case open, quickLook, showInEnclosingFolder, revealInFinder, pin, rename, moveToTrash, copyToOtherPane, moveToOtherPane
    // View
    case toggleSidebar, toggleInspector, toggleHidden, asList, asGallery, biggerThumbnails, smallerThumbnails, splitPane, refresh
    // Go
    case back, forward, enclosingFolder, recents, newFiles, storage, home, desktop, documents, downloads, applications,
         goToPath, goToFolder
    // Window
    case nextTab, previousTab

    var id: String { rawValue }

    enum Group: String, CaseIterable {
        case file = "File", edit = "Edit", item = "Item", view = "View", go = "Go", window = "Window"
    }

    var group: Group {
        switch self {
        case .newTab, .openInNewTab, .closeTab, .newFolder, .newFile, .openInTerminal: .file
        case .copyPath, .find, .goAnywhere: .edit
        case .open, .quickLook, .showInEnclosingFolder, .revealInFinder, .pin, .rename, .moveToTrash,
             .copyToOtherPane, .moveToOtherPane: .item
        case .toggleSidebar, .toggleInspector, .toggleHidden, .asList, .asGallery, .biggerThumbnails,
             .smallerThumbnails, .splitPane, .refresh: .view
        case .back, .forward, .enclosingFolder, .recents, .newFiles, .storage, .home, .desktop, .documents,
             .downloads, .applications, .goToPath, .goToFolder: .go
        case .nextTab, .previousTab: .window
        }
    }

    var title: String {
        switch self {
        case .newTab: "New Tab"
        case .openInNewTab: "Open in New Tab"
        case .closeTab: "Close Tab or Pane"
        case .newFolder: "New Folder"
        case .newFile: "New File"
        case .openInTerminal: "Open in Terminal"
        case .copyPath: "Copy Path"
        case .find: "Find"
        case .goAnywhere: "Go Anywhere"
        case .open: "Open"
        case .quickLook: "Quick Look"
        case .showInEnclosingFolder: "Show in Enclosing Folder"
        case .revealInFinder: "Reveal in Finder"
        case .pin: "Pin / Unpin"
        case .rename: "Rename"
        case .moveToTrash: "Move to Trash"
        case .copyToOtherPane: "Copy to Other Pane"
        case .moveToOtherPane: "Move to Other Pane"
        case .toggleSidebar: "Show or Hide Sidebar"
        case .toggleInspector: "Show or Hide Details"
        case .toggleHidden: "Show or Hide Hidden Files"
        case .asList: "as List"
        case .asGallery: "as Gallery"
        case .biggerThumbnails: "Bigger Thumbnails"
        case .smallerThumbnails: "Smaller Thumbnails"
        case .splitPane: "Split Pane"
        case .refresh: "Refresh"
        case .back: "Back"
        case .forward: "Forward"
        case .enclosingFolder: "Enclosing Folder"
        case .recents: "Recents"
        case .newFiles: "New"
        case .storage: "Storage"
        case .home: "Home"
        case .desktop: "Desktop"
        case .documents: "Documents"
        case .downloads: "Downloads"
        case .applications: "Applications"
        case .goToPath: "Go to Path"
        case .goToFolder: "Go to Folder"
        case .nextTab: "Next Tab"
        case .previousTab: "Previous Tab"
        }
    }

    var defaultShortcut: Shortcut {
        switch self {
        case .newTab: .cmd("t")
        case .openInNewTab: Shortcut(key: "down", command: true, option: true)
        case .closeTab: .cmd("w")
        case .newFolder: Shortcut(key: "n", command: true, shift: true)
        case .newFile: Shortcut(key: "n", command: true, option: true)
        case .openInTerminal: Shortcut(key: "t", command: true, control: true)
        case .copyPath: Shortcut(key: "c", command: true, option: true)
        case .find: .cmd("f")
        case .goAnywhere: .cmd("k")
        case .open: Shortcut(key: "down", command: true)
        case .quickLook: .cmd("y")
        case .showInEnclosingFolder: .cmd("r")
        case .revealInFinder: Shortcut(key: "r", command: true, option: true)
        case .pin: .cmd("d")
        case .rename: Shortcut(key: "return", command: true, shift: true)
        case .moveToTrash: Shortcut(key: "delete", command: true)
        case .copyToOtherPane: Shortcut(key: "f5")
        case .moveToOtherPane: Shortcut(key: "f6")
        case .toggleSidebar: Shortcut(key: "s", command: true, option: true)
        case .toggleInspector: .cmd("i")
        case .toggleHidden: Shortcut(key: ".", command: true, shift: true)
        case .asList: Shortcut(key: "1", command: true, option: true)
        case .asGallery: Shortcut(key: "2", command: true, option: true)
        case .biggerThumbnails: .cmd("=")
        case .smallerThumbnails: .cmd("-")
        case .splitPane: .cmd("/")
        case .refresh: Shortcut(key: "r", command: true, shift: true)
        case .back: .cmd("[")
        case .forward: .cmd("]")
        case .enclosingFolder: Shortcut(key: "up", command: true)
        case .recents: Shortcut(key: "f", command: true, shift: true)
        case .newFiles: Shortcut(key: "e", command: true, shift: true)
        case .storage: Shortcut(key: "b", command: true, shift: true)
        case .home: Shortcut(key: "h", command: true, shift: true)
        case .desktop: Shortcut(key: "d", command: true, shift: true)
        case .documents: Shortcut(key: "o", command: true, shift: true)
        case .downloads: Shortcut(key: "l", command: true, option: true)
        case .applications: Shortcut(key: "a", command: true, shift: true)
        case .goToPath: .cmd("l")
        case .goToFolder: Shortcut(key: "g", command: true, shift: true)
        case .nextTab: Shortcut(key: "tab", control: true)
        case .previousTab: Shortcut(key: "tab", shift: true, control: true)
        }
    }
}

/// The shortcuts in use: each command's default unless you changed it in Settings › Shortcuts.
/// The menus read from here, so a change applies at once.
@MainActor
@Observable
final class Shortcuts {
    static let shared = Shortcuts()

    /// Changed ones: a new shortcut, or nil for none.
    private(set) var changes: [String: Shortcut?] = [:]
    /// The command whose new keys Settings › Shortcuts is waiting for.
    var recording: ShortcutCommand?
    @ObservationIgnored private let defaults: UserDefaults
    private static let key = "shortcuts"

    /// Keys that can't be changed, shown on the page so the whole set is in one place.
    static let fixed: [(title: String, keys: String)] = [
        ("Undo / Redo", "⌘Z / ⇧⌘Z"), ("Cut / Copy / Paste / Paste and Move Here", "⌘X / ⌘C / ⌘V / ⌥⌘V"), ("Select All", "⌘A"),
        ("Go to Tab 1–8, Last Tab", "⌘1–⌘9"), ("Quick Look the selection", "Space"), ("Open the selection", "↩"),
        ("Switch pane", "⇥"), ("Expand / Collapse a folder", "→ / ←"),
    ]

    /// Keys macOS and the fixed commands already use, which can't be given to anything else.
    static func reserved(_ shortcut: Shortcut) -> String? {
        let plain = shortcut.command && !shortcut.shift && !shortcut.option && !shortcut.control
        if plain {
            switch shortcut.key {
            case "q": return "Quit"
            case "h": return "Hide TheExplorer"
            case "m": return "Minimize"
            case ",": return "Settings"
            case "z": return "Undo"
            case "x": return "Cut"
            case "c": return "Copy"
            case "v": return "Paste"
            case "a": return "Select All"
            case "`": return "switching windows"
            case "1", "2", "3", "4", "5", "6", "7", "8", "9": return "going to a tab"
            default: return nil
            }
        }
        if shortcut == Shortcut(key: "z", command: true, shift: true) { return "Redo" }
        if shortcut == Shortcut(key: "h", command: true, option: true) { return "Hide Others" }
        if shortcut == Shortcut(key: "v", command: true, option: true) { return "Paste and Move Here" }
        return nil
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([String: Shortcut?].self, from: data) {
            changes = saved
        }
    }

    /// The shortcut for a command now (nil when it has none).
    func shortcut(_ command: ShortcutCommand) -> Shortcut? {
        if let changed = changes[command.rawValue] { return changed }
        return command.defaultShortcut
    }

    func keyboardShortcut(_ command: ShortcutCommand) -> KeyboardShortcut? {
        shortcut(command)?.keyboardShortcut
    }

    func isChanged(_ command: ShortcutCommand) -> Bool { changes[command.rawValue] != nil }

    /// The other command already using `shortcut`, if any.
    func command(using shortcut: Shortcut, besides command: ShortcutCommand) -> ShortcutCommand? {
        ShortcutCommand.allCases.first { $0 != command && self.shortcut($0) == shortcut }
    }

    /// Gives `command` a new shortcut (nil for none). One already used by another command moves:
    /// that command is left without one, and is returned so the page can say so.
    @discardableResult
    func set(_ shortcut: Shortcut?, for command: ShortcutCommand) -> ShortcutCommand? {
        var taken: ShortcutCommand?
        if let shortcut, let other = self.command(using: shortcut, besides: command) {
            assign(nil, to: other)
            taken = other
        }
        assign(shortcut, to: command)
        save()
        return taken
    }

    func reset(_ command: ShortcutCommand) {
        changes[command.rawValue] = nil
        // Its default may be in use by another command now; that one gives it up.
        if let other = self.command(using: command.defaultShortcut, besides: command) { assign(nil, to: other) }
        save()
    }

    func resetAll() {
        changes = [:]
        save()
    }

    private func assign(_ shortcut: Shortcut?, to command: ShortcutCommand) {
        changes[command.rawValue] = shortcut == command.defaultShortcut ? nil : .some(shortcut)
    }

    private func save() {
        if changes.isEmpty {
            defaults.removeObject(forKey: Self.key)
        } else if let data = try? JSONEncoder().encode(changes) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
