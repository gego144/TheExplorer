import Foundation
import Testing
@testable import TheExplorer

/// Quitting keeps where each tab was, S3 and Google Drive included, and launching goes back.
@MainActor
struct SessionRestoreTests {
    @Test func cloudPlacesAreSavedAndReopened() {
        let drive = DriveLocation(accountID: UUID(), id: "folder123", name: "Receipts")
        let s3 = S3Location(connectionID: UUID(), bucket: "media", prefix: "uploads/2026/")

        let drivePane = BrowserModel(url: URL.home)
        drivePane.navigate(to: drive.url)
        let s3Pane = BrowserModel(url: URL.home)
        s3Pane.navigate(to: s3.url)
        let local = BrowserModel(url: URL.home)

        // Saved as their addresses, not the folder on the Mac the pane last showed.
        #expect(WindowState.place(of: drivePane) == drive.url.absoluteString)
        #expect(WindowState.place(of: s3Pane) == s3.url.absoluteString)
        #expect(WindowState.place(of: local) == URL.home.path)

        // And reopened there.
        let reopenedDrive = WindowState.pane(at: WindowState.place(of: drivePane))
        #expect(reopenedDrive.destination == .drive)
        #expect(reopenedDrive.drive.location?.id == "folder123")
        #expect(reopenedDrive.drive.location?.name == "Receipts")
        let reopenedS3 = WindowState.pane(at: WindowState.place(of: s3Pane))
        #expect(reopenedS3.destination == .s3)
        #expect(reopenedS3.s3.location == s3)
        // Nothing to go back to on launch.
        #expect(reopenedDrive.backStack.isEmpty && reopenedS3.backStack.isEmpty)
    }

    @Test func aWindowWithCloudTabsComesBackWhole() {
        let drive = DriveLocation(accountID: UUID(), id: "folder123", name: "Receipts")
        let state = WindowState(paths: [drive.url.absoluteString, URL.home.path, "/no/such/folder"], selected: 0,
                                splits: [URL.home.path, nil, nil], splitFractions: nil)
        let workspace = Workspace(state: state)
        // The missing folder is left out; the Drive tab is first, split with the home folder.
        #expect(workspace.tabs.count == 2)
        #expect(workspace.currentTab.destination == .drive)
        #expect(workspace.secondPane(of: workspace.currentTab)?.currentURL == URL.home)
        // Saving again gives the same places.
        #expect(workspace.state.paths == [drive.url.absoluteString, URL.home.path])
        #expect(workspace.state.splits == [URL.home.path, nil])
    }

    @Test func onlyCloudAddressesCountAsCloud() {
        #expect(WindowState.cloudURL("/Users/me/Documents") == nil)
        #expect(WindowState.cloudURL("x-s3://abc/bucket/") != nil)
        #expect(WindowState.canRestore(URL.home.path))
        #expect(!WindowState.canRestore("/no/such/folder"))
    }
}
