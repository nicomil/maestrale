import Foundation

/// What to do with the files the user chose to clean.
public enum RemovalMode: String, Sendable, CaseIterable {
    /// Move to the Trash (default, can be undone).
    case trash
    /// Delete permanently.
    case delete
    /// Do nothing, only report what would happen.
    case dryRun
}

/// Why a path was refused or failed.
public enum RemovalError: Error, Equatable, Sendable {
    case outsideAllowedRoots
    case isAllowedRoot
    case systemProtected
    case notFound
    case failed(String)
}

public struct RemovalOutcome: Sendable {
    public let url: URL
    public let result: Result<Int64, RemovalError>

    public init(url: URL, result: Result<Int64, RemovalError>) {
        self.url = url
        self.result = result
    }
}

/// Removes files only inside a fixed set of folders.
///
/// Every path is resolved (symlinks included) before the check, so a link that
/// points outside the allowed folders is refused. The allowed folder itself is
/// never removed, only what is inside it.
public struct SafeRemover: Sendable {
    public let allowedRoots: [URL]
    public let mode: RemovalMode
    private let log: OperationLog?

    public init(allowedRoots: [URL], mode: RemovalMode, log: OperationLog? = .standard) {
        self.allowedRoots = allowedRoots.map { $0.resolvingSymlinksInPath().standardizedFileURL }
        self.mode = mode
        self.log = log
    }

    /// Checks a path without touching it.
    public func validate(_ url: URL) -> RemovalError? {
        let fm = FileManager.default
        // "." and ".." are never valid: "root/sub/.." would pass the prefix
        // check below while pointing at the root or above it. They are refused
        // rather than collapsed, because collapsing them before resolving
        // symlinks can point at a different folder than the one removed.
        if url.pathComponents.contains(where: { $0 == "." || $0 == ".." }) { return .outsideAllowedRoots }
        // Resolve the parent, not the item: removing a symlink must remove the
        // link itself, but the link must live inside an allowed folder.
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let target = parent.appendingPathComponent(url.lastPathComponent)

        guard fm.fileExists(atPath: target.path) || isSymlink(target) else { return .notFound }
        if allowedRoots.contains(where: { $0.path == target.path }) { return .isAllowedRoot }
        guard allowedRoots.contains(where: { target.path.hasPrefix($0.path + "/") }) else {
            return .outsideAllowedRoots
        }
        if Self.isSystemProtected(target) { return .systemProtected }
        return nil
    }

    /// Removes the given items and returns one outcome per item.
    public func remove(_ urls: [URL]) -> [RemovalOutcome] {
        urls.map { url in
            let outcome = removeOne(url)
            log?.record(mode: mode, outcome: outcome)
            return outcome
        }
    }

    private func removeOne(_ url: URL) -> RemovalOutcome {
        if let error = validate(url) { return RemovalOutcome(url: url, result: .failure(error)) }
        let size = FileSizer.allocatedSize(of: url)
        do {
            switch mode {
            case .dryRun: break
            case .trash: try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            case .delete: try FileManager.default.removeItem(at: url)
            }
            return RemovalOutcome(url: url, result: .success(size))
        } catch {
            return RemovalOutcome(url: url, result: .failure(.failed(error.localizedDescription)))
        }
    }

    private func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }

    /// True for files protected by System Integrity Protection (the
    /// `restricted` flag) and for the system folders that are always off limits.
    public static func isSystemProtected(_ url: URL) -> Bool {
        let blockedPrefixes = ["/System/", "/bin/", "/sbin/", "/usr/bin/", "/usr/lib/", "/usr/libexec/",
                               "/usr/sbin/", "/usr/share/", "/private/var/db/"]
        if blockedPrefixes.contains(where: { url.path.hasPrefix($0) }) { return true }

        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        let restrictedFlag: UInt32 = 0x0008_0000 // SF_RESTRICTED
        return info.st_flags & restrictedFlag != 0
    }
}
