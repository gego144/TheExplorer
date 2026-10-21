import Foundation
import Observation
import UniformTypeIdentifiers

/// The two time-based views. Both are the same live Spotlight query with different settings.
enum RecentsMode {
    /// Like Finder's Recents: documents you've opened, newest first, all time.
    case opened
    /// Files and folders that appeared recently (created, modified or added).
    case new
}

enum RecentsDateKind: String, CaseIterable, Identifiable {
    case created = "Created"
    case modified = "Modified"
    case added = "Added"

    var id: String { rawValue }

    var attribute: String {
        switch self {
        case .created: NSMetadataItemFSCreationDateKey
        case .modified: NSMetadataItemFSContentChangeDateKey
        case .added: FileItem.addedDateAttribute
        }
    }
}

enum RecentsRange: Int, CaseIterable, Identifiable {
    case day = 1
    case week = 7
    case month = 30
    case quarter = 90
    case year = 365
    /// No cutoff. Only offered where the result set stays small (opened documents).
    case all = 0

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .day: "Last 24 Hours"
        case .week: "Last 7 Days"
        case .month: "Last 30 Days"
        case .quarter: "Last 90 Days"
        case .year: "Last Year"
        case .all: "All Time"
        }
    }

    /// The ranges each mode offers. A year of everything created in a home folder can be
    /// millions of items, so New stops at 90 days.
    static func options(for mode: RecentsMode) -> [RecentsRange] {
        switch mode {
        case .opened: [.week, .month, .quarter, .year, .all]
        case .new: [.day, .week, .month, .quarter]
        }
    }

    /// The next wider range, offered when you scroll past the end of this one.
    func wider(for mode: RecentsMode) -> RecentsRange? {
        let options = Self.options(for: mode)
        guard let index = options.firstIndex(of: self), index + 1 < options.count else { return nil }
        return options[index + 1]
    }
}

/// Recents and New, newest first, loaded a page at a time.
///
/// New with clutter hidden reads TheExplorer's own file index, which already leaves clutter
/// out: a pass over its arrays takes milliseconds and keeps nothing alive, and it follows changes
/// through the index. Everything else is a live Spotlight query over your home folder.
///
/// A week of a developer's home folder is easily half a million items (mostly dependency folders),
/// so the query runs off the main thread, sorted newest first, and only the items up to the
/// current page are ever resolved. Scrolling to the end loads the next page; paths already
/// resolved are cached, so each page only costs its own items. The main thread only receives
/// the finished rows. Every match is held in memory, though (over a gigabyte for 90 days of
/// everything), which is why New avoids it when it can.
@MainActor
@Observable
final class RecentsModel {
    nonisolated static let pageSize = 1500
    static let lastUsedDateAttribute = "kMDItemLastUsedDate"

    let mode: RecentsMode
    var dateKind: RecentsDateKind = .created { didSet { restart() } }
    var range: RecentsRange { didSet { restart() } }
    var kindFilter: KindFilter = .all { didSet { refilter() } }
    var hideNoise: Bool { didSet { refilter() } }
    var selection: Set<URL> = []

    /// Newest first, with a day-group header on the first row of each group.
    private(set) var rows: [ListRow] = []
    /// Matching items in range; nil when only the loaded pages were counted.
    private(set) var totalCount: Int?
    /// More items in range than are loaded; scrolling to the end loads them.
    private(set) var hasMore = false
    private(set) var isGathering = false

    @ObservationIgnored private var query: SpotlightQuery?
    @ObservationIgnored private var indexed: IndexedRecents?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var limit = RecentsModel.pageSize
    @ObservationIgnored private var loadingMore = false

    init(mode: RecentsMode) {
        self.mode = mode
        range = mode == .opened ? .all : Prefs.shared.newRange
        hideNoise = Prefs.shared.newHidesClutter
    }

    var isActive: Bool { query != nil || indexed != nil }

    /// The date the list is about, as a column title.
    var dateTitle: String { mode == .opened ? "Opened" : dateKind.rawValue }

    func start() {
        guard !isActive else { return }
        restart()
    }

    /// Shows a renamed item under its new name (and keeps it selected) until the next update
    /// lists it anyway.
    func renamed(_ old: URL, to new: URL) {
        guard let index = rows.firstIndex(where: { $0.id == old }), let item = FileItem(url: new) else { return }
        var row = rows[index]
        row = ListRow(item: item, size: row.size, liveFolderSize: row.liveFolderSize, date: row.date,
                      location: row.location, group: row.group)
        rows[index] = row
        if selection.remove(old) != nil { selection.insert(new) }
    }

    /// Whether the list is off screen, where live updates wait.
    @ObservationIgnored var isPaused = false {
        didSet {
            guard isPaused != oldValue else { return }
            query?.setPaused(isPaused)
            indexed?.setPaused(isPaused)
        }
    }

    func stop() {
        query?.stop()
        query = nil
        indexed = nil
        generation += 1
        isGathering = false
        loadingMore = false
    }

    /// Loads the next page; called when the list scrolls to its end.
    func loadMore() {
        guard hasMore, !loadingMore else { return }
        if let indexed {
            loadingMore = true
            limit += Self.pageSize
            indexed.load(limit: limit)
            return
        }
        guard let query else { return }
        loadingMore = true
        limit += Self.pageSize
        query.setHandler(makeHandler())
    }

    /// New with clutter hidden is exactly what the file index holds.
    private var usesIndex: Bool { mode == .new && hideNoise }

    private var cutoff: Date {
        range == .all
            ? Date(timeIntervalSince1970: 0)
            : Calendar.current.date(byAdding: .day, value: -range.rawValue, to: Date()) ?? Date()
    }

    private var attribute: String {
        mode == .opened ? Self.lastUsedDateAttribute : dateKind.attribute
    }

    private func restart() {
        query?.stop()
        query = nil
        indexed = nil
        limit = Self.pageSize
        generation += 1
        isGathering = true
        if usesIndex {
            startIndexed()
            return
        }
        let attribute = attribute
        let cutoff = cutoff
        let query = SpotlightQuery(
            predicate: NSPredicate(format: "%K >= %@", attribute, cutoff as NSDate),
            scopes: [NSMetadataQueryUserHomeScope],
            sortedBy: attribute
        )
        self.query = query
        if isPaused { query.setPaused(true) }
        isGathering = true
        query.start(makeHandler())
    }

    private func refilter() {
        guard isActive else { return }
        // Hiding clutter switches between the index and Spotlight.
        if usesIndex != (indexed != nil) {
            restart()
            return
        }
        limit = Self.pageSize
        if let indexed {
            indexed.reset(kind: kindFilter)
            indexed.load(limit: limit)
        } else {
            query?.setHandler(makeHandler())
        }
    }

    private func startIndexed() {
        let generation = generation
        let date: FileIndex.RecentDate = switch dateKind {
        case .created: .created
        case .modified: .modified
        case .added: .added
        }
        let indexed = IndexedRecents(date: date, cutoff: cutoff, kind: kindFilter, groups: .days) { [weak self] snapshot in
            guard let self, self.generation == generation else { return }
            self.isGathering = false
            self.loadingMore = false
            self.rows = snapshot.rows
            self.totalCount = snapshot.total
            self.hasMore = snapshot.hasMore
            if !self.selection.isEmpty {
                self.selection.formIntersection(snapshot.rows.map(\.id))
            }
        }
        self.indexed = indexed
        indexed.setPaused(isPaused)
        indexed.load(limit: limit)
    }

    /// Builds the background handler for the current filters; results from older handlers are dropped.
    private func makeHandler() -> SpotlightQuery.Handler {
        generation += 1
        let generation = generation
        let filter = RecentsFilter(
            attribute: attribute,
            kind: mode == .opened ? .files : kindFilter,
            documentsOnly: mode == .opened,
            hideNoise: mode == .opened || hideNoise,
            limit: limit,
            groups: mode == .opened ? .finder : .days
        )
        let last = LastSnapshot()
        return { [weak self] results, gathering in
            let snapshot = filter.collect(results)
            // Live updates often change nothing visible (e.g. churn in hidden folders).
            let unchanged = last.matches(snapshot)
            DispatchQueue.main.async {
                guard let self, self.generation == generation else { return }
                if self.isGathering != gathering { self.isGathering = gathering }
                self.loadingMore = false
                guard !unchanged else { return }
                self.rows = snapshot.rows
                self.totalCount = snapshot.total
                self.hasMore = snapshot.hasMore
                if !self.selection.isEmpty {
                    self.selection.formIntersection(snapshot.rows.map(\.id))
                }
            }
            // While you scroll through this page, get the next one ready: crossing a block of
            // dependency-folder files means resolving tens of thousands of paths the first time.
            if snapshot.hasMore && !last.warmed {
                last.warmed = true
                filter.warm(results, from: snapshot.walked, wanted: filter.pageSize)
            }
        }
    }
}

/// The previous snapshot a handler published. Only touched on the query's queue.
private final class LastSnapshot: @unchecked Sendable {
    private var ids: [URL] = []
    private var dates: [Date?] = []
    private var total: Int?
    private var hasMore = false
    private var published = false
    /// Whether this handler already prepared the page after its own.
    var warmed = false

    func matches(_ snapshot: RecentsFilter.Snapshot) -> Bool {
        let ids = snapshot.rows.map(\.id)
        let dates = snapshot.rows.map(\.date)
        defer {
            self.ids = ids
            self.dates = dates
            total = snapshot.total
            hasMore = snapshot.hasMore
            published = true
        }
        return published && ids == self.ids && dates == self.dates && snapshot.total == total && snapshot.hasMore == hasMore
    }
}

/// The filters Recents applies, evaluated on the query's background queue.
private struct RecentsFilter: Sendable {
    enum Groups: Sendable {
        /// Today, Yesterday, weekdays, Last Week, Earlier This Month, then months.
        case days
        /// Finder's Recents: Today, Yesterday, Previous 7 Days, Previous 30 Days, then months.
        case finder
    }

    let attribute: String
    let kind: KindFilter
    /// Finder's Recents shows documents only: no folders or apps.
    let documentsOnly: Bool
    let hideNoise: Bool
    let limit: Int
    let pageSize = RecentsModel.pageSize
    let groups: Groups

    struct Snapshot: Sendable {
        let rows: [ListRow]
        let total: Int?
        let hasMore: Bool
        /// Where the walk stopped: the next page starts after this index.
        var walked = 0
    }

    /// Walks results newest first. Dates and types are free to read, so filtering on them costs
    /// nothing; paths are only resolved until `limit` items are kept.
    func collect(_ results: SpotlightQuery.Results) -> Snapshot {
        var kept: [ListRow] = []
        kept.reserveCapacity(limit)
        var matching = 0
        for index in 0..<results.count {
            guard kind.matches(isFolder: results.isFolder(at: index)) else { continue }
            if documentsOnly && !Self.isDocument(results.contentType(at: index)) { continue }
            if kept.count >= limit {
                // Counting the rest would mean walking every result on every live update, and
                // with clutter shown that can be millions.
                return Snapshot(rows: grouped(kept), total: nil, hasMore: true, walked: index)
            }
            if hideNoise && results.isNoisy(at: index) { continue }
            guard let date: Date = results.value(attribute, at: index),
                  let path = results.path(at: index) else { continue }
            guard let item = results.item(at: index) else { continue }
            matching += 1
            kept.append(ListRow(
                item: item,
                size: item.isFolder ? nil : item.fileSize,
                date: date,
                location: (path as NSString).deletingLastPathComponent
            ))
        }
        return Snapshot(rows: grouped(kept), total: matching, hasMore: matching > kept.count)
    }

    /// Resolves the clutter check for results past the loaded pages until `wanted` more items
    /// pass the filters, so loading the next page only reads memoized answers.
    func warm(_ results: SpotlightQuery.Results, from start: Int, wanted: Int) {
        guard hideNoise else { return }
        var found = 0
        var index = start
        while index < results.count && found < wanted {
            if kind.matches(isFolder: results.isFolder(at: index)),
               !documentsOnly || Self.isDocument(results.contentType(at: index)),
               !results.isNoisy(at: index) {
                found += 1
            }
            index += 1
        }
    }

    /// Documents, images, media, archives: what Finder's Recents lists.
    private static func isDocument(_ type: UTType?) -> Bool {
        guard let type else { return false }
        if type.conforms(to: .folder) || type.conforms(to: .application) || type.conforms(to: .applicationBundle) {
            return false
        }
        return type.conforms(to: .content) || type.conforms(to: .archive)
    }

    /// Puts a group header on the first row of each group. Rows arrive newest first, so the
    /// title is only recomputed when the day changes.
    func grouped(_ rows: [ListRow]) -> [ListRow] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var currentDay: Date?
        var title: String?
        return rows.map { row in
            var row = row
            let day = calendar.startOfDay(for: row.date ?? .distantPast)
            if day != currentDay {
                currentDay = day
                let next = bucket(day, today: today, calendar: calendar)
                if next != title {
                    title = next
                    row.group = next
                }
            }
            return row
        }
    }

    fileprivate func bucket(_ day: Date, today: Date, calendar: Calendar) -> String {
        let days = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        if days <= 0 { return "Today" }
        if days == 1 { return "Yesterday" }
        switch groups {
        case .days:
            if days < 7 { return day.formatted(.dateTime.weekday(.wide)) }
            if days < 14 { return "Last Week" }
            if days < 31 { return "Earlier This Month" }
        case .finder:
            if days < 7 { return "Previous 7 Days" }
            if days < 30 { return "Previous 30 Days" }
        }
        return day.formatted(.dateTime.month(.wide).year())
    }
}

/// New's rows from the file index. Each load is one pass over a snapshot of the index off the
/// main thread; the index's changes reload it, at most every two seconds.
@MainActor
private final class IndexedRecents {
    typealias Snapshot = RecentsFilter.Snapshot

    private let date: FileIndex.RecentDate
    private let cutoff: Date
    private var kind: KindFilter
    private let groups: RecentsFilter.Groups
    private let deliver: (Snapshot) -> Void
    private var limit = RecentsModel.pageSize
    private var loading: Task<Void, Never>?
    private var pending: Task<Void, Never>?
    private var observer: NSObjectProtocol?
    private var paused = false
    private var missedChange = false
    /// Items already read from disk, by path, with the change time they were read at.
    private var items = ItemCache()
    private let addedTimes = FileIndex.AddedTimes()

    init(date: FileIndex.RecentDate, cutoff: Date, kind: KindFilter, groups: RecentsFilter.Groups,
         deliver: @escaping (Snapshot) -> Void) {
        self.date = date
        self.cutoff = cutoff
        self.kind = kind
        self.groups = groups
        self.deliver = deliver
        observer = NotificationCenter.default.addObserver(forName: FileIndex.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.indexChanged() }
        }
    }

    deinit {
        loading?.cancel()
        pending?.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func reset(kind: KindFilter) {
        self.kind = kind
    }

    func setPaused(_ paused: Bool) {
        self.paused = paused
        if !paused && missedChange {
            missedChange = false
            load(limit: limit)
        }
    }

    func load(limit: Int) {
        self.limit = limit
        loading?.cancel()
        let (date, cutoff, kind, groups, items, addedTimes) = (date, cutoff, kind, groups, items, addedTimes)
        loading = Task { [weak self] in
            let snapshot = await Task.detached(priority: .userInitiated) {
                await FileIndex.shared.waitUntilReady()
                return Self.collect(date: date, cutoff: cutoff, kind: kind, groups: groups, limit: limit, items: items, addedTimes: addedTimes)
            }.value
            guard !Task.isCancelled else { return }
            self?.deliver(snapshot)
        }
    }

    private func indexChanged() {
        guard !paused else {
            missedChange = true
            return
        }
        guard pending == nil else { return }
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            self.pending = nil
            self.load(limit: self.limit)
        }
    }

    nonisolated private static func collect(date: FileIndex.RecentDate, cutoff: Date, kind: KindFilter,
                                            groups: RecentsFilter.Groups, limit: Int, items: ItemCache,
                                            addedTimes: FileIndex.AddedTimes) -> Snapshot {
        let storage = FileIndex.shared.snapshot()
        let home = URL.home.path
        let found = FileIndex.recent(in: storage, scopes: [home], since: cutoff, by: date, kind: kind, addedTimes: addedTimes)
        var rows: [ListRow] = []
        rows.reserveCapacity(min(limit, found.count))
        var walked = 0
        for entry in found {
            guard rows.count < limit else { break }
            walked += 1
            let path = storage.path(entry.index)
            guard let item = items.item(path, changed: storage.changed[Int(entry.index)]) else { continue }
            rows.append(ListRow(
                item: item,
                size: item.isFolder ? nil : item.fileSize,
                date: Date(timeIntervalSinceReferenceDate: TimeInterval(entry.date)),
                location: (path as NSString).deletingLastPathComponent
            ))
        }
        let filter = RecentsFilter(attribute: "", kind: kind, documentsOnly: false, hideNoise: true, limit: limit, groups: groups)
        // Items that vanished since the index saw them are skipped, so the count is approximate
        // by those few.
        let total = found.count - (walked - rows.count)
        return Snapshot(rows: filter.grouped(rows), total: total, hasMore: walked < found.count)
    }
}

/// Items read from disk for New, reused while their change time stays the same.
private final class ItemCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: (changed: Int32, item: FileItem)] = [:]

    func item(_ path: String, changed: Int32) -> FileItem? {
        if let hit = lock.withLock({ entries[path] }), hit.changed == changed { return hit.item }
        guard let item = FileItem(url: URL(fileURLWithPath: path)) else { return nil }
        lock.withLock {
            // Bounded: a few pages' worth is all that's ever shown.
            if entries.count > 20_000 { entries.removeAll(keepingCapacity: true) }
            entries[path] = (changed, item)
        }
        return item
    }
}
