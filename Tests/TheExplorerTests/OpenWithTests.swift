import Foundation
import Testing
@testable import TheExplorer

@MainActor
struct OpenWithTests {
    private let preview = "com.apple.Preview"
    private let textEdit = "com.apple.TextEdit"

    @Test func firstRuleListingAnExtensionWins() {
        let rules = OpenWithRules(defaults: nil)
        rules.add(extensions: ["png", "jpg"], appID: preview)
        let later = rules.add(extensions: ["PNG", "txt"].map { $0.lowercased() }, appID: textEdit)
        #expect(rules.appID(forExtension: "PNG") == preview)
        #expect(rules.appID(forExtension: "txt") == textEdit)
        #expect(rules.appID(forExtension: "gif") == nil)
        #expect(rules.duplicates(in: later) == ["png"])
    }

    @Test func rulesWithoutAnInstalledAppAreSkipped() {
        let rules = OpenWithRules(defaults: nil)
        rules.add(extensions: ["png"], appID: "com.example.not-installed")
        rules.add(extensions: ["png"], appID: "")
        #expect(rules.appID(forExtension: "png") == nil)
    }

    @Test func alwaysOpenWithMovesTheExtension() {
        let rules = OpenWithRules(defaults: nil)
        rules.add(extensions: ["png"], appID: preview)
        rules.setApp(textEdit, forExtension: "PNG")
        #expect(rules.appID(forExtension: "png") == textEdit)
        // Preview's rule had nothing left, so it's gone.
        #expect(rules.rules.map(\.appID) == [textEdit])
        rules.clear("png")
        #expect(rules.rules.isEmpty)
        #expect(rules.appID(forExtension: "png") == nil)
    }

    @Test func savesAndLoads() throws {
        let suite = "OpenWithTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        OpenWithRules(defaults: defaults).add(extensions: ["md"], appID: textEdit)
        #expect(OpenWithRules(defaults: defaults).rules.map(\.extensions) == [["md"]])
    }

    @Test func listsAppsThatCanOpenAFile() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("open-with-\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let ids = FileOpener.apps(for: [file]).compactMap(FileOpener.bundleID)
        #expect(ids.contains(textEdit))
        #expect(Set(ids).count == ids.count)
        #expect(FileOpener.apps(forExtension: "txt").compactMap(FileOpener.bundleID).contains(textEdit))
    }
}
