import Foundation

/// The ids seen by the previous scan, with the date each one first appeared.
/// Lets the screen say "new since last time", which on a Mac that keeps
/// misbehaving is the most useful signal of all.
public struct ProtectionBaseline: Sendable {
    public let fileURL: URL

    public static let standardURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/MacCleaner/protection/last-scan.json")

    public init(fileURL: URL = ProtectionBaseline.standardURL) {
        self.fileURL = fileURL
    }

    struct Entry: Codable {
        var firstSeen: Date
        var lastSeen: Date
    }

    func load() -> [String: Entry] {
        guard let data = try? Data(contentsOf: fileURL),
              let entries = try? JSONDecoder().decode([String: Entry].self, from: data) else { return [:] }
        return entries
    }

    /// Marks the findings that were not in the previous scan and records the
    /// current ones. The first scan ever marks nothing as new. Ids no longer
    /// found are forgotten after 90 days, so a finding that comes back after
    /// a long time counts as new again.
    public func apply(_ findings: [Finding], now: Date = Date()) -> [Finding] {
        let stored = load()
        let firstScan = stored.isEmpty
        let previous = stored.filter { now.timeIntervalSince($0.value.lastSeen) < 90 * 86_400 }
        var next = previous
        let marked = findings.map { finding -> Finding in
            var finding = finding
            if let entry = previous[finding.id] {
                finding.firstSeen = entry.firstSeen
                finding.isNew = false
                next[finding.id] = Entry(firstSeen: entry.firstSeen, lastSeen: now)
            } else {
                finding.firstSeen = now
                finding.isNew = !firstScan
                next[finding.id] = Entry(firstSeen: now, lastSeen: now)
            }
            return finding
        }
        save(next)
        return marked
    }

    func save(_ entries: [String: Entry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    public func reset() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
