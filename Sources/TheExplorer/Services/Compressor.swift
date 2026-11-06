import Foundation

/// Zips files and folders the way Finder's Compress does, with the same `ditto` it uses: one
/// item becomes "Name.zip" beside it, several become "Archive.zip" holding them side by side.
/// Extended attributes and resource forks go in the archive's __MACOSX folder, so unzipping on
/// a Mac gives back exactly what went in.
///
/// The archive is written in a temporary folder on the same volume and moved into place once
/// it's complete, so a half-written zip never shows up in the folder.
enum Compressor {
    enum Failure: LocalizedError {
        case mixedFolders
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .mixedFolders: "Only items in the same folder can be compressed together."
            case .failed(let message): message.isEmpty ? "The archive couldn't be made." : message
            }
        }
    }

    /// Where the archive goes: "Name.zip", or "Name 2.zip" and so on if that's taken.
    static func destination(for items: [URL]) -> URL {
        let folder = items[0].deletingLastPathComponent()
        let base = items.count == 1 ? items[0].lastPathComponent : "Archive"
        var candidate = folder.appendingPathComponent(base + ".zip")
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(number).zip")
            number += 1
        }
        return candidate
    }

    /// Writes the archive, returning where it landed. Blocks while `ditto` runs, so call it off
    /// the main thread.
    static func zip(_ items: [URL]) throws -> URL {
        let items = items.map(\.standardizedFileURL)
        let folder = items[0].deletingLastPathComponent()
        guard items.allSatisfy({ $0.deletingLastPathComponent() == folder }) else { throw Failure.mixedFolders }
        let fm = FileManager.default
        let scratch = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: folder, create: true)
        defer { try? fm.removeItem(at: scratch) }
        let archive = scratch.appendingPathComponent("archive.zip")

        if items.count == 1 {
            try ditto(["-c", "-k", "--sequesterRsrc", "--keepParent", items[0].path, archive.path])
        } else {
            // ditto takes one source, so the items are gathered in a folder first. On APFS the
            // copies are clones: instant, and they take no space.
            let gathered = scratch.appendingPathComponent("Archive")
            try fm.createDirectory(at: gathered, withIntermediateDirectories: false)
            for item in items {
                try fm.copyItem(at: item, to: gathered.appendingPathComponent(item.lastPathComponent))
            }
            try ditto(["-c", "-k", "--sequesterRsrc", gathered.path, archive.path])
        }

        // Picked last, so an archive another app made meanwhile isn't overwritten.
        let destination = destination(for: items)
        try fm.moveItem(at: archive, to: destination)
        return destination
    }

    private static func ditto(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let message = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure.failed(String(decoding: message, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
