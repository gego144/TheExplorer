import Foundation
import Testing
@testable import TheExplorer

struct FolderHandlerTests {
    private let others: [[String: Any]] = [
        ["LSHandlerContentType": "public.html", "LSHandlerRoleViewer": "com.google.chrome"],
        ["LSHandlerURLScheme": "mailto", "LSHandlerRoleAll": "com.apple.mail"],
    ]

    @Test func removesOnlyOurFolderEntry() {
        let existing = others + [["LSHandlerContentType": "Public.Folder", "LSHandlerRoleAll": "com.gego.TheExplorer"]]
        let cleaned = FolderHandler.withoutFolderEntry(for: "com.gego.theexplorer", in: existing)
        #expect(cleaned.count == 2)
        #expect(cleaned.contains { $0["LSHandlerURLScheme"] as? String == "mailto" })
    }

    @Test func keepsAnotherAppsFolderEntry() {
        let existing = others + [["LSHandlerContentType": "public.folder", "LSHandlerRoleAll": "com.binarynights.forklift"]]
        #expect(FolderHandler.withoutFolderEntry(for: "com.gego.TheExplorer", in: existing).count == 3)
    }
}
