import Foundation
import Testing
@testable import TheExplorer

@MainActor
struct DirectoryWatcherTests {
    private final class Counter { var fired = 0 }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DirectoryWatcherTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func touch(_ folder: URL, _ name: String) throws {
        try Data("x".utf8).write(to: folder.appendingPathComponent(name))
    }

    @Test func aChangeDuringAReloadStillComesThrough() async throws {
        let url = try folder()
        defer { try? FileManager.default.removeItem(at: url) }
        let counter = Counter()
        let watcher = DirectoryWatcher { counter.fired += 1 }
        watcher.watch(url)
        try touch(url, "a")
        try await Task.sleep(for: .milliseconds(50))
        // A reload finishing watches the same folder again; the change waiting must survive.
        watcher.watch(url)
        try await Task.sleep(for: .milliseconds(500))
        #expect(counter.fired == 1)
    }

    @Test func busyFoldersReportAtLeastOnceASecond() async throws {
        let url = try folder()
        defer { try? FileManager.default.removeItem(at: url) }
        let counter = Counter()
        let watcher = DirectoryWatcher { counter.fired += 1 }
        watcher.watch(url)
        // Like an unzip: a file every 50 ms for two seconds, never a quiet quarter second.
        for i in 0..<40 {
            try touch(url, "f\(i)")
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(counter.fired >= 1)
        try await Task.sleep(for: .milliseconds(400))
        #expect(counter.fired >= 2)
        watcher.stop()
    }

    @Test func aReplacedFolderIsWatchedAgain() async throws {
        let url = try folder()
        let moved = url.appendingPathExtension("old")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: moved)
        }
        let counter = Counter()
        let watcher = DirectoryWatcher { counter.fired += 1 }
        watcher.watch(url)
        try FileManager.default.moveItem(at: url, to: moved)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try await Task.sleep(for: .milliseconds(400))
        let before = counter.fired
        #expect(before >= 1)
        watcher.watch(url)
        try touch(url, "new")
        try await Task.sleep(for: .milliseconds(400))
        #expect(counter.fired == before + 1)
    }
}
