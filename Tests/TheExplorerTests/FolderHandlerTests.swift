import Foundation
import Testing
@testable import TheExplorer

struct FolderHandlerTests {
    private let others: [[String: Any]] = [
        ["LSHandlerContentType": "public.html", "LSHandlerRoleViewer": "com.google.chrome"],
        ["LSHandlerURLScheme": "mailto", "LSHandlerRoleAll": "com.apple.mail"],
    ]

    @Test func choosingAnAppReplacesOnlyTheFolderEntry() {
        let existing = others + [["LSHandlerContentType": "Public.Folder", "LSHandlerRoleAll": "com.other.browser"]]
        let handlers = FolderHandler.handlers(choosing: "com.gego.TheExplorer", in: existing)
        #expect(handlers.count == 3)
        #expect(FolderHandler.folderEntry(in: handlers) == "com.gego.TheExplorer")
        #expect(handlers.filter { ($0["LSHandlerContentType"] as? String)?.lowercased() == "public.folder" }.count == 1)
        #expect(handlers.contains { $0["LSHandlerURLScheme"] as? String == "mailto" })
    }

    @Test func choosingFinderRemovesTheFolderEntry() {
        let existing = others + [["LSHandlerContentType": "public.folder", "LSHandlerRoleAll": "com.gego.TheExplorer"]]
        let handlers = FolderHandler.handlers(choosing: nil, in: existing)
        #expect(handlers.count == 2)
        #expect(FolderHandler.folderEntry(in: handlers) == nil)
    }
}
