import Foundation
import MacCleanerCore

/// Apps that arrived in the last weeks, with where they came from: the
/// quarantine attribute names the download event, and macOS keeps the event
/// (with its URL) in the LaunchServices quarantine database.
public struct RecentInstallsCheck: ProtectionCheck {
    public let id = "recent-installs"
    public let title = "App installate di recente"
    public let requirement = CheckRequirement.fullDiskAccess
    let folders: [URL]?
    let days: Int

    public init(folders: [URL]? = nil, days: Int = 30) {
        self.folders = folders
        self.days = days
    }

    public struct QuarantineEvent: Equatable, Sendable {
        public let identifier: String
        public let date: Date?
        public let agent: String?
        public let dataURL: String?
        public let originURL: String?
    }

    public func run(_ context: CheckContext) -> [Finding] {
        let events = Self.events(home: context.home)
        var findings: [Finding] = []
        for app in AppInventory(home: context.home, folders: folders).appURLs() {
            guard let values = try? app.resourceValues(forKeys: [.creationDateKey, .addedToDirectoryDateKey]),
                  let added = values.addedToDirectoryDate ?? values.creationDate,
                  context.now.timeIntervalSince(added) < Double(days) * 86_400 else { continue }
            let signature = context.signatures.signature(of: app)
            if signature == .apple { continue }
            let quarantine = Self.quarantineAttribute(app)
            let event = quarantine.flatMap { $0.eventIdentifier }.flatMap { events[$0] }
            var evidence = ["Aggiunta il \(added.formatted(date: .numeric, time: .shortened))"]
            var reasons: [String] = []
            var severity = Finding.Severity.info
            if let event {
                let origin = event.dataURL ?? event.originURL
                reasons.append("Scaricata \(event.agent.map { "con \($0)" } ?? "")\(origin.map { " da \(Self.host(of: $0) ?? $0)" } ?? "")")
                if let data = event.dataURL { evidence.append("URL: \(data)") }
                if let origin = event.originURL { evidence.append("Pagina: \(origin)") }
            } else if let quarantine {
                reasons.append("Scaricata con \(quarantine.agent ?? "un'app sconosciuta")")
            } else if Self.isFromAppStore(app) {
                reasons.append("Installata dall'App Store")
            } else if signature.isAppleOrNotarized {
                // Apps update themselves by replacing the bundle, which looks like a
                // fresh install without a download: a notarized app is not news.
                continue
            } else {
                reasons.append("Nessuna traccia del download: copiata, estratta da un archivio o attributo di quarantena rimosso")
                severity = .info
            }
            switch signature {
            case .unsigned: reasons.append("App non firmata"); severity = max(severity, .warning)
            case .adHoc: reasons.append("Firma ad-hoc"); severity = max(severity, .warning)
            case .invalid: reasons.append("Firma non valida"); severity = max(severity, .warning)
            case .signed(_, false): reasons.append("Non notarizzata")
            default: break
            }
            findings.append(Finding(category: .application, key: "recent|\(app.path)", severity: severity, title: app.lastPathComponent,
                                    path: app, reasons: reasons, evidence: evidence, action: .trash, team: signature.team))
        }
        return findings
    }

    public struct QuarantineAttribute: Equatable, Sendable {
        public let flags: String
        public let agent: String?
        public let eventIdentifier: String?

        /// "flags;hex timestamp;agent;event UUID"
        public init?(_ value: String) {
            let parts = value.components(separatedBy: ";")
            guard parts.count >= 2 else { return nil }
            flags = parts[0]
            agent = parts.count > 2 && !parts[2].isEmpty ? parts[2] : nil
            eventIdentifier = parts.count > 3 && !parts[3].isEmpty ? parts[3] : nil
        }
    }

    static func quarantineAttribute(_ url: URL) -> QuarantineAttribute? {
        let size = getxattr(url.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard getxattr(url.path, "com.apple.quarantine", &buffer, size, 0, XATTR_NOFOLLOW) == size else { return nil }
        return QuarantineAttribute(String(decoding: buffer, as: UTF8.self))
    }

    static func isFromAppStore(_ app: URL) -> Bool {
        FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/_MASReceipt/receipt").path)
    }

    /// The quarantine events by identifier, from the LaunchServices database.
    static func events(home: URL) -> [String: QuarantineEvent] {
        let db = home.appendingPathComponent("Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2")
        guard FileManager.default.fileExists(atPath: db.path), let reader = SQLiteDB(url: db, readOnly: true) else { return [:] }
        let rows = reader.rows("SELECT LSQuarantineEventIdentifier, LSQuarantineTimeStamp, LSQuarantineAgentName, LSQuarantineDataURLString, LSQuarantineOriginURLString FROM LSQuarantineEvent")
        return Dictionary(rows.compactMap { row -> (String, QuarantineEvent)? in
            guard row.count >= 5 else { return nil }
            let date = Double(row[1]).map { Date(timeIntervalSinceReferenceDate: $0) }
            return (row[0], QuarantineEvent(identifier: row[0], date: date, agent: row[2].isEmpty ? nil : row[2],
                                            dataURL: row[3].isEmpty ? nil : row[3], originURL: row[4].isEmpty ? nil : row[4]))
        }, uniquingKeysWith: { a, _ in a })
    }

    static func host(of url: String) -> String? { URL(string: url)?.host }
}
