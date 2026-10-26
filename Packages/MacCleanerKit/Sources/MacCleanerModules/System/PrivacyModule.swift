import AppKit
import Foundation
import MacCleanerCore

/// A kind of private data kept by a browser or by macOS.
public enum PrivacyKind: String, CaseIterable, Sendable {
    case history, cookies, downloads, autofill, passwords, sessions, recentItems, quarantine

    public var title: String {
        switch self {
        case .history: "Cronologia"
        case .cookies: "Cookie"
        case .downloads: "Cronologia download"
        case .autofill: "Dati dei moduli"
        case .passwords: "Password salvate"
        case .sessions: "Schede dell'ultima sessione"
        case .recentItems: "Elementi recenti"
        case .quarantine: "Storico dei file scaricati (quarantena)"
        }
    }
}

/// One row of the Privacy screen: e.g. "Chrome, profile Default, cookies: 1240".
public struct PrivacyItem: Identifiable, Sendable, Hashable {
    public let id: String
    public let owner: String
    public let ownerBundleID: String?
    public let profile: String?
    public let kind: PrivacyKind
    public let count: Int
    /// Saved passwords are never preselected.
    public var autoSelect: Bool { kind != .passwords && kind != .autofill }
    let action: PrivacyAction
}

/// How an item is cleaned.
enum PrivacyAction: Sendable, Hashable {
    /// Run these SQL statements on the database (then VACUUM).
    case sql(URL, [String])
    /// Move these files to the Trash.
    case trash([URL])

    var key: String {
        switch self {
        case .sql(let url, _): url.lastPathComponent
        case .trash: "files"
        }
    }
}

public enum PrivacyError: Error, Equatable, Sendable {
    case browserRunning(String)
    case failed(String)
}

/// Finds and removes browser and system traces.
public struct PrivacyScanner: Sendable {
    let home: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    /// Chromium browsers and the folder of their profiles.
    static let chromium: [(name: String, bundleID: String, folder: String)] = [
        ("Google Chrome", "com.google.Chrome", "Google/Chrome"),
        ("Brave", "com.brave.Browser", "BraveSoftware/Brave-Browser"),
        ("Microsoft Edge", "com.microsoft.edgemac", "Microsoft Edge"),
        ("Arc", "company.thebrowser.Browser", "Arc/User Data"),
        ("Vivaldi", "com.vivaldi.Vivaldi", "Vivaldi"),
    ]

    public func scan() -> [PrivacyItem] {
        var items: [PrivacyItem] = []
        let support = home.appendingPathComponent("Library/Application Support")

        for browser in Self.chromium {
            let base = support.appendingPathComponent(browser.folder)
            for profile in chromiumProfiles(base) {
                let dir = base.appendingPathComponent(profile)
                let owner = (browser.name, browser.bundleID, profile)
                items += sqlItems(owner, db: dir.appendingPathComponent("History"), [
                    (.history, "urls", ["DELETE FROM visits", "DELETE FROM urls", "DELETE FROM keyword_search_terms",
                                        "DELETE FROM segments", "DELETE FROM segment_usage"]),
                    (.downloads, "downloads", ["DELETE FROM downloads", "DELETE FROM downloads_url_chains"]),
                ])
                for cookies in ["Network/Cookies", "Cookies"] {
                    items += sqlItems(owner, db: dir.appendingPathComponent(cookies),
                                      [(.cookies, "cookies", ["DELETE FROM cookies"])])
                }
                items += sqlItems(owner, db: dir.appendingPathComponent("Web Data"),
                                  [(.autofill, "autofill", ["DELETE FROM autofill"])])
                items += sqlItems(owner, db: dir.appendingPathComponent("Login Data"),
                                  [(.passwords, "logins", ["DELETE FROM logins"])])
                let sessions = dir.appendingPathComponent("Sessions")
                if let files = try? FileManager.default.contentsOfDirectory(at: sessions, includingPropertiesForKeys: nil),
                   !files.isEmpty {
                    items.append(item(owner, .sessions, files.count, .trash(files)))
                }
            }
        }

        // Firefox: keep bookmarked places, remove the rest of the history.
        let firefox = support.appendingPathComponent("Firefox/Profiles")
        for profile in (try? FileManager.default.contentsOfDirectory(atPath: firefox.path)) ?? [] {
            let dir = firefox.appendingPathComponent(profile)
            let owner = ("Firefox", "org.mozilla.firefox", profile)
            items += sqlItems(owner, db: dir.appendingPathComponent("places.sqlite"), [
                (.history, "moz_historyvisits", ["DELETE FROM moz_historyvisits",
                    "DELETE FROM moz_places WHERE id NOT IN (SELECT fk FROM moz_bookmarks WHERE fk IS NOT NULL)"]),
            ])
            items += sqlItems(owner, db: dir.appendingPathComponent("cookies.sqlite"),
                              [(.cookies, "moz_cookies", ["DELETE FROM moz_cookies"])])
            items += sqlItems(owner, db: dir.appendingPathComponent("formhistory.sqlite"),
                              [(.autofill, "moz_formhistory", ["DELETE FROM moz_formhistory"])])
        }

        // Safari (needs Full Disk Access).
        let safari = ("Safari", "com.apple.Safari", nil as String?)
        items += sqlItems(safari, db: home.appendingPathComponent("Library/Safari/History.db"), [
            (.history, "history_items", ["DELETE FROM history_visits", "DELETE FROM history_items"]),
        ])
        let safariCookies = [
            home.appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies"),
            home.appendingPathComponent("Library/Cookies/Cookies.binarycookies"),
        ].filter { FileManager.default.fileExists(atPath: $0.path) }
        if !safariCookies.isEmpty { items.append(item(safari, .cookies, safariCookies.count, .trash(safariCookies))) }
        let safariDownloads = home.appendingPathComponent("Library/Safari/Downloads.plist")
        if FileManager.default.fileExists(atPath: safariDownloads.path) {
            items.append(item(safari, .downloads, 1, .trash([safariDownloads])))
        }

        // macOS: recent items and the downloads quarantine log.
        let system = ("macOS", nil as String?, nil as String?)
        let shared = home.appendingPathComponent("Library/Application Support/com.apple.sharedfilelist")
        let recent = ((try? FileManager.default.subpathsOfDirectory(atPath: shared.path)) ?? [])
            .filter { $0.hasSuffix(".sfl3") || $0.hasSuffix(".sfl4") || $0.hasSuffix(".sfl2") }
            .filter { $0.contains("Recent") }
            .map { shared.appendingPathComponent($0) }
        if !recent.isEmpty { items.append(item(system, .recentItems, recent.count, .trash(recent))) }
        items += sqlItems(system, db: home.appendingPathComponent("Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2"),
                          [(.quarantine, "LSQuarantineEvent", ["DELETE FROM LSQuarantineEvent"])])
        return items
    }

    /// Browsers whose data exists but cannot be read: macOS protects other
    /// apps' data until the app gets Full Disk Access.
    public func unreadableOwners() -> [String] {
        let support = home.appendingPathComponent("Library/Application Support")
        var owners: [String] = []
        let folders = Self.chromium.map { ($0.name, support.appendingPathComponent($0.folder)) }
            + [("Firefox", support.appendingPathComponent("Firefox/Profiles")),
               ("Safari", home.appendingPathComponent("Library/Safari"))]
        for (name, folder) in folders where FileManager.default.fileExists(atPath: folder.path) {
            if (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) == nil { owners.append(name) }
        }
        let history = home.appendingPathComponent("Library/Safari/History.db")
        if !owners.contains("Safari"), FileManager.default.fileExists(atPath: history.path),
           SQLiteDB(url: history, readOnly: true) == nil {
            owners.append("Safari")
        }
        return owners
    }

    func chromiumProfiles(_ base: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? [])
            .filter { $0 == "Default" || $0.hasPrefix("Profile ") }
            .sorted()
    }

    typealias Owner = (name: String, bundleID: String?, profile: String?)

    func sqlItems(_ owner: Owner, db: URL, _ specs: [(PrivacyKind, String, [String])]) -> [PrivacyItem] {
        guard FileManager.default.fileExists(atPath: db.path), let reader = SQLiteDB(url: db, readOnly: true) else {
            return []
        }
        return specs.compactMap { kind, table, statements in
            guard reader.tableExists(table), let count = reader.count(table), count > 0 else { return nil }
            return item(owner, kind, count, .sql(db, statements))
        }
    }

    func item(_ owner: Owner, _ kind: PrivacyKind, _ count: Int, _ action: PrivacyAction) -> PrivacyItem {
        PrivacyItem(id: [owner.name, owner.profile ?? "", kind.rawValue, action.key].joined(separator: "|"),
                    owner: owner.name, ownerBundleID: owner.bundleID, profile: owner.profile,
                    kind: kind, count: count, action: action)
    }

    /// Cleans one item. The owning browser must be closed: its databases are
    /// locked and it would write the data back on quit.
    public func clean(_ item: PrivacyItem, dryRun: Bool = false) async throws {
        if let bundleID = item.ownerBundleID, await Self.isRunning(bundleID) {
            throw PrivacyError.browserRunning(item.owner)
        }
        guard !dryRun else { return }
        switch item.action {
        case .sql(let url, let statements):
            // SQL deletions cannot be undone: keep a copy in the Trash first.
            do { try backupToTrash(url, for: item) } catch { throw PrivacyError.failed("copia di sicurezza di \(url.lastPathComponent)") }
            guard let db = SQLiteDB(url: url, readOnly: false) else { throw PrivacyError.failed("apertura di \(url.lastPathComponent)") }
            guard db.execute("BEGIN"), statements.allSatisfy({ db.execute($0) }), db.execute("COMMIT") else {
                db.execute("ROLLBACK")
                throw PrivacyError.failed(url.lastPathComponent)
            }
            db.execute("VACUUM")
        case .trash(let urls):
            for url in urls { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
        }
        OperationLog.standard.recordAdmin("privacy \(item.id)", ok: true, detail: "\(item.count)")
    }

    /// Saves a standalone copy of a database into a folder in the Trash, e.g.
    /// "MacCleaner, copia di Google Chrome Default History 2026-10-26 10.15.03".
    /// The copy is made by SQLite itself and read back before anything is
    /// deleted, so it holds the data even when the database is reached through
    /// a symlink or has recent changes in its "-wal" file.
    /// To restore, quit the browser, delete the "-wal" and "-shm" files next to
    /// the original and copy the backup over it.
    @discardableResult
    func backupToTrash(_ db: URL, for item: PrivacyItem, now: Date = Date()) throws -> URL {
        let fm = FileManager.default
        let trash = home.appendingPathComponent(".Trash")
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let base = (["MacCleaner, copia di", item.owner, item.profile, db.lastPathComponent, formatter.string(from: now)]
            .compactMap { $0 }.joined(separator: " ")).replacingOccurrences(of: "/", with: "-")
        var folder = trash.appendingPathComponent(base)
        var counter = 2
        while fm.fileExists(atPath: folder.path) {
            folder = trash.appendingPathComponent("\(base) \(counter)")
            counter += 1
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        guard let source = SQLiteDB(url: db, readOnly: true),
              source.snapshot(to: folder.appendingPathComponent(db.lastPathComponent)) else {
            throw PrivacyError.failed("copia di sicurezza di \(db.lastPathComponent)")
        }
        return folder
    }

    @MainActor
    public static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }
}

/// Saved Wi-Fi networks, read with `networksetup`.
public enum WiFiNetworks {
    public static func preferred() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = ["-listpreferredwirelessnetworks", AdminRunner.wifiInterface()]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        return text.components(separatedBy: "\n").dropFirst()
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
