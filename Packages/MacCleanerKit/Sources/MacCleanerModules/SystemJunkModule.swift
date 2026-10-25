import AppKit
import Foundation
import MacCleanerCore

/// Caches, logs, developer junk and other files that can be regenerated.
/// The rules live in `Resources/system-junk.json` (see docs/spec/system-junk.md).
public struct SystemJunkModule: CleanerModule {
    public let id = "system-junk"
    public let title = "Pulizia sistema"
    private let rules: RuleSet
    private let home: URL

    public init(rules: RuleSet? = nil, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        self.rules = try rules ?? Self.bundledRules()
        self.home = home
    }

    public var allowedRoots: [URL] { AllowedRoots.user(home: home) }

    public static func bundledRules() throws -> RuleSet {
        guard let url = Bundle.module.url(forResource: "system-junk", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try RuleSet.load(from: url)
    }

    public func scan() async throws -> ScanReport {
        let running = await Self.runningBundleIdentifiers()
        let engine = RuleEngine(home: home, protectedNames: running)
        let output = engine.evaluate(rules)
        return ScanReport(moduleID: id, categories: output.categories, unreadablePaths: output.unreadable)
    }

    /// Caches of running apps are skipped: deleting them under an open app can
    /// make it misbehave until it is restarted.
    @MainActor
    static func runningBundleIdentifiers() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }
}
