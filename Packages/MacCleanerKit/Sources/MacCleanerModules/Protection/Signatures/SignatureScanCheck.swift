import CryptoKit
import Foundation
import MacCleanerCore

/// Which files are worth a signature scan: executables and scripts in the
/// places malware lives, never the whole disk.
public enum ScanTargets {
    public static let maximumFileSize: Int64 = 50_000_000
    static let scriptExtensions: Set<String> = ["sh", "bash", "zsh", "command", "py", "rb", "pl", "js", "scpt", "applescript", "jar", "plist"]
    static let machOMagics: Set<UInt32> = [0xfeedface, 0xfeedfacf, 0xcafebabe, 0xcefaedfe, 0xcffaedfe, 0xbebafeca]

    /// Folders scanned a few levels deep, and the apps' main executables.
    public static func candidates(home: URL, launchItems: [LaunchItem], extraFolders: [URL] = []) -> [URL] {
        var urls: [URL] = []
        var seen: Set<String> = []
        func add(_ url: URL) {
            let path = url.standardizedFileURL.path
            if seen.insert(path).inserted { urls.append(url) }
        }
        for item in launchItems {
            if let program = item.program, program.hasPrefix("/") { add(URL(fileURLWithPath: program)) }
        }
        for app in AppInventory(home: home).appURLs() {
            if let executable = Bundle(url: app)?.executableURL { add(executable) }
        }
        let folders: [(URL, Int)] = [
            (home.appendingPathComponent("Downloads"), 2),
            (home.appendingPathComponent("Desktop"), 1),
            (home.appendingPathComponent("Library/Application Support"), 3),
            (home.appendingPathComponent("Library/LaunchAgents"), 1),
            (home.appendingPathComponent(".local/bin"), 1),
            (URL(fileURLWithPath: "/tmp"), 2),
            (URL(fileURLWithPath: "/private/var/tmp"), 2),
            (URL(fileURLWithPath: "/Users/Shared"), 3),
            (URL(fileURLWithPath: "/Library/Application Support"), 3),
            (URL(fileURLWithPath: "/Library/LaunchAgents"), 1),
            (URL(fileURLWithPath: "/Library/LaunchDaemons"), 1),
        ] + extraFolders.map { ($0, 3) }
        for (folder, depth) in folders {
            walk(folder, depth: depth, add: add)
        }
        return urls.filter(isScannable)
    }

    static func walk(_ folder: URL, depth: Int, add: (URL) -> Void) {
        guard depth >= 0, let entries = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
            options: []) else { return }
        for entry in entries.prefix(2000) {
            guard let values = try? entry.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]),
                  values.isSymbolicLink != true else { continue }
            if values.isRegularFile == true {
                add(entry)
            } else if values.isDirectory == true {
                // App bundles: only the main executable matters, handled above.
                if entry.pathExtension == "app" {
                    if let executable = Bundle(url: entry)?.executableURL { add(executable) }
                    continue
                }
                walk(entry, depth: depth - 1, add: add)
            }
        }
    }

    /// Mach-O, a shebang, or a script extension; small enough to scan.
    public static func isScannable(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true,
              let size = values.fileSize, size > 0, Int64(size) <= maximumFileSize else { return false }
        if scriptExtensions.contains(url.pathExtension.lowercased()) { return true }
        guard let handle = try? FileHandle(forReadingFrom: url), let head = try? handle.read(upToCount: 4) else { return false }
        try? handle.close()
        if head.count >= 2, head[0] == 0x23, head[1] == 0x21 { return true } // "#!"
        guard head.count == 4 else { return false }
        let magic = head.withUnsafeBytes { $0.load(as: UInt32.self) }
        return machOMagics.contains(magic) || machOMagics.contains(magic.byteSwapped)
    }
}

/// Remembers the verdict for each file (by path, size and date) so a
/// rescan with the same rules only reads what changed.
public struct ScanCache: Sendable {
    public struct Entry: Codable, Sendable {
        public var size: Int64
        public var modified: TimeInterval
        public var sha256: String?
        public var matches: [String]       // "namespace:rule" identifiers
    }

    public struct Contents: Codable, Sendable {
        public var rulesVersion: String
        public var entries: [String: Entry]
    }

    public let fileURL: URL
    public static let standardURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/MacCleaner/protection/signature-cache.json")

    public init(fileURL: URL = ScanCache.standardURL) { self.fileURL = fileURL }

    public func load(rulesVersion: String) -> [String: Entry] {
        guard let data = try? Data(contentsOf: fileURL), let contents = try? JSONDecoder().decode(Contents.self, from: data),
              contents.rulesVersion == rulesVersion else { return [:] }
        return contents.entries
    }

    public func save(_ entries: [String: Entry], rulesVersion: String) {
        guard let data = try? JSONEncoder().encode(Contents(rulesVersion: rulesVersion, entries: entries)) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// YARA rules and known hashes over the files that matter.
public struct SignatureScanCheck: ProtectionCheck {
    public let id = "signatures"
    public let title = "Firme conosciute"
    let store: RuleStore
    let cache: ScanCache?
    let extraFolders: [URL]
    let onlyFolders: Bool

    /// `onlyFolders` limits the scan to `extraFolders` (for tests).
    public init(store: RuleStore = RuleStore(), cache: ScanCache? = ScanCache(), extraFolders: [URL] = [], onlyFolders: Bool = false) {
        self.store = store
        self.cache = cache
        self.extraFolders = extraFolders
        self.onlyFolders = onlyFolders
    }

    public func run(_ context: CheckContext) -> [Finding] {
        let sources = store.ruleSources()
        let hashes = KnownHashes.load(store.hashFiles())
        let engine = try? YaraEngine(sources: sources)
        guard engine != nil || !hashes.isEmpty else { return [] }
        let version = store.version()
        var entries = cache?.load(rulesVersion: version) ?? [:]
        let candidates = onlyFolders
            ? extraFolders.flatMap { folder -> [URL] in var urls: [URL] = []; ScanTargets.walk(folder, depth: 3) { urls.append($0) }; return urls.filter(ScanTargets.isScannable) }
            : ScanTargets.candidates(home: context.home, launchItems: context.launchItems, extraFolders: extraFolders)
        var findings: [Finding] = []
        let deadline = context.now.addingTimeInterval(120)

        for url in candidates {
            if Date() > deadline { break }
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize else { continue }
            let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
            let key = url.path
            var entry: ScanCache.Entry
            if let cached = entries[key], cached.size == Int64(size), cached.modified == modified {
                entry = cached
            } else {
                var matches: [String] = []
                if let engine, let found = try? engine.scan(file: url) {
                    matches = found.map { "\($0.namespace):\($0.rule)|\($0.severity.rawValue)|\($0.description)|\($0.source)" }
                }
                let sha = hashes.isEmpty ? nil : Self.sha256(of: url)
                entry = ScanCache.Entry(size: Int64(size), modified: modified, sha256: sha, matches: matches)
                entries[key] = entry
            }
            for match in entry.matches {
                let parts = match.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
                let severity = Finding.Severity(rawValue: Int(parts.count > 1 ? parts[1] : "2") ?? 2) ?? .danger
                findings.append(Finding(category: .signature, key: "\(url.path)|\(parts[0])", severity: severity,
                                        title: "\(url.lastPathComponent): \(parts[0].split(separator: ":").last ?? "")", path: url,
                                        reasons: [parts.count > 2 ? parts[2] : "Corrisponde a una regola YARA"],
                                        evidence: ["Regola: \(parts[0])", "Fonte: \(parts.count > 3 ? parts[3] : "?")"],
                                        action: .quarantine))
            }
            if let sha = entry.sha256, let name = hashes.entries[sha] {
                findings.append(Finding(category: .signature, key: "\(url.path)|hash", severity: .danger,
                                        title: "\(url.lastPathComponent): malware conosciuto", path: url,
                                        reasons: ["Il file ha lo stesso SHA-256 di un campione segnalato come \(name)"],
                                        evidence: ["SHA-256: \(sha)"], action: .quarantine))
            }
        }
        cache?.save(entries, rulesVersion: version)
        return findings
    }

    static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
