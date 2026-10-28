import AppKit
import Foundation
import MaestraleCore

/// Files left behind by applications that are no longer installed.
///
/// An entry is a candidate when its name looks like a bundle identifier
/// (`com.vendor.app`), is not Apple's, and nothing still claims it: no
/// installed app or helper inside an app, no running process, no app known
/// to Launch Services, and no launchd service (a plist in the LaunchAgents
/// and LaunchDaemons folders, or a label loaded in the user's session, which
/// also covers tools without an app such as `com.google.Keystone`).
/// Nothing is preselected: command line tools also write such folders, so
/// each item says how long ago it was last modified and a recent one is
/// marked high risk.
public struct OrphanLeftoversModule: CleanerModule {
    public let id = "orphan-leftovers"
    public let title = "Avanzi di app rimosse"
    private let home: URL
    private let inventory: AppInventory
    private let commands: any CommandRunner
    private let launchItems: @Sendable () -> [LaunchItem]
    private let now: Date

    /// An item modified within this many days may still be in use.
    public static let recentDays = 30

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                commands: any CommandRunner = SystemCommands(),
                launchItems: (@Sendable () -> [LaunchItem])? = nil,
                now: Date = Date()) {
        self.home = home
        self.inventory = AppInventory(home: home)
        self.commands = commands
        self.launchItems = launchItems ?? { LaunchItemsScanner(home: home).scan() }
        self.now = now
    }

    public var allowedRoots: [URL] { AllowedRoots.appSupport(home: home) }

    static let places = ["Application Support", "Caches", "Preferences", "Containers", "Saved Application State",
                         "HTTPStorages", "WebKit", "Logs", "Application Scripts", "Cookies"]

    public func scan() async throws -> ScanReport {
        let apps = await inventory.load(computeSizes: false)
        var known = Set(apps.flatMap { [$0.bundleID] + $0.embeddedBundleIDs }.map { $0.lowercased() })
        known.formUnion(await Self.runningBundleIDs())
        known.formUnion(launchItems().map { $0.label.lowercased() })
        known.formUnion(Self.parseLaunchctlLabels(commands.run("/bin/launchctl", ["list"])))
        let resolver = BundleIDResolver()

        var byOwner: [String: [ScanItem]] = [:]
        for place in Self.places {
            let folder = home.appendingPathComponent("Library").appendingPathComponent(place)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] {
                try Task.checkCancellation()
                guard let owner = Self.bundleIDLike(name), !Self.isOwned(owner, known: known),
                      !resolver.isInstalledSomewhere(owner) else { continue }
                let url = folder.appendingPathComponent(name)
                let size = FileSizer.allocatedSize(of: url)
                guard size > 0 else { continue }
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                let age = Self.classify(modified: modified, now: now)
                byOwner[owner, default: []].append(ScanItem(url: url, size: size, risk: age.risk, autoSelect: false,
                                                            needsHelper: false, detail: "~/Library/\(place) · \(age.note)"))
            }
        }
        let categories = byOwner.map { owner, items in
            ScanCategory(id: "orphan-\(owner)", title: owner, items: items.sorted { $0.size > $1.size })
        }
        .sorted { $0.totalSize > $1.totalSize }
        return ScanReport(moduleID: id, categories: categories)
    }

    /// "com.vendor.app.plist" → "com.vendor.app"; nil for names that are not bundle-id shaped.
    static func bundleIDLike(_ name: String) -> String? {
        var base = name.lowercased()
        for suffix in [".plist", ".savedstate", ".binarycookies"] where base.hasSuffix(suffix) {
            base.removeLast(suffix.count)
        }
        let parts = base.split(separator: ".")
        guard parts.count >= 3, let first = parts.first,
              ["com", "org", "net", "io", "de", "it", "co", "app", "dev", "me", "info", "fr", "uk", "jp", "ru"]
                .contains(String(first)),
              !base.hasPrefix("com.apple."),
              base.allSatisfy({ $0.isLetter || $0.isNumber || "-_.".contains($0) }) else { return nil }
        return base
    }

    /// Owned when it equals a known id, is inside one (com.app.helper), or is
    /// the vendor part of one (com.vendor.shared used by com.vendor.app).
    static func isOwned(_ id: String, known: Set<String>) -> Bool {
        if known.contains(id) { return true }
        return known.contains { id.hasPrefix($0 + ".") || $0.hasPrefix(id + ".") }
    }

    /// The labels in the output of `launchctl list` (PID, status, label per
    /// line, header first). Lines that do not look like that are skipped.
    static func parseLaunchctlLabels(_ output: String) -> Set<String> {
        var labels: Set<String> = []
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(maxSplits: 2, omittingEmptySubsequences: true, whereSeparator: { $0 == "\t" || $0 == " " })
            guard fields.count == 3, fields[0] == "-" || Int(fields[0]) != nil, Int(fields[1]) != nil else { continue }
            labels.insert(fields[2].trimmingCharacters(in: .whitespaces).lowercased())
        }
        return labels
    }

    /// How risky an item is from its age: something written in the last
    /// `recentDays` days is probably still used by a tool without an app.
    static func classify(modified: Date?, now: Date) -> (risk: RiskLevel, note: String) {
        guard let modified else { return (.high, "data di modifica sconosciuta") }
        let days = max(0, Int(now.timeIntervalSince(modified) / 86_400))
        if days < recentDays {
            let when = days == 0 ? "oggi" : days == 1 ? "ieri" : "\(days) giorni fa"
            return (.high, "modificato \(when), forse ancora in uso")
        }
        if days < 365 { return (.medium, "ultima modifica \(days / 30) mesi fa") }
        return (.medium, "ultima modifica \(days / 365) anni fa")
    }

    @MainActor
    static func runningBundleIDs() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier?.lowercased() })
    }
}

/// Asks Launch Services whether an app with a bundle id exists anywhere
/// (other folders, other volumes, system locations).
struct BundleIDResolver: Sendable {
    func isInstalledSomewhere(_ bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }
}
