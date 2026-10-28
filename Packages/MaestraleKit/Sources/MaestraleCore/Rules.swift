import Foundation

/// One cleaning rule, loaded from a JSON file in the Rules folder.
///
/// `paths` may start with `~` and may contain wildcards (`*`, `?`, `[…]`) in
/// any component, e.g. `~/Library/Containers/*/Data/Library/Caches`.
public struct CleaningRule: Codable, Sendable, Identifiable {
    public enum Target: String, Codable, Sendable {
        /// Each item inside the matched folders becomes a result.
        case children
        /// The matched path itself becomes a result.
        case itself
    }

    public let id: String
    public let category: String
    public let title: String
    public let paths: [String]
    public var target: Target = .children
    /// Names (wildcards allowed) that are never returned.
    public var excludes: [String] = []
    /// Only items not modified for at least this many days.
    public var minAgeDays: Int?
    public var risk: RiskLevel = .low
    public var autoSelect: Bool = true
    public var needsHelper: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, category, title, paths, target, excludes, minAgeDays, risk, autoSelect, needsHelper
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        category = try c.decode(String.self, forKey: .category)
        title = try c.decode(String.self, forKey: .title)
        paths = try c.decode([String].self, forKey: .paths)
        target = try c.decodeIfPresent(Target.self, forKey: .target) ?? .children
        excludes = try c.decodeIfPresent([String].self, forKey: .excludes) ?? []
        minAgeDays = try c.decodeIfPresent(Int.self, forKey: .minAgeDays)
        risk = try c.decodeIfPresent(RiskLevel.self, forKey: .risk) ?? .low
        autoSelect = try c.decodeIfPresent(Bool.self, forKey: .autoSelect) ?? true
        needsHelper = try c.decodeIfPresent(Bool.self, forKey: .needsHelper) ?? false
    }
}

public struct RuleSet: Codable, Sendable {
    public let version: Int
    /// Names excluded by every rule of the set.
    public let globalExcludes: [String]?
    public let rules: [CleaningRule]
}

/// Turns rules into scan results.
public struct RuleEngine: Sendable {
    public let home: URL
    /// Extra names to skip, e.g. bundle identifiers of running apps.
    public let protectedNames: Set<String>
    public let now: Date
    /// Keep items of size zero (empty files and folders). Off by default:
    /// they are noise in a cleaning list, but the Trash must empty them too.
    public let includeEmptyItems: Bool

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                protectedNames: Set<String> = [], now: Date = Date(), includeEmptyItems: Bool = false) {
        self.home = home
        self.protectedNames = protectedNames
        self.now = now
        self.includeEmptyItems = includeEmptyItems
    }

    public struct Output: Sendable {
        public var categories: [ScanCategory]
        public var unreadable: [URL]
    }

    public func evaluate(_ set: RuleSet) -> Output {
        var byCategory: [String: (title: String, items: [ScanItem])] = [:]
        var order: [String] = []
        var unreadable: [URL] = []

        for rule in set.rules {
            let excludes = (set.globalExcludes ?? []) + rule.excludes
            var items: [ScanItem] = []
            for pattern in rule.paths {
                for match in expand(pattern) {
                    switch rule.target {
                    case .itself:
                        if let item = makeItem(match, rule: rule, excludes: excludes) { items.append(item) }
                    case .children:
                        guard let children = try? FileManager.default.contentsOfDirectory(
                            at: match, includingPropertiesForKeys: [.contentModificationDateKey], options: []
                        ) else {
                            if FileManager.default.fileExists(atPath: match.path) { unreadable.append(match) }
                            continue
                        }
                        for child in children {
                            if let item = makeItem(child, rule: rule, excludes: excludes) { items.append(item) }
                        }
                    }
                }
            }
            if !includeEmptyItems { items = items.filter { $0.size > 0 } }
            guard !items.isEmpty else { continue }
            if byCategory[rule.category] == nil {
                order.append(rule.category)
                byCategory[rule.category] = (rule.title, [])
            }
            byCategory[rule.category]?.items.append(contentsOf: items)
        }

        // Rules can overlap (a folder and something inside it). Keep only the
        // outermost item, and only its first occurrence, so sizes are not
        // counted twice and nothing is removed twice.
        let allPaths = Set(byCategory.values.flatMap { $0.items.map { Self.canonicalPath($0.url) } })
        var seen: Set<String> = []
        let categories = order.compactMap { key -> ScanCategory? in
            guard let entry = byCategory[key] else { return nil }
            let kept = entry.items.filter { item in
                let path = Self.canonicalPath(item.url)
                return !Self.hasAncestor(path, in: allPaths) && seen.insert(path).inserted
            }
            guard !kept.isEmpty else { return nil }
            return ScanCategory(id: key, title: entry.title, items: kept.sorted { $0.size > $1.size })
        }
        return Output(categories: categories, unreadable: unreadable)
    }

    /// Path with symlinks resolved in the parent folders (e.g. /var → /private/var),
    /// but not in the last component, so a symlink item stays itself.
    static func canonicalPath(_ url: URL) -> String {
        url.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(url.lastPathComponent).path
    }

    /// True when any folder on the path, or the item itself, is named after
    /// one of `names` (bundle identifiers of running apps): "com.foo" protects
    /// ~/Library/Caches/com.foo, ~/Library/Containers/com.foo/… and its
    /// subfolders, "group.com.foo", "TEAMID.com.foo" and "com.foo.ShipIt".
    public static func isProtected(_ url: URL, by names: Set<String>) -> Bool {
        guard !names.isEmpty else { return false }
        return url.pathComponents.contains { component in
            if names.contains(component) { return true }
            // Only components that look like identifiers need the slower checks.
            guard component.contains(".") else { return false }
            return names.contains { name in
                component.hasSuffix("." + name) || component.hasPrefix(name + ".")
            }
        }
    }

    static func hasAncestor(_ path: String, in paths: Set<String>) -> Bool {
        var current = (path as NSString).deletingLastPathComponent
        while current.count > 1 {
            if paths.contains(current) { return true }
            current = (current as NSString).deletingLastPathComponent
        }
        return false
    }

    private func makeItem(_ url: URL, rule: CleaningRule, excludes: [String]) -> ScanItem? {
        let name = url.lastPathComponent
        if name == ".DS_Store" || Self.isProtected(url, by: protectedNames) { return nil }
        if excludes.contains(where: { Self.matches(name, pattern: $0) }) { return nil }
        if let days = rule.minAgeDays {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard let modified, now.timeIntervalSince(modified) >= Double(days) * 86_400 else { return nil }
        }
        return ScanItem(url: url, size: FileSizer.allocatedSize(of: url), risk: rule.risk,
                        autoSelect: rule.autoSelect, needsHelper: rule.needsHelper)
    }

    /// Expands `~` and wildcards into the existing paths that match.
    public func expand(_ pattern: String) -> [URL] {
        var path = pattern.replacingOccurrences(of: "$UID", with: String(getuid()))
        if path == "~" || path.hasPrefix("~/") { path = home.path + path.dropFirst() }
        guard path.hasPrefix("/") else { return [] }

        var current: [URL] = [URL(fileURLWithPath: "/")]
        for component in path.split(separator: "/").map(String.init) {
            var next: [URL] = []
            for base in current {
                if Self.hasWildcard(component) {
                    let names = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
                    for name in names where Self.matches(name, pattern: component) {
                        next.append(base.appendingPathComponent(name))
                    }
                } else {
                    let candidate = base.appendingPathComponent(component)
                    if FileManager.default.fileExists(atPath: candidate.path) { next.append(candidate) }
                }
            }
            current = next
            if current.isEmpty { break }
        }
        return current
    }

    static func hasWildcard(_ s: String) -> Bool { s.contains { "*?[".contains($0) } }

    static func matches(_ name: String, pattern: String) -> Bool {
        fnmatch(pattern, name, 0) == 0
    }
}

extension RuleSet {
    public static func load(from url: URL) throws -> RuleSet {
        try JSONDecoder().decode(RuleSet.self, from: Data(contentsOf: url))
    }
}
