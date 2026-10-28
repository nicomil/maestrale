import Foundation

/// How dangerous it is to remove an item.
public enum RiskLevel: String, Codable, Sendable, Comparable, CaseIterable {
    /// Regenerated automatically by the system or the app.
    case low
    /// Some state is lost (sessions, logins, window positions).
    case medium
    /// Possible data loss or a broken app.
    case high

    private var rank: Int {
        switch self {
        case .low: 0
        case .medium: 1
        case .high: 2
        }
    }

    public static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool { lhs.rank < rhs.rank }
}

/// A single file or folder found by a scan.
public struct ScanItem: Identifiable, Hashable, Sendable {
    public var id: URL { url }
    public let url: URL
    public let size: Int64
    public let risk: RiskLevel
    /// Whether the item is selected by default in the review screen.
    public let autoSelect: Bool
    /// Whether removing the item needs the privileged helper.
    public let needsHelper: Bool
    /// Short extra information shown under the name (e.g. "last used 2 years ago").
    public let detail: String?

    public init(url: URL, size: Int64, risk: RiskLevel, autoSelect: Bool, needsHelper: Bool,
                detail: String? = nil) {
        self.url = url
        self.size = size
        self.risk = risk
        self.autoSelect = autoSelect
        self.needsHelper = needsHelper
        self.detail = detail
    }

    public var displayName: String { url.lastPathComponent }
}

/// A group of items that belong to the same category (e.g. "User caches").
public struct ScanCategory: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let items: [ScanItem]
    /// For groups of copies (duplicates, similar photos): the item that must
    /// stay. Selecting the whole group never selects it, and a clean that
    /// would remove every item of the group is refused.
    public let keep: URL?

    public init(id: String, title: String, items: [ScanItem], keep: URL? = nil) {
        self.id = id
        self.title = title
        self.items = items
        self.keep = keep
    }

    public var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
}

/// The result of scanning one module.
public struct ScanReport: Sendable {
    public let moduleID: String
    public let categories: [ScanCategory]
    /// Paths that could not be read, usually because Full Disk Access is missing.
    public let unreadablePaths: [URL]

    public init(moduleID: String, categories: [ScanCategory], unreadablePaths: [URL] = []) {
        self.moduleID = moduleID
        self.categories = categories
        self.unreadablePaths = unreadablePaths
    }

    public var totalSize: Int64 { categories.reduce(0) { $0 + $1.totalSize } }
    public var allItems: [ScanItem] { categories.flatMap(\.items) }
}

/// A feature that can scan the Mac and return items to clean.
public protocol CleanerModule: Sendable {
    var id: String { get }
    var title: String { get }
    /// Folders this module may remove items from (see `SafeRemover`).
    var allowedRoots: [URL] { get }
    func scan() async throws -> ScanReport
}
