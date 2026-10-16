import AppKit

/// Moves or copies dropped items into a folder with Finder's rules: move within a volume,
/// copy across volumes, ⌥ forces a copy, and name clashes keep both instead of overwriting.
enum FileTransfer {
    enum Mode {
        case move
        case copy
    }

    struct Outcome: Sendable {
        var placed: [URL] = []
        var failures: [String] = []
        /// What it would take to undo the transfer: move moved items back, trash the copies.
        var undo: [FileHistory.Step] = []
    }

    /// Transfers that make sense: not onto itself, not into its own subfolder, and not into
    /// the folder it's already in (unless `duplicating`, where that makes a copy beside it).
    static func validSources(_ urls: [URL], into folder: URL, duplicating: Bool = false) -> [URL] {
        let destination = folder.standardizedFileURL.path
        return urls.map(\.standardizedFileURL).filter { source in
            let path = source.path
            return path != destination
                && !destination.hasPrefix(path + "/")
                && (duplicating || source.deletingLastPathComponent().path != destination)
        }
    }

    static func mode(for source: URL, into folder: URL, optionHeld: Bool) -> Mode {
        if optionHeld { return .copy }
        return volumeID(source) == volumeID(folder) ? .move : .copy
    }

    /// `forced` overrides the drop rules (paste decides copy or move itself).
    static func perform(_ sources: [URL], into folder: URL, optionHeld: Bool, forced: Mode? = nil) -> Outcome {
        var outcome = Outcome()
        let fm = FileManager.default
        for source in sources {
            let destination = uniqueDestination(for: source.lastPathComponent, in: folder)
            do {
                switch forced ?? mode(for: source, into: folder, optionHeld: optionHeld) {
                case .move:
                    try fm.moveItem(at: source, to: destination)
                    outcome.undo.append(.move(destination, to: source))
                case .copy:
                    try fm.copyItem(at: source, to: destination)
                    outcome.undo.append(.trash(destination))
                }
                outcome.placed.append(destination)
            } catch {
                outcome.failures.append("\(source.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return outcome
    }

    /// "Report.pdf" → "Report 2.pdf", "Report 3.pdf", … until the name is free.
    static func uniqueDestination(for name: String, in folder: URL) -> URL {
        let fm = FileManager.default
        var candidate = folder.appendingPathComponent(name)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var counter = 2
        repeat {
            let numbered = "\(stem) \(counter)" + (ext.isEmpty ? "" : ".\(ext)")
            candidate = folder.appendingPathComponent(numbered)
            counter += 1
        } while fm.fileExists(atPath: candidate.path)
        return candidate
    }

    private static func volumeID(_ url: URL) -> NSObject? {
        (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
    }
}
