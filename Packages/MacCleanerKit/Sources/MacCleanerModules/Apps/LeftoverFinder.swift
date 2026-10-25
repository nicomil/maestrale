import Foundation
import MacCleanerCore

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

    public func leftovers(for identity: Identity) -> [ScanItem] {
        var items: [ScanItem] = []
        for (relative, match, systemToo) in places {
            var roots = [home.appendingPathComponent("Library").appendingPathComponent(relative)]
            if systemToo { roots.append(systemLibrary.appendingPathComponent(relative)) }
            for root in roots {
                let isSystem = !root.path.hasPrefix(home.path + "/")
                for name in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
                where Self.matches(name, match: match, identity: identity) {
                    let url = root.appendingPathComponent(name)
                    let exact = identity.bundleIDs.contains { name == $0 || name.hasPrefix($0 + ".") }
                    items.append(ScanItem(
                        url: url, size: FileSizer.allocatedSize(of: url),
                        risk: exact ? .low : .medium, autoSelect: exact,
                        needsHelper: isSystem && !FileManager.default.isDeletableFile(atPath: url.path),
                        detail: url.deletingLastPathComponent().path.replacingOccurrences(of: home.path, with: "~")))
                }
            }
        }
        return items
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
