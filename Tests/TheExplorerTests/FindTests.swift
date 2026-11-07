import Foundation
import Testing
@testable import TheExplorer

/// Find (⌘F) searches where you are; ⌘K hands searches over to it.
@MainActor
struct FindTests {
    private let root: URL
    private let other: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("find-\(UUID().uuidString)")
        other = root.appendingPathComponent("Other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    }

    @Test func aFreshFindSearchesTheFolderYouAreIn() {
        let model = BrowserModel(url: root)
        model.searchScope = .mac
        model.openFind()
        #expect(model.isFinding)
        #expect(model.searchScope == .folder)
        #expect(model.searchText.isEmpty)
        #expect(model.findScopeName == root.lastPathComponent)
    }

    @Test func outsideAFolderItSearchesYourMac() {
        let model = BrowserModel(url: root)
        model.show(.recents)
        model.openFind()
        #expect(model.searchScope == .mac)
        #expect(model.findScopeName == "your Mac")
    }

    /// ⌘K's Find line: the text is searched at once and the list takes the keyboard.
    @Test func aHandedOverSearchRunsAndFocusesTheList() {
        let model = BrowserModel(url: root)
        let focus = model.listFocusRequest
        model.openFind("receipts")
        #expect(model.searchText == "receipts")
        #expect(model.isSearching)
        #expect(model.listFocusRequest == focus + 1)
        model.openFind("receipts", everywhere: true)
        #expect(model.searchScope == .mac)
    }

    @Test func goingSomewhereElseEndsTheSearch() {
        let model = BrowserModel(url: root)
        model.openFind("x")
        model.navigate(to: other)
        #expect(!model.isFinding)
        #expect(model.searchText.isEmpty)
    }

    @Test func endFindClearsIt() {
        let model = BrowserModel(url: root)
        model.openFind("x")
        model.endFind()
        #expect(!model.isFinding && model.searchText.isEmpty && !model.isSearching)
    }
}
