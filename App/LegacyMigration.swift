import Foundation

/// Carries over what the app kept under its previous name, MacCleaner (up to
/// version 1.0): the operations log, the quarantine and the user folders in
/// Application Support, and the preferences stored under the old bundle id.
/// Each move happens once, only when the new location does not exist yet.
enum LegacyMigration {
    static let oldName = "MacCleaner"
    static let newName = "Maestrale"
    static let oldDefaultsDomain = "it.nico.maccleaner"

    /// Runs every migration once. Safe to call at every launch.
    static func run(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                    defaults: UserDefaults = .standard) {
        for relative in ["Library/Logs", "Library/Application Support"] {
            let folder = home.appendingPathComponent(relative)
            moveIfNeeded(from: folder.appendingPathComponent(oldName), to: folder.appendingPathComponent(newName))
        }
        // Both log folders exist (the new one was created first): keep the old
        // log next to the new one instead of losing it.
        let logs = home.appendingPathComponent("Library/Logs")
        moveIfNeeded(from: logs.appendingPathComponent("\(oldName)/operations.log"),
                     to: logs.appendingPathComponent("\(newName)/operations-maccleaner.log"))
        copyDefaultsIfNeeded(into: defaults)
    }

    /// Moves `old` to `new` when `old` exists and `new` does not. Returns true on a move.
    @discardableResult
    static func moveIfNeeded(from old: URL, to new: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { return false }
        do {
            try fm.moveItem(at: old, to: new)
            return true
        } catch {
            return false
        }
    }

    /// Copies the preferences of the old bundle id into `defaults`, without
    /// overwriting anything already set under the new one.
    static func copyDefaultsIfNeeded(into defaults: UserDefaults, from oldDomain: String = oldDefaultsDomain) {
        guard defaults.object(forKey: migratedKey) == nil,
              let old = defaults.persistentDomain(forName: oldDomain), !old.isEmpty else { return }
        for (key, value) in old where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
        defaults.set(true, forKey: migratedKey)
    }

    static let migratedKey = "migratedFromMacCleaner"
}
