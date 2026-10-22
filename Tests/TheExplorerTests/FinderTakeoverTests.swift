import Foundation
import Testing
@testable import TheExplorer

struct FinderTakeoverTests {
    @Test func frontWindowOpensLastWithItsSelection() {
        let windows = FinderWindows(folders: ["/Users/me/Downloads/", "/Users/me/Pictures/"],
                                    selection: ["/Users/me/Downloads/report.pdf", "/Users/me/Downloads/Photos/"])
        let openings = windows.openings
        #expect(openings.count == 2)
        // Behind first, so the front window's folder ends up in front.
        #expect(openings[0] == .init(urls: [URL(fileURLWithPath: "/Users/me/Pictures", isDirectory: true)], revealing: false))
        #expect(openings[1].revealing)
        #expect(openings[1].urls.map(\.lastPathComponent) == ["report.pdf", "Photos"])
    }

    @Test func aSelectionElsewhereIsLeftOut() {
        // With the desktop in front, Finder's selection is on the desktop, not in the window.
        let windows = FinderWindows(folders: ["/Users/me/Downloads/"], selection: ["/Users/me/Desktop/notes.txt"])
        #expect(windows.openings == [.init(urls: [URL(fileURLWithPath: "/Users/me/Downloads", isDirectory: true)], revealing: false)])
    }

    @Test func theSameFolderTwiceOpensOnce() {
        let windows = FinderWindows(folders: ["/Users/me/Downloads/", "/Users/me/Downloads/"], selection: [])
        #expect(windows.openings.count == 1)
        #expect(FinderWindows(folders: [], selection: ["/x"]).openings.isEmpty)
    }
}
