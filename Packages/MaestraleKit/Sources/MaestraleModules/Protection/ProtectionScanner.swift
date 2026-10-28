import Foundation
import MaestraleCore

/// Runs every `ProtectionCheck` and merges the results.
public struct ProtectionScanner: Sendable {
    public let checks: [any ProtectionCheck]
    public let context: CheckContext

    public static func defaultChecks() -> [any ProtectionCheck] {
        [LaunchItemsCheck(), LoginItemsCheck(), AppsSignatureCheck(), RecentInstallsCheck(), BrowserExtensionsCheck(),
         BrowserHijackCheck(), CronAndShellCheck(), ProfilesCheck(), TrustedRootsCheck(), SystemExtensionsCheck(),
         NetworkConfigCheck(), TCCCheck(), PostureCheck(), XProtectCheck(), ProcessesCheck(), SignatureScanCheck()]
    }

    public init(context: CheckContext = CheckContext(), checks: [any ProtectionCheck]? = nil) {
        self.context = context
        self.checks = checks ?? Self.defaultChecks()
    }

    /// Runs the checks whose requirements are met, in parallel, and returns the
    /// findings sorted by severity. Signature findings about trusted teams are dropped.
    public func scan() -> [Finding] {
        let runnable = checks.filter { check in
            switch check.requirement {
            case .none, .fullDiskAccess: true
            case .admin: context.systemEvidence != nil
            }
        }
        let results = Results()
        DispatchQueue.concurrentPerform(iterations: runnable.count) { index in
            let check = runnable[index]
            let found = check.run(context)
            results.add(found)
        }
        var seen: Set<String> = []
        return results.all
            .filter { finding in
                guard let team = finding.team, context.trustedTeams.contains(team) else { return true }
                return finding.severity == .danger
            }
            .filter { seen.insert($0.id).inserted }
            .sorted { ($0.severity, $0.category.rawValue, $0.title) > ($1.severity, $1.category.rawValue, $1.title) }
    }

    private final class Results: @unchecked Sendable {
        private var findings: [Finding] = []
        private let lock = NSLock()
        func add(_ new: [Finding]) { lock.lock(); findings += new; lock.unlock() }
        var all: [Finding] { lock.lock(); defer { lock.unlock() }; return findings }
    }
}

private func > (a: (Finding.Severity, String, String), b: (Finding.Severity, String, String)) -> Bool {
    if a.0 != b.0 { return a.0 > b.0 }
    if a.1 != b.1 { return a.1 < b.1 }
    return a.2.localizedCaseInsensitiveCompare(b.2) == .orderedAscending
}
