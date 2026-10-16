import Foundation
import Testing
@testable import TheExplorer

private func row(_ name: String, folder: Bool = false, size: Int64? = nil, modified: TimeInterval = 0) -> ListRow {
    let item = FileItem(url: URL(fileURLWithPath: "/x/\(name)"), name: name, isDirectory: folder,
                        fileSize: folder ? nil : size, modified: Date(timeIntervalSince1970: modified))
    return ListRow(item: item, size: folder ? nil : size, liveFolderSize: folder, date: item.modified)
}

@MainActor
struct RowSorterTests {
    @Test func namesSortNaturallyWithFoldersFirst() {
        let rows = [row("file 10"), row("b", folder: true), row("file 2"), row("A", folder: true)]
        let sorted = RowSorter.sorted(rows, by: SortSpec(key: .name, ascending: true), foldersFirst: true)
        #expect(sorted.map(\.item.name) == ["A", "b", "file 2", "file 10"])
    }

    @Test func newestFirstBreaksTiesByName() {
        let rows = [row("old", modified: 1), row("b", modified: 5), row("a", modified: 5)]
        let sorted = RowSorter.sorted(rows, by: .byChanged)
        #expect(sorted.map(\.item.name) == ["a", "b", "old"])
    }

    @Test func sizeUsesMeasuredFolderSizesAndPutsUnknownLast() {
        let rows = [row("small", size: 10), row("unmeasured", folder: true), row("big", folder: true), row("mid", size: 500)]
        let sorted = RowSorter.sorted(rows, by: SortSpec(key: .size, ascending: false)) { path in
            path.hasSuffix("/big") ? 1_000 : nil
        }
        #expect(sorted.map(\.item.name) == ["big", "mid", "small", "unmeasured"])
    }
}

struct SearchRankTests {
    @Test func exactThenPrefixThenWordStartThenAnywhere() {
        #expect(SearchModel.rank(name: "Report.pdf", terms: ["report"]) == 0)
        #expect(SearchModel.rank(name: "reports", terms: ["report"]) == 1)
        #expect(SearchModel.rank(name: "q3-report.pdf", terms: ["report"]) == 2)
        #expect(SearchModel.rank(name: "misreported", terms: ["report"]) == 3)
    }

    @Test func noisyPathsRankLower() {
        #expect(PathNoise.isNoisy("/Users/me/Dev/app/node_modules/react/index.js"))
        #expect(PathNoise.isNoisy("/Users/me/Dev/app/.git/HEAD"))
        #expect(!PathNoise.isNoisy("/Users/me/Dev/app/src/index.js"))
    }
}

@MainActor
struct DragAndDropTests {
    @Test func multiDragCarriesTheSelectionInListOrder() {
        let rows = ["video8.ts", "video7.ts", "video5.ts", "video.m3u8", "video6.ts"].map { row($0) }
        let selection: Set<URL> = [rows[4].id, rows[0].id, rows[2].id]
        #expect(MultiDragSource.dragged(rows: rows, selection: selection).map(\.lastPathComponent) == ["video8.ts", "video5.ts", "video6.ts"])
    }

    @Test func dropsFindTheRowUnderTheCursor() {
        let frames = RowFrames()
        frames.frames[URL(fileURLWithPath: "/x/dest")] = CGRect(x: 0, y: 30, width: 400, height: 28)
        frames.frames[URL(fileURLWithPath: "/x/a.txt")] = CGRect(x: 0, y: 59, width: 400, height: 28)
        #expect(frames.row(at: CGPoint(x: 100, y: 40))?.lastPathComponent == "dest")
        #expect(frames.row(at: CGPoint(x: 100, y: 70))?.lastPathComponent == "a.txt")
        #expect(frames.row(at: CGPoint(x: 100, y: 300)) == nil)
    }
}
