import Foundation

/// A regular file found while walking a folder tree.
public struct FileRecord: Sendable {
    public let url: URL
    public let size: Int64
    public let modified: Date?
    /// The most recent of the access and modification dates.
    public let lastUsed: Date?
    /// Identifies the file on disk; two hard links share it.
    public let fileID: UInt64?
}

/// Walks folder trees and reports regular files.
///
/// Hidden items and the content of packages (apps, photo libraries) are
/// skipped, and so are packages themselves: deleting a whole library by
/// mistake is the worst outcome for a "big files" list.
public struct FileWalker: Sendable {
    public var excludedFolderNames: Set<String>
    public var excludedPaths: [String]
    public var minimumSize: Int64

    public init(excludedFolderNames: Set<String> = ["node_modules", "Library", ".git"],
                excludedPaths: [String] = [], minimumSize: Int64 = 0) {
        self.excludedFolderNames = excludedFolderNames
        self.excludedPaths = excludedPaths
        self.minimumSize = minimumSize
    }

    static let keys: [URLResourceKey] = [
        .isRegularFileKey, .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey,
        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .contentModificationDateKey,
        .contentAccessDateKey, .fileResourceIdentifierKey,
    ]

    /// Calls `visit` for each file at least `minimumSize` bytes big.
    /// Return `false` from `shouldContinue` to stop early (cancellation).
    public func walk(_ roots: [URL], shouldContinue: () -> Bool = { true }, visit: (FileRecord) -> Void) {
        let keySet = Set(Self.keys)
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: Self.keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in true }
            ) else { continue }

            for case let url as URL in enumerator {
                guard shouldContinue() else { return }
                guard let values = try? url.resourceValues(forKeys: keySet) else { continue }
                if values.isSymbolicLink == true { continue }
                if values.isPackage == true { continue }
                if values.isDirectory == true {
                    if excludedFolderNames.contains(url.lastPathComponent)
                        || excludedPaths.contains(where: { url.path.hasPrefix($0) }) {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                guard values.isRegularFile == true else { continue }
                let size = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
                guard size >= minimumSize else { continue }
                let modified = values.contentModificationDate
                let accessed = values.contentAccessDate
                let lastUsed = [modified, accessed].compactMap { $0 }.max()
                visit(FileRecord(url: url, size: size, modified: modified, lastUsed: lastUsed,
                                 fileID: Self.fileID(values.fileResourceIdentifier)))
            }
        }
    }

    static func fileID(_ identifier: (any NSCopying & NSSecureCoding & NSObjectProtocol)?) -> UInt64? {
        guard let data = identifier as? Data, data.count >= 8 else {
            return (identifier as? NSNumber)?.uint64Value
        }
        return data.prefix(8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
    }
}

/// Human friendly "how long ago" text in Italian, e.g. "2 anni fa".
public enum RelativeAge {
    public static func text(since date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "it_IT")
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

public enum PathUtils {
    /// The canonical path as the file system reports it (`realpath(3)`).
    /// Unlike `URL.resolvingSymlinksInPath()`, it keeps `/private` in front of
    /// `/var` and `/tmp`, which matches what directory enumerators return.
    public static func realPath(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.standardizedFileURL.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
