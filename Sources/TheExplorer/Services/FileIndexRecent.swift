import Darwin
import Foundation

extension FileIndex {
    /// Which date "recent" is about.
    enum RecentDate: Sendable {
        case created, modified, added
    }

    /// Added dates already read, so reloading New doesn't read them all again. An item's added
    /// date can't change without its change time changing too, so that's checked.
    final class AddedTimes: @unchecked Sendable {
        private let lock = NSLock()
        private var times: [Int32: (changed: Int32, nameStart: UInt32, added: Int32?)] = [:]

        func added(_ index: Int32, in storage: Storage) -> Int32? {
            let i = Int(index)
            if let hit = lock.withLock({ times[index] }), hit.changed == storage.changed[i], hit.nameStart == storage.nameStart[i] {
                return hit.added
            }
            let added = FileIndex.addedTime(storage.path(index))
            lock.withLock {
                if times.count > 400_000 { times.removeAll(keepingCapacity: true) }
                times[index] = (storage.changed[i], storage.nameStart[i], added)
            }
            return added
        }
    }

    /// An indexed item dated at or after a cutoff.
    struct RecentEntry: Sendable {
        let index: Int32
        /// Seconds since 2001.
        let date: Int32
    }

    /// Everything indexed inside `scopes` dated at or after `cutoff`, newest first: what New
    /// lists with clutter hidden, since the index already leaves clutter out (Library, hidden
    /// and dependency folders, the insides of packages). One pass over the arrays, so it takes
    /// milliseconds and holds nothing beyond its answer, where the same Spotlight query keeps
    /// every match in memory, often hundreds of thousands.
    ///
    /// Created and modified dates are in the index. The date something was added to its folder
    /// isn't, so it's read from disk, but only for entries changed since the cutoff: moving or
    /// copying something into a folder changes it, so nothing added later is missed.
    static func recent(in storage: Storage, scopes: [String], since cutoff: Date, by date: RecentDate,
                       kind: KindFilter, addedTimes: AddedTimes = AddedTimes()) -> [RecentEntry] {
        let count = storage.count
        guard count > 0 else { return [] }
        let since = Int32(clamping: Int(cutoff.timeIntervalSinceReferenceDate))
        var inScope = [Bool](repeating: false, count: count)
        for root in storage.roots {
            let path = storage.name(root)
            inScope[Int(root)] = scopes.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
        var found: [RecentEntry] = []
        for i in 0..<count {
            let parent = storage.parent[i]
            if parent >= 0 { inScope[i] = inScope[Int(parent)] }
            guard inScope[i] else { continue }
            let flags = storage.flags[i]
            if flags.contains(.removed) || flags.contains(.root) || flags.contains(.hidden) { continue }
            guard kind.matches(isFolder: flags.contains(.folder) && !flags.contains(.package)) else { continue }
            switch date {
            case .created:
                if storage.created[i] >= since { found.append(RecentEntry(index: Int32(i), date: storage.created[i])) }
            case .modified:
                if storage.modified[i] >= since { found.append(RecentEntry(index: Int32(i), date: storage.modified[i])) }
            case .added:
                guard storage.changed[i] >= since, let added = addedTimes.added(Int32(i), in: storage), added >= since else { continue }
                found.append(RecentEntry(index: Int32(i), date: added))
            }
        }
        found.sort { $0.date != $1.date ? $0.date > $1.date : $0.index > $1.index }
        return found
    }

    /// When the item arrived in its folder (downloaded, copied, moved), in seconds since 2001.
    static func addedTime(_ path: String) -> Int32? {
        var request = attrlist(bitmapcount: u_short(ATTR_BIT_MAP_COUNT), reserved: 0,
                               commonattr: attrgroup_t(ATTR_CMN_ADDEDTIME), volattr: 0, dirattr: 0, fileattr: 0, forkattr: 0)
        // A 4-byte length, then the timespec.
        var buffer = (UInt64(0), UInt64(0), UInt64(0), UInt64(0))
        return withUnsafeMutableBytes(of: &buffer) { raw -> Int32? in
            guard getattrlist(path, &request, raw.baseAddress, raw.count, UInt32(FSOPT_NOFOLLOW)) == 0,
                  raw.load(as: UInt32.self) >= 4 + UInt32(MemoryLayout<timespec>.size) else { return nil }
            let seconds = raw.loadUnaligned(fromByteOffset: 4, as: Int.self)
            return Int32(clamping: seconds - 978_307_200)
        }
    }
}
