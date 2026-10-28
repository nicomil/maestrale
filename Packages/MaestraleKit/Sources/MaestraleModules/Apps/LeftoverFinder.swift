import Foundation
import MaestraleCore

/// Finds the files an application leaves around the system
/// (see docs/spec/uninstaller.md for the list of places).
public struct LeftoverFinder: Sendable {
    public let home: URL
    public let systemLibrary: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                systemLibrary: URL = URL(fileURLWithPath: "/Library")) {
        self.home = home
        self.systemLibrary = systemLibrary
    }

    /// What identifies an app's files.
    public struct Identity: Sendable {
        public let bundleIDs: [String]
        public let name: String
        public let teamID: String?

        public init(bundleIDs: [String], name: String, teamID: String?) {
            self.bundleIDs = bundleIDs.filter { !$0.isEmpty }
            self.name = name
            self.teamID = teamID
        }

        public init(app: InstalledApp) {
            self.init(bundleIDs: [app.bundleID] + app.embeddedBundleIDs, name: app.name, teamID: app.teamID)
        }
    }

    /// Folders searched in both ~/Library and /Library, with how entries match.
    enum Match { case bundleID, bundleIDOrName, preferences, savedState, cookies, groupContainer, launchd }

    var places: [(String, Match, systemToo: Bool)] {
        [
            ("Application Support", .bundleIDOrName, true),
            ("Caches", .bundleID, true),
            ("HTTPStorages", .bundleID, false),
            ("WebKit", .bundleID, false),
            ("Logs", .bundleIDOrName, true),
            ("Preferences", .preferences, true),
            ("Preferences/ByHost", .preferences, false),
            ("Containers", .bundleID, false),
            ("Group Containers", .groupContainer, false),
            ("Saved Application State", .savedState, false),
            ("Cookies", .cookies, false),
            ("Application Scripts", .bundleID, false),
            ("LaunchAgents", .launchd, true),
            ("LaunchDaemons", .launchd, true),
            ("PrivilegedHelperTools", .launchd, true),
        ]
    }

    /// Places where apps keep the user's own data (documents, databases, notes):
    /// never preselected, even when the name matches exactly.
    static let dataPlaces: Set<String> = ["Application Support", "Containers", "Group Containers"]

    /// `otherAppIDs` are the bundle identifiers of the other installed apps:
    /// an entry that belongs to one of them more precisely (com.google.Chrome.canary
    /// when uninstalling com.google.Chrome) is left alone.
    public func leftovers(for identity: Identity, otherAppIDs: Set<String> = []) -> [ScanItem] {
        let others = otherAppIDs.subtracting(identity.bundleIDs)
        var items: [ScanItem] = []
        for (relative, match, systemToo) in places {
            var roots = [home.appendingPathComponent("Library").appendingPathComponent(relative)]
            if systemToo { roots.append(systemLibrary.appendingPathComponent(relative)) }
            for root in roots {
                let isSystem = !root.path.hasPrefix(home.path + "/")
                for name in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
                where Self.matches(name, match: match, identity: identity)
                    && !Self.belongsToAnotherApp(name, identity: identity, others: others) {
                    let url = root.appendingPathComponent(name)
                    let exact = identity.bundleIDs.contains { name == $0 || name.hasPrefix($0 + ".") }
                    let holdsData = Self.dataPlaces.contains(relative)
                    items.append(ScanItem(
                        url: url, size: FileSizer.allocatedSize(of: url),
                        risk: holdsData ? .high : exact ? .low : .medium, autoSelect: exact && !holdsData,
                        needsHelper: isSystem && !FileManager.default.isDeletableFile(atPath: url.path),
                        detail: url.deletingLastPathComponent().path.replacingOccurrences(of: home.path, with: "~")))
                }
            }
        }
        return items
    }

    /// True when another installed app's identifier matches the name more
    /// precisely than any identifier of the app being removed.
    static func belongsToAnotherApp(_ name: String, identity: Identity, others: Set<String>) -> Bool {
        guard !others.isEmpty else { return false }
        var base = name.lowercased()
        for suffix in [".plist", ".savedstate", ".binarycookies"] where base.hasSuffix(suffix) {
            base.removeLast(suffix.count)
        }
        if let team = identity.teamID?.lowercased(), base.hasPrefix(team + ".") { base.removeFirst(team.count + 1) }
        func longestMatch(_ ids: [String]) -> Int {
            ids.map { $0.lowercased() }.filter { base == $0 || base.hasPrefix($0 + ".") }.map(\.count).max() ?? 0
        }
        return longestMatch(Array(others)) > longestMatch(identity.bundleIDs)
    }

    static func matches(_ name: String, match: Match, identity: Identity) -> Bool {
        let lower = name.lowercased()
        let ids = identity.bundleIDs.map { $0.lowercased() }
        func idMatch(_ candidate: String) -> Bool {
            ids.contains { candidate == $0 || candidate.hasPrefix($0 + ".") }
        }
        switch match {
        case .bundleID:
            return idMatch(lower)
        case .bundleIDOrName:
            // The bare app name only when it is distinctive enough (not "Helper", "Data"...).
            let appName = identity.name.lowercased()
            return idMatch(lower) || (appName.count >= 4 && lower == appName)
        case .preferences:
            return idMatch(lower.replacingOccurrences(of: ".plist", with: ""))
        case .savedState:
            return idMatch(lower.replacingOccurrences(of: ".savedstate", with: ""))
        case .cookies:
            return idMatch(lower.replacingOccurrences(of: ".binarycookies", with: ""))
        case .groupContainer:
            // "<TEAMID>.<bundle id or group>" — require the team and a bundle id inside.
            guard let team = identity.teamID?.lowercased(), lower.hasPrefix(team + ".") else { return false }
            let rest = String(lower.dropFirst(team.count + 1))
            let specific = rest.split(separator: ".").count >= 3
            return ids.contains { rest == $0 || rest.hasPrefix($0 + ".") || (specific && $0.hasPrefix(rest)) }
        case .launchd:
            return idMatch(lower.replacingOccurrences(of: ".plist", with: ""))
        }
    }
}
