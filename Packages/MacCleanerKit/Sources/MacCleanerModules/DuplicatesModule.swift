import CryptoKit
import Foundation
import MacCleanerCore

/// Exact duplicate files in the user's folders.
///
/// Files are grouped by size, then by a hash of their first and last 64 KB,
/// and only the remaining candidates get a full SHA-256. Hard links of the
/// same file are not duplicates. In each group one copy is kept: the one not
/// in Downloads, then the most recently modified.
public struct DuplicatesModule: CleanerModule {
    public let id = "duplicates"
    public let title = "Duplicati"
    public var minimumSize: Int64
    private let roots: [URL]
    private let home: URL

    public init(minimumSize: Int64 = 1_000_000, roots: [URL]? = nil,
                home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.minimumSize = minimumSize
        self.home = home
        self.roots = roots ?? AllowedRoots.userFiles(home: home)
    }

    public var allowedRoots: [URL] { roots }

    public func scan() async throws -> ScanReport {
        var bySize: [Int64: [FileRecord]] = [:]
        FileWalker(minimumSize: minimumSize).walk(roots, shouldContinue: { !Task.isCancelled }) { file in
            bySize[file.size, default: []].append(file)
        }

        var groups: [[FileRecord]] = []
        for (_, files) in bySize where files.count > 1 {
            try Task.checkCancellation()
            let distinct = Self.uniqueByFileID(files)
            guard distinct.count > 1 else { continue }
            for partial in Self.group(distinct, by: Self.partialHash) where partial.count > 1 {
                for full in Self.group(partial, by: Self.fullHash) where full.count > 1 {
                    groups.append(full)
                }
            }
        }

        let downloads = PathUtils.realPath(home.appendingPathComponent("Downloads")) + "/"
        let categories: [ScanCategory] = groups.map { files in
            let keep = Self.copyToKeep(files, downloadsPrefix: downloads)
            let items = files.map { file in
                let isKept = file.url == keep.url
                return ScanItem(url: file.url, size: file.size, risk: .medium, autoSelect: !isKept,
                                needsHelper: false,
                                detail: isKept ? "Copia da tenere" : file.url.deletingLastPathComponent().path)
            }
            return ScanCategory(id: "dup-\(keep.url.path)",
                                title: "\(keep.url.lastPathComponent) · \(files.count) copie",
                                items: items, keep: keep.url)
        }
        .sorted { $0.totalSize > $1.totalSize }
        return ScanReport(moduleID: id, categories: categories)
    }

    static func copyToKeep(_ files: [FileRecord], downloadsPrefix: String) -> FileRecord {
        files.max { a, b in
            let aOutside = !a.url.path.hasPrefix(downloadsPrefix)
            let bOutside = !b.url.path.hasPrefix(downloadsPrefix)
            if aOutside != bOutside { return !aOutside }
            return (a.modified ?? .distantPast) < (b.modified ?? .distantPast)
        }!
    }

    static func uniqueByFileID(_ files: [FileRecord]) -> [FileRecord] {
        var seen: Set<UInt64> = []
        return files.filter { file in
            guard let id = file.fileID else { return true }
            return seen.insert(id).inserted
        }
    }

    static func group(_ files: [FileRecord], by hash: (URL) -> String?) -> [[FileRecord]] {
        var buckets: [String: [FileRecord]] = [:]
        for file in files {
            guard let key = hash(file.url) else { continue }
            buckets[key, default: []].append(file)
        }
        return Array(buckets.values)
    }

    static let chunk = 64 * 1024

    static func partialHash(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        guard let head = try? handle.read(upToCount: chunk) else { return nil }
        hasher.update(data: head)
        if let end = try? handle.seekToEnd(), end > UInt64(chunk * 2) {
            try? handle.seek(toOffset: end - UInt64(chunk))
            if let tail = try? handle.read(upToCount: chunk) { hasher.update(data: tail) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func fullHash(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try? handle.read(upToCount: 1 << 20), !data.isEmpty {
            if Task.isCancelled { return nil }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
