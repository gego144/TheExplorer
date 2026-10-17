import Foundation
import Testing
@testable import TheExplorer

@MainActor
struct SplitPaneTests {
    private let root: URL
    private let left: URL
    private let right: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("split-\(UUID().uuidString)")
        left = root.appendingPathComponent("Left")
        right = root.appendingPathComponent("Right")
        try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: right, withIntermediateDirectories: true)
    }

    private func workspace() -> Workspace {
        Workspace(state: WindowState(paths: [left.path], selected: 0))
    }

    @Test func splittingAddsAnActiveSecondPaneOnTheSameFolder() {
        let workspace = workspace()
        let first = workspace.currentTab
        workspace.toggleSplit()
        let second = try! #require(workspace.secondPane(of: first))
        #expect(workspace.selected === second)
        #expect(second.currentURL == first.currentURL)
        #expect(workspace.otherPane === first)
        workspace.switchPane()
        #expect(workspace.selected === first)
        workspace.toggleSplit()
        #expect(!workspace.isSplit)
        #expect(workspace.selected === first)
    }

    @Test func closingTheFirstPaneLeavesTheSecond() {
        let workspace = workspace()
        workspace.toggleSplit()
        let second = workspace.selected
        second.navigate(to: right)
        workspace.activate(workspace.currentTab)
        #expect(workspace.closeActivePane())
        #expect(!workspace.isSplit)
        #expect(workspace.currentTab === second)
        #expect(workspace.tabs.count == 1)
    }

    @Test func swappingKeepsTheSamePaneActive() {
        let workspace = workspace()
        let first = workspace.currentTab
        workspace.toggleSplit()
        let second = workspace.selected
        workspace.swapPanes()
        #expect(workspace.currentTab === second)
        #expect(workspace.secondPane(of: second) === first)
        #expect(workspace.selected === second)
    }

    @Test func splitsAreSavedAndRestored() {
        let workspace = workspace()
        workspace.toggleSplit()
        workspace.selected.navigate(to: right)
        let state = workspace.state
        #expect(state.splits == [right.path])
        let restored = Workspace(state: state)
        #expect(restored.secondPane(of: restored.currentTab)?.currentURL.path == right.path)
        // Windows saved before split panes existed still open.
        let old = try! JSONDecoder().decode(WindowState.self, from: Data(#"{"id":"\#(UUID().uuidString)","paths":["\#(left.path)"],"selected":0}"#.utf8))
        #expect(Workspace(state: old).isSplit == false)
    }

    @Test func dividerPositionIsKeptClampedSwappedAndSaved() {
        let workspace = workspace()
        workspace.toggleSplit()
        let first = workspace.currentTab
        #expect(workspace.splitFraction(of: first) == 0.5)
        workspace.setSplitFraction(0.02, of: first)
        #expect(workspace.splitFraction(of: first) == 0.15)
        workspace.setSplitFraction(0.7, of: first)
        workspace.swapPanes()
        #expect(abs(workspace.splitFraction(of: workspace.currentTab) - 0.3) < 0.0001)
        let restored = Workspace(state: workspace.state)
        #expect(abs(restored.splitFraction(of: restored.currentTab) - 0.3) < 0.0001)
        workspace.setSplitFraction(nil, of: workspace.currentTab)
        #expect(workspace.splitFraction(of: workspace.currentTab) == 0.5)
    }

    @Test func otherPaneTargetsItsFolder() {
        let workspace = workspace()
        workspace.toggleSplit()
        let second = workspace.selected
        second.navigate(to: right)
        #expect(workspace.dropFolder(of: workspace.currentTab)?.path == left.path)
        #expect(workspace.pane(oppositeTo: second) === workspace.currentTab)
        second.show(.recents)
        #expect(workspace.dropFolder(of: second) == nil)
        // Nothing selected: nothing to send.
        #expect(!workspace.sendToOtherPane(from: workspace.currentTab, mode: .copy))
    }
}
