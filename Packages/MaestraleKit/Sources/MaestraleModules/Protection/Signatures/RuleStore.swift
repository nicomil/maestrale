import CryptoKit
import Foundation
import MaestraleCore

/// A rule file or a hash list the user added, with the digest to compare
/// against what the publisher states.
public struct RuleFile: Identifiable, Sendable, Hashable {
    public let url: URL
    public let size: Int64
    public let sha256: String
    public var id: String { url.path }
    public var name: String { url.lastPathComponent }
    public var isHashList: Bool { ["csv", "txt"].contains(url.pathExtension.lowercased()) }
}

/// The folder of rule sets and hash lists. Nothing is downloaded by the app:
/// the user fetches the files from the publisher and adds them here.
public struct RuleStore: Sendable {
    public let folder: URL
    public static let standardFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Maestrale/rules")

    public init(folder: URL = RuleStore.standardFolder) { self.folder = folder }

    /// The rules shipped with the app.
    public static var bundledRules: URL? {
        Bundle.module.url(forResource: "maestrale-basic", withExtension: "yar", subdirectory: "rules")
            ?? Bundle.module.url(forResource: "maestrale-basic", withExtension: "yar")
    }

    public func files() -> [RuleFile] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])) ?? [])
            .filter { ["yar", "yara", "csv", "txt"].contains($0.pathExtension.lowercased()) }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return RuleFile(url: url, size: Int64(data.count), sha256: Self.sha256(data))
            }
            .sorted { $0.name < $1.name }
    }

    public func ruleFiles() -> [RuleFile] { files().filter { !$0.isHashList } }
    public func hashFiles() -> [RuleFile] { files().filter(\.isHashList) }

    /// Copies a file in (never moved, never followed if it is a symlink).
    @discardableResult
    public func add(_ source: URL) throws -> RuleFile {
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw YaraError.compilation(["non è un file"]) }
        guard (values.fileSize ?? 0) < 200_000_000 else { throw YaraError.compilation(["file troppo grande"]) }
        let data = try Data(contentsOf: source)
        if !RuleFile(url: source, size: 0, sha256: "").isHashList {
            // Refuse a rule file that does not compile, so the scan never breaks.
            _ = try YaraEngine(sources: [(source.lastPathComponent, String(decoding: data, as: UTF8.self))])
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(source.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try data.write(to: destination, options: .atomic)
        return RuleFile(url: destination, size: Int64(data.count), sha256: Self.sha256(data))
    }

    public func remove(_ file: RuleFile) throws {
        let inside = file.url.resolvingSymlinksInPath().path.hasPrefix(folder.resolvingSymlinksInPath().path + "/")
        guard inside else { throw YaraError.compilation(["file fuori dalla cartella delle regole"]) }
        try FileManager.default.removeItem(at: file.url)
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Everything to compile: the bundled rules plus the user's rule files.
    public func ruleSources() -> [(namespace: String, text: String)] {
        var sources: [(String, String)] = []
        if let bundled = Self.bundledRules, let text = try? String(contentsOf: bundled, encoding: .utf8) {
            sources.append(("maestrale", text))
        }
        for file in ruleFiles() {
            if let text = try? String(contentsOf: file.url, encoding: .utf8) {
                sources.append((file.name.replacingOccurrences(of: ".", with: "_"), text))
            }
        }
        return sources
    }

    /// A digest of every rule and hash file: when it changes, the scan cache is stale.
    public func version() -> String {
        var hasher = SHA256()
        for source in ruleSources() { hasher.update(data: Data(source.text.utf8)) }
        for file in hashFiles() { hasher.update(data: Data(file.sha256.utf8)) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// SHA-256 hashes of known malware, from MalwareBazaar's CSV export or any
/// text file with one hash per line.
public struct KnownHashes: Sendable {
    public let entries: [String: String]   // sha256 (lowercase) -> signature or source

    public init(entries: [String: String]) { self.entries = entries }

    public static func load(_ files: [RuleFile]) -> KnownHashes {
        var entries: [String: String] = [:]
        for file in files {
            guard let text = try? String(contentsOf: file.url, encoding: .utf8) else { continue }
            entries.merge(parse(text, source: file.name)) { a, _ in a }
        }
        return KnownHashes(entries: entries)
    }

    /// MalwareBazaar rows: "first_seen","sha256","md5","sha1","reporter","file_name","type","mime","signature",…
    /// Plain lines: a 64-hex hash, optionally followed by a name.
    public static func parse(_ text: String, source: String) -> [String: String] {
        var entries: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("\"") {
                let fields = line.split(separator: ",", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) }
                guard fields.count > 1, fields[1].count == 64 else { continue }
                let signature = fields.count > 8 && !fields[8].isEmpty && fields[8] != "n/a" ? fields[8] : source
                entries[fields[1].lowercased()] = signature
            } else if let match = line.firstMatch(of: /^([0-9a-fA-F]{64})\b\s*(.*)$/) {
                let name = String(match.2).trimmingCharacters(in: .whitespaces)
                entries[String(match.1).lowercased()] = name.isEmpty ? source : name
            }
        }
        return entries
    }

    public var isEmpty: Bool { entries.isEmpty }
}
