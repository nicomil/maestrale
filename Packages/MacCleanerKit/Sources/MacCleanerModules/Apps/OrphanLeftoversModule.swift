import AppKit
import Foundation
import MacCleanerCore

/// Files left behind by applications that are no longer installed.
///
/// An entry is a candidate when its name looks like a bundle identifier
/// (`com.vendor.app`), is not Apple's, and no installed app, helper inside an
/// app, running process or app known to Launch Services owns it.
/// Nothing is preselected: command line tools also write such folders.
public struct OrphanLeftoversModule: CleanerModule {
    public let id = "orphan-leftovers"
    public let title = "Avanzi di app rimosse"
    private let home: URL
    private let inventory: AppInventory

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
        self.inventory = AppInventory(home: home)
    }

    public var allowedRoots: [URL] { AllowedRoots.appSupport(home: home) }

    static let places = ["Application Support", "Caches", "Preferences", "Containers", "Saved Application State",
                         "HTTPStorages", "WebKit", "Logs", "Application Scripts", "Cookies"]

    public func scan() async throws -> ScanReport {
        let apps = await inventory.load(computeSizes: false)
        var known = Set(apps.flatMap { [$0.bundleID] + $0.embeddedBundleIDs }.map { $0.lowercased() })
        known.formUnion(await Self.runningBundleIDs())
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
                byOwner[owner, default: []].append(ScanItem(url: url, size: size, risk: .medium, autoSelect: false,
                                                            needsHelper: false, detail: "~/Library/\(place)"))
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
