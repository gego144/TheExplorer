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

/// Live Spotlight query over your home folder, newest first, loaded a page at a time.
///
/// A week of a developer's home folder is easily half a million items (mostly dependency folders),
/// so the query runs off the main thread, sorted newest first, and only the items up to the
/// current page are ever resolved. Scrolling to the end loads the next page; paths already
/// resolved are cached, so each page only costs its own items. The main thread only receives
/// the finished rows.
@MainActor
@Observable
final class RecentsModel {
    static let pageSize = 1500
    static let lastUsedDateAttribute = "kMDItemLastUsedDate"

    let mode: RecentsMode
    var dateKind: RecentsDateKind = .created { didSet { restart() } }
    var range: RecentsRange { didSet { restart() } }
    var kindFilter: KindFilter = .all { didSet { refilter() } }
    var hideNoise = true { didSet { refilter() } }
    var selection: Set<URL> = []

    /// Newest first, with a day-group header on the first row of each group.
    private(set) var rows: [ListRow] = []
    /// Matching items in range; nil when only the loaded pages were counted.
    private(set) var totalCount: Int?
    /// More items in range than are loaded; scrolling to the end loads them.
    private(set) var hasMore = false
    private(set) var isGathering = false

    @ObservationIgnored private var query: SpotlightQuery?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var limit = RecentsModel.pageSize
    @ObservationIgnored private var loadingMore = false

    init(mode: RecentsMode) {
        self.mode = mode
        range = mode == .opened ? .all : .week
    }

    var isActive: Bool { query != nil }

    /// The date the list is about, as a column title.
    var dateTitle: String { mode == .opened ? "Opened" : dateKind.rawValue }

    func start() {
        guard query == nil else { return }
        restart()
    }

    func stop() {
        query?.stop()
        query = nil
        generation += 1
        isGathering = false
        loadingMore = false
    }

    /// Loads the next page; called when the list scrolls to its end.
    func loadMore() {
        guard hasMore, !loadingMore, let query else { return }
        loadingMore = true
        limit += Self.pageSize
        query.setHandler(makeHandler())
    }

    private var attribute: String {
        mode == .opened ? Self.lastUsedDateAttribute : dateKind.attribute
    }

    private func restart() {
        query?.stop()
        limit = Self.pageSize
        let attribute = attribute
        let cutoff = range == .all
            ? Date(timeIntervalSince1970: 0)
            : Calendar.current.date(byAdding: .day, value: -range.rawValue, to: Date()) ?? Date()
        let query = SpotlightQuery(
            predicate: NSPredicate(format: "%K >= %@", attribute, cutoff as NSDate),
            scopes: [NSMetadataQueryUserHomeScope],
            sortedBy: attribute
        )
        self.query = query
        isGathering = true
        query.start(makeHandler())
    }

    private func refilter() {
        limit = Self.pageSize
        query?.setHandler(makeHandler())
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
                self.isGathering = gathering
                self.loadingMore = false
                guard !unchanged else { return }
                self.rows = snapshot.rows
                self.totalCount = snapshot.total
                self.hasMore = snapshot.hasMore
                if !self.selection.isEmpty {
                    self.selection.formIntersection(snapshot.rows.map(\.id))
                }
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
    let groups: Groups

    struct Snapshot: Sendable {
        let rows: [ListRow]
        let total: Int?
        let hasMore: Bool
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
                // With the noise filter, counting the rest would mean resolving every path.
                if hideNoise { return Snapshot(rows: grouped(kept), total: nil, hasMore: true) }
                matching += 1
                continue
            }
            guard let date: Date = results.value(attribute, at: index),
                  let path = results.path(at: index) else { continue }
            if hideNoise && PathNoise.isNoisy(path) { continue }
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
    private func grouped(_ rows: [ListRow]) -> [ListRow] {
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

    private func bucket(_ day: Date, today: Date, calendar: Calendar) -> String {
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
