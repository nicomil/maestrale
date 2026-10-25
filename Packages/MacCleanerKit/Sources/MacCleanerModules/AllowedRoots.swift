import Foundation
import MacCleanerCore

/// The folders the app may remove things from without the helper.
/// Every rule path must fall strictly under one of these (a root itself is
/// never removed), which a test checks.
public enum AllowedRoots {
    public static func user(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        let relative = [
            "Library/Caches",
            "Library/Containers",
            "Library/Application Support",
            "Library/Logs",
            "Library/Developer/Xcode",
            "Library/Developer/CoreSimulator",
            "Library/pnpm",
            ".gradle",
            ".npm",
            ".cache",
            ".Trash",
        ]
        return relative.map { home.appendingPathComponent($0) }
            + RuleEngine(home: home).expand("/Volumes/*/.Trashes/$UID")
    }

    /// The user's own document folders (Desktop, Documents, Downloads, Movies,
    /// any other visible folder in the home), excluding Library and Applications.
    /// Used by the modules that list personal files: removal goes to the Trash.
    public static func userFiles(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
        return names
            .filter { !$0.hasPrefix(".") && !["Library", "Applications"].contains($0) }
            .map { home.appendingPathComponent($0) }
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
    }
}
