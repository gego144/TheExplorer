import Darwin
import Foundation

/// Folders projects tell git to ignore, like build output and caches (`/build`, `/[Ll]ibrary/`,
/// `.next/`). Their contents are regenerated, named by hash, and never what you're looking for,
/// so the search index skips them, as tools like ripgrep and fd do.
///
/// Only folder rules matter here, and only the common forms: names and globs (`dist`,
/// `*.egg-info/`), paths anchored to the .gitignore's folder (`/build`, `docs/_site/`), and a
/// leading `**/`. Negations (`!keep/`) are ignored, and so are rules that would ignore everything.
final class IgnoreRules: @unchecked Sendable {
    static let shared = IgnoreRules()

    struct Rule: Equatable {
        let glob: String
        /// Matched against the path below the .gitignore's folder rather than just the name.
        let anchored: Bool
    }

    private struct Folder {
        let rules: [Rule]
        /// A repository's top folder (has .git); rules above it don't apply.
        let isRepository: Bool
    }

    private let lock = NSLock()
    private var folders: [String: Folder] = [:]

    /// Forgets what's been read, so edited .gitignore files are read again.
    func reset() {
        lock.withLock { folders = [:] }
    }

    /// Whether a .gitignore in a folder above `path` ignores it.
    func ignores(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        var folder = (path as NSString).deletingLastPathComponent
        while folder.count > 1 {
            let info = self.folder(folder)
            if !info.rules.isEmpty {
                let relative = String(path.dropFirst(folder.count + 1))
                for rule in info.rules where Self.matches(rule, name: name, relative: relative) {
                    return true
                }
            }
            if info.isRepository { break }
            folder = (folder as NSString).deletingLastPathComponent
        }
        return false
    }

    static func matches(_ rule: Rule, name: String, relative: String) -> Bool {
        rule.anchored ? fnmatch(rule.glob, relative, FNM_PATHNAME) == 0 : fnmatch(rule.glob, name, 0) == 0
    }

    private func folder(_ path: String) -> Folder {
        if let known = lock.withLock({ folders[path] }) { return known }
        let text = try? String(contentsOfFile: path + "/.gitignore", encoding: .utf8)
        let info = Folder(rules: text.map(Self.parse) ?? [], isRepository: access(path + "/.git", F_OK) == 0)
        lock.withLock { folders[path] = info }
        return info
    }

    /// The folder rules in a .gitignore.
    static func parse(_ text: String) -> [Rule] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("!") else { return nil }
            if line.hasSuffix("/**") { line.removeLast(3) }
            while line.hasSuffix("/") { line.removeLast() }
            var anchored = false
            if line.hasPrefix("**/") {
                line.removeFirst(3)
            } else if line.hasPrefix("/") {
                line.removeFirst()
                anchored = true
            }
            if line.contains("/") { anchored = true }
            line = line.replacingOccurrences(of: "**", with: "*")
            // "*" alone would hide the whole project (it's usually followed by "!" exceptions).
            guard !line.isEmpty, line.contains(where: { $0 != "*" && $0 != "/" }) else { return nil }
            return Rule(glob: line, anchored: anchored)
        }
    }
}
