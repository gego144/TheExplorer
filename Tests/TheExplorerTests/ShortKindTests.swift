import Foundation
import Testing
import UniformTypeIdentifiers
@testable import TheExplorer

/// The list's Kind column: a word or two, not macOS's full type names.
struct ShortKindTests {
    private func kind(_ name: String, folder: Bool = false) -> String {
        let url = URL(fileURLWithPath: "/tmp/\(name)")
        return FileItem(url: url, name: name, isDirectory: folder,
                        contentType: folder ? .folder : UTType(filenameExtension: url.pathExtension)).shortKind
    }

    @Test func commonKindsAreShort() {
        #expect(kind("App.swift") == "Swift")
        #expect(kind("index.ts") == "TypeScript")   // not "MPEG-2 Transport Stream"
        #expect(kind("main.py") == "Python")
        #expect(kind("photo.jpg") == "JPEG image")
        #expect(kind("icon.png") == "PNG image")
        #expect(kind("clip.mp4") == "MP4 video")
        #expect(kind("song.mp3") == "MP3 audio")
        #expect(kind("report.docx") == "Word")
        #expect(kind("notes.md") == "Markdown")
        #expect(kind("Sources", folder: true) == "Folder")
    }

    @Test func unknownKindsStayShort() {
        #expect(kind("thing.qzx") == "QZX")
        #expect(kind("thing.averyverylongextension") == "Document")
        #expect(["App.swift", "x.pdf", "a.zip", "b.csv", "c.yaml", "d.dmg"].allSatisfy { kind($0).count <= 14 })
    }
}
