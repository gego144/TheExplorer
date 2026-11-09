import AppKit
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
    @Test func folderWalkScoresLikeTheIndex() throws {
        let tokens = FuzzyMatcher.tokens("report")
        let stem = try #require(FuzzyMatcher.score(tokens, name: "Report.pdf"))
        let prefix = try #require(FuzzyMatcher.score(tokens, name: "reports"))
        let wordStart = try #require(FuzzyMatcher.score(tokens, name: "q3-report.pdf"))
        let middle = try #require(FuzzyMatcher.score(tokens, name: "misreported"))
        #expect(stem > prefix && prefix > wordStart && wordStart > middle)
        // Every word has to match.
        #expect(FuzzyMatcher.score(FuzzyMatcher.tokens("report q3"), name: "q3-report.pdf") != nil)
        #expect(FuzzyMatcher.score(FuzzyMatcher.tokens("report zebra"), name: "q3-report.pdf") == nil)
    }

    @Test func noisyPathsRankLower() {
        #expect(PathNoise.isNoisy("/Users/me/Dev/app/node_modules/react/index.js"))
        #expect(PathNoise.isNoisy("/Users/me/Dev/app/.git/HEAD"))
        #expect(!PathNoise.isNoisy("/Users/me/Dev/app/src/index.js"))
    }
}

@MainActor
struct FileTableTests {
    private func controller(_ rows: [ListRow], selection: Set<URL> = [], onSelect: @escaping (Set<URL>) -> Void = { _ in }) -> FileTableController {
        let controller = FileTableController()
        var config = FileTableController.Config()
        config.setSelection = onSelect
        controller.update(rows: rows, selection: selection, focusRequest: 0, config: config)
        return controller
    }

    @Test func groupHeadersSitAboveTheirRowsAndCantBeSelected() {
        var rows = ["a.txt", "b.txt", "c.txt"].map { row($0) }
        rows[0].group = "Today"
        rows[2].group = "Yesterday"
        let table = controller(rows)
        #expect(table.numberOfRows(in: table.table) == 5)
        #expect(table.row(atLine: 0) == nil)
        #expect(table.row(atLine: 1)?.item.name == "a.txt")
        #expect(table.row(atLine: 3) == nil)
        #expect(table.row(atLine: 4)?.item.name == "c.txt")
        #expect(table.tableView(table.table, shouldSelectRow: 1))
        #expect(!table.tableView(table.table, shouldSelectRow: 3))
        #expect(table.tableView(table.table, selectionIndexesForProposedSelection: [0, 1, 2, 3, 4]) == [1, 2, 4])
    }

    @Test func dragsCarryEachFileInListOrder() {
        let rows = ["video8.ts", "video7.ts", "video5.ts"].map { row($0) }
        var withGroup = rows
        withGroup[0].group = "Today"
        let table = controller(withGroup)
        let written = (1...3).compactMap { table.tableView(table.table, pasteboardWriterForRow: $0) as? NSURL }
        #expect(written.map { ($0 as URL).lastPathComponent } == ["video8.ts", "video7.ts", "video5.ts"])
        #expect(table.tableView(table.table, pasteboardWriterForRow: 0) == nil)
    }

    @Test func selectionGoesBothWays() async {
        let rows = ["a.txt", "b.txt", "c.txt"].map { row($0) }
        var told: Set<URL>?
        let table = controller(rows, selection: [rows[1].id]) { told = $0 }
        #expect(table.table.selectedRowIndexes == [1])
        // Picking rows in the table tells SwiftUI on the next turn of the run loop.
        table.table.selectRowIndexes([0, 2], byExtendingSelection: false)
        #expect(told == nil)
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(told == [rows[0].id, rows[2].id])
    }

    @Test func dropsReadFilesAndRemoteItems() {
        let pasteboard = NSPasteboard(name: .init("FileTableTests-\(UUID().uuidString)"))
        let file = URL(fileURLWithPath: "/x/a.txt")
        let remote = URL(string: "s3://connection/bucket/key.txt")!
        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL, remote as NSURL])
        #expect(FileTableController.urls(from: pasteboard) == [file, remote])
        pasteboard.releaseGlobally()
    }

    /// A drag over the list, at a point in the window.
    private final class FakeDrag: NSObject, NSDraggingInfo {
        let draggingPasteboard: NSPasteboard
        let draggingLocation: NSPoint
        init(urls: [URL], at point: NSPoint) {
            draggingPasteboard = NSPasteboard(name: .init("FileTableDrag-\(UUID().uuidString)"))
            draggingPasteboard.clearContents()
            draggingPasteboard.writeObjects(urls.map { $0 as NSURL })
            draggingLocation = point
        }
        var draggingDestinationWindow: NSWindow? { nil }
        var draggingSourceOperationMask: NSDragOperation { [.copy, .move, .generic] }
        var draggedImageLocation: NSPoint { draggingLocation }
        var draggedImage: NSImage? { nil }
        var draggingSource: Any? { nil }
        var draggingSequenceNumber: Int { 1 }
        func slideDraggedImage(to screenPoint: NSPoint) {}
        var draggingFormation: NSDraggingFormation = .default
        var animatesToDestination = false
        var numberOfValidItemsForDrop = 1
        func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                    classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                    using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
        var springLoadingHighlight: NSSpringLoadingHighlight { .none }
        func resetSpringLoading() {}
    }

    @Test func dropsGoIntoTheFolderUnderTheCursorOrTheFolderShown() {
        let rows = [row("dest", folder: true), row("a.txt"), row("b.txt")]
        var into: (urls: [URL], folder: URL)?
        var background: [URL]?
        let table = FileTableController()
        var config = FileTableController.Config()
        config.onDropInto = { urls, folder in into = (urls, folder); return true }
        config.onDropBackground = { urls in background = urls; return true }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = table.scrollView
        table.scrollView.frame = window.contentView!.bounds
        table.update(rows: rows, selection: [], focusRequest: 0, config: config)
        table.scrollView.layoutSubtreeIfNeeded()
        func point(onLine line: Int) -> NSPoint {
            let rect = table.table.rect(ofRow: line)
            return table.table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        }
        let dragged = [URL(fileURLWithPath: "/elsewhere/photo.jpg")]

        // Over the folder row: into that folder.
        let overFolder = FakeDrag(urls: dragged, at: point(onLine: 0))
        #expect(table.tableView(table.table, validateDrop: overFolder, proposedRow: 0, proposedDropOperation: .on) == .move)
        #expect(table.dropLine == 0)
        #expect(table.tableView(table.table, acceptDrop: overFolder, row: 0, dropOperation: .on))
        #expect(into?.folder.lastPathComponent == "dest")
        #expect(into?.urls == dragged)

        // Over a file row: into the folder shown.
        let overFile = FakeDrag(urls: dragged, at: point(onLine: 1))
        #expect(table.tableView(table.table, validateDrop: overFile, proposedRow: 1, proposedDropOperation: .on) == .move)
        #expect(table.dropLine == nil && table.dropOnBackground)
        #expect(table.tableView(table.table, acceptDrop: overFile, row: 1, dropOperation: .on))
        #expect(background == dragged)
        #expect(!table.dropOnBackground)

        // A folder dragged over itself goes nowhere: not into itself, and not into the folder
        // shown, where it already is.
        let ownFolder = FakeDrag(urls: [rows[0].id], at: point(onLine: 0))
        #expect(table.tableView(table.table, validateDrop: ownFolder, proposedRow: 0, proposedDropOperation: .on) == [])
        #expect(table.dropLine == nil && !table.dropOnBackground)

        // Files from this list: into a folder beside them, yes; dropped back among themselves, no.
        let siblings = [rows[1].id, rows[2].id]
        let siblingsOverFolder = FakeDrag(urls: siblings, at: point(onLine: 0))
        #expect(table.tableView(table.table, validateDrop: siblingsOverFolder, proposedRow: 0, proposedDropOperation: .on) == .move)
        #expect(table.dropLine == 0)
        let siblingsOverFile = FakeDrag(urls: siblings, at: point(onLine: 2))
        #expect(table.tableView(table.table, validateDrop: siblingsOverFile, proposedRow: 2, proposedDropOperation: .on) == [])
        #expect(table.dropLine == nil && !table.dropOnBackground)
        table.draggingEnded()
        #expect(!table.dropOnBackground)

        // The end of a drag reaches the list as AppKit sends it. Passing it on to NSTableView,
        // which has no such method, threw and left every later drag unable to start.
        (table.table as! FileTableView).draggingEnded(overFolder)
    }

    @Test func columnsNeverOverlap() {
        for width in [200, 300, 450, 600, 900, 1400] as [CGFloat] {
            for showLocation in [false, true] {
                for depth in [0, 3] {
                    let layout = FileTableLayout(width: width, showLocation: showLocation, depth: depth)
                    let columns = [layout.name, layout.location, layout.type, layout.size, layout.date].compactMap { $0 }
                    for (left, right) in zip(columns, columns.dropFirst()) {
                        #expect(left.upperBound <= right.lowerBound, "width \(width)")
                    }
                    #expect(columns.last!.upperBound <= width - FileTableLayout.gutter)
                }
            }
        }
    }

    /// A narrow pane (a split) leaves columns out rather than squeezing the name to nothing.
    @Test func narrowListsLeaveColumnsOut() {
        let wide = FileTableLayout(width: 900, showLocation: false, depth: 0)
        #expect(wide.type != nil && wide.size != nil && wide.date != nil)
        let split = FileTableLayout(width: 300, showLocation: false, depth: 0)
        #expect(split.type == nil && split.size == nil && split.date != nil)
        #expect(split.name.upperBound - split.name.lowerBound >= FileTableLayout.minNameWithDate)
        let tiny = FileTableLayout(width: 200, showLocation: false, depth: 0)
        #expect(tiny.date == nil)
        let narrowRecents = FileTableLayout(width: 600, showLocation: true, depth: 0)
        #expect(narrowRecents.location == nil && narrowRecents.type != nil)
    }
}

