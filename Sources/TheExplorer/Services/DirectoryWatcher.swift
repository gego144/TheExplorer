import Foundation

/// Fires `onChange` (on the main queue) when a directory's entries change: a quarter second
/// after things go quiet, and at least once a second while they don't (an unzip or a download
/// writing for a while), so the list keeps up as it happens.
final class DirectoryWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var watched: String?
    private var pending: DispatchWorkItem?
    /// When the first change still waiting to be reported came in.
    private var waitingSince: DispatchTime?
    private let onChange: () -> Void

    private static let quiet = 0.25
    private static let longestWait = 1.0

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    deinit { stop() }

    /// Watches `url`. Watching the folder already watched changes nothing, so a change that
    /// arrives while its list reloads is still reported once the reload is done.
    func watch(_ url: URL) {
        let path = url.standardizedFileURL.path
        if path == watched, source != nil { return }
        stop()
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .link], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let self else { return }
            // The folder itself was moved or deleted: this watch is on what's gone, so the
            // next watch() opens whatever is at the path now.
            if let flags = source?.data, !flags.isDisjoint(with: [.delete, .rename]) {
                self.source?.cancel()
                self.source = nil
                self.watched = nil
            }
            self.scheduleChange()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
        watched = path
    }

    func stop() {
        pending?.cancel()
        pending = nil
        waitingSince = nil
        source?.cancel()
        source = nil
        watched = nil
    }

    private func scheduleChange() {
        pending?.cancel()
        let now = DispatchTime.now()
        let first = waitingSince ?? now
        waitingSince = first
        let work = DispatchWorkItem { [weak self] in
            self?.waitingSince = nil
            self?.pending = nil
            self?.onChange()
        }
        pending = work
        let due = min(now + Self.quiet, first + Self.longestWait)
        DispatchQueue.main.asyncAfter(deadline: due, execute: work)
    }
}
