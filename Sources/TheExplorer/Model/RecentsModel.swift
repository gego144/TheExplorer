import Foundation
import Observation

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

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .day: "24 Hours"
        case .week: "7 Days"
        case .month: "30 Days"
        case .quarter: "90 Days"
        }
    }
}

struct RecentItem: Identifiable {
    let item: FileItem
    let date: Date
    var id: URL { item.url }
}

struct RecentSection: Identifiable {
    let title: String
    let items: [RecentItem]
    var id: String { title }
}

/// Live Spotlight query over your home folder for the newest files and folders.
@MainActor
@Observable
final class RecentsModel {
    static let limit = 1500

    var dateKind: RecentsDateKind = .created { didSet { restart() } }
    var range: RecentsRange = .week { didSet { restart() } }
    var kindFilter: KindFilter = .all { didSet { rebuild() } }
    var hideNoise = true { didSet { rebuild() } }
    var selection: Set<URL> = []

    private(set) var sections: [RecentSection] = []
    private(set) var totalCount = 0
    private(set) var isGathering = false

    @ObservationIgnored private var query: SpotlightQuery?
    @ObservationIgnored private var latest: [NSMetadataItem] = []

    var isActive: Bool { query != nil }

    func start() {
        guard query == nil else { return }
        restart()
    }

    func stop() {
        query?.stop()
        query = nil
    }

    private func restart() {
        query?.stop()
        let cutoff = Calendar.current.date(byAdding: .day, value: -range.rawValue, to: Date()) ?? Date()
        let attribute = dateKind.attribute
        let query = SpotlightQuery()
        query.onUpdate = { [weak self] items, gathering in
            self?.latest = items
            self?.isGathering = gathering
            self?.rebuild()
        }
        isGathering = true
        query.start(
            predicate: NSPredicate(format: "%K >= %@", attribute, cutoff as NSDate),
            scopes: [NSMetadataQueryUserHomeScope],
            sortedBy: attribute
        )
        self.query = query
    }

    private func rebuild() {
        let attribute = dateKind.attribute
        var kept: [RecentItem] = []
        var total = 0
        for metadata in latest {
            guard let date = metadata.value(forAttribute: attribute) as? Date,
                  let path = metadata.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
            if hideNoise && PathNoise.isNoisy(path) { continue }
            guard let item = FileItem(metadata: metadata), kindFilter.matches(isFolder: item.isFolder) else { continue }
            total += 1
            if kept.count < Self.limit {
                kept.append(RecentItem(item: item, date: date))
            }
        }
        // Spotlight already sorts, but live updates can append out of order.
        kept.sort { $0.date > $1.date }
        totalCount = total
        sections = Self.group(kept)
        selection.formIntersection(kept.map(\.id))
    }

    private static func group(_ items: [RecentItem]) -> [RecentSection] {
        let calendar = Calendar.current
        let now = Date()
        func bucket(_ date: Date) -> String {
            if calendar.isDateInToday(date) { return "Today" }
            if calendar.isDateInYesterday(date) { return "Yesterday" }
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
            if days < 7 { return date.formatted(.dateTime.weekday(.wide)) }
            if days < 14 { return "Last Week" }
            if days < 31 { return "Earlier This Month" }
            return date.formatted(.dateTime.month(.wide).year())
        }
        var sections: [RecentSection] = []
        var currentTitle: String?
        var bucketItems: [RecentItem] = []
        for item in items {
            let title = bucket(item.date)
            if title != currentTitle, let currentTitle {
                sections.append(RecentSection(title: currentTitle, items: bucketItems))
                bucketItems = []
            }
            currentTitle = title
            bucketItems.append(item)
        }
        if let currentTitle {
            sections.append(RecentSection(title: currentTitle, items: bucketItems))
        }
        return sections
    }
}
