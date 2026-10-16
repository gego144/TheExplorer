import Foundation
import Testing
@testable import TheExplorer

struct ActionTests {
    private func item(_ name: String, folder: Bool = false) -> FileItem {
        FileItem(url: URL(fileURLWithPath: "/x/\(name)"), name: name, isDirectory: folder, fileSize: folder ? nil : 1)
    }

    @Test func appliesByTypeAndTarget() {
        let video = FileAction(name: "HLS", command: "", extensions: ["mp4", "mov"])
        #expect(video.applies(to: item("clip.MP4")))
        #expect(!video.applies(to: item("notes.txt")))
        #expect(!video.applies(to: item("Footage", folder: true)))

        let anyFile = FileAction(name: "Zip", command: "", target: .filesAndFolders)
        #expect(anyFile.applies(to: item("notes.txt")))
        #expect(anyFile.applies(to: item("Footage", folder: true)))

        let folders = FileAction(name: "Count", command: "", extensions: ["txt"], target: .folders)
        #expect(!folders.applies(to: item("notes.txt")))
        #expect(folders.applies(to: item("Footage", folder: true)))
    }

    @Test func parsesExtensionLists() {
        #expect(FileAction.parseExtensions("mp4, .MOV  m4v,,") == ["mp4", "mov", "m4v"])
        #expect(FileAction.parseExtensions("  ") == [])
    }

    @Test func carriageReturnsRewriteTheLastLine() {
        var output = ""
        output = ActionRunner.appending("start\nframe=1", to: output)
        output = ActionRunner.appending("\rframe=2", to: output)
        output = ActionRunner.appending("\rframe=3\ndone\r\n", to: output)
        #expect(output == "start\nframe=3\ndone\n")
    }

    @Test func environmentDescribesTheFirstItem() {
        let env = ActionRunner.environment(for: [URL(fileURLWithPath: "/Videos/my clip.mp4"), URL(fileURLWithPath: "/Videos/b.mov")])
        #expect(env["FILE"] == "/Videos/my clip.mp4")
        #expect(env["FILENAME"] == "my clip.mp4")
        #expect(env["NAME"] == "my clip")
        #expect(env["EXT"] == "mp4")
        #expect(env["DIR"] == "/Videos")
        #expect(env["COUNT"] == "2")
        #expect(env["PATH"]?.contains("/opt/homebrew/bin") == true)
    }
}
