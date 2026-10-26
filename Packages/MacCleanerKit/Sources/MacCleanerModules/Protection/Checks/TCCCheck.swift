import AppKit
import Foundation
import MacCleanerCore

/// Who holds the permissions a spy needs: Accessibility, Input Monitoring,
/// Screen Recording, Full Disk Access, Automation. Reads the user's TCC
/// database (Full Disk Access needed) and the system one when the privileged
/// evidence is available.
public struct TCCCheck: ProtectionCheck {
    public let id = "tcc"
    public let title = "Permessi di privacy"
    public let requirement = CheckRequirement.fullDiskAccess
    let userDatabase: URL?

    public init(userDatabase: URL? = nil) { self.userDatabase = userDatabase }

    static let sensitive: [String: (title: String, why: String)] = [
        "kTCCServiceAccessibility": ("Accessibilità", "può controllare il Mac e leggere quello che c'è sullo schermo"),
        "kTCCServiceListenEvent": ("Monitoraggio input", "può registrare tutto quello che scrivi, password comprese"),
        "kTCCServiceScreenCapture": ("Registrazione schermo", "può vedere lo schermo in ogni momento"),
        "kTCCServiceSystemPolicyAllFiles": ("Accesso completo al disco", "legge ogni file, inclusi Mail, Messaggi e Safari"),
        "kTCCServiceAppleEvents": ("Automazione", "può comandare altre app"),
        "kTCCServiceDeveloperTool": ("Strumenti per sviluppatori", "può eseguire software non verificato"),
        "kTCCServicePostEvent": ("Invio di eventi", "può simulare tastiera e mouse"),
    ]

    public struct Grant: Equatable, Sendable {
        public let service: String
        public let client: String
        public let isPath: Bool
        public let allowed: Bool
    }

    public func run(_ context: CheckContext) -> [Finding] {
        var grants: [(Grant, String)] = []
        let db = userDatabase ?? context.home.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
        if FileManager.default.fileExists(atPath: db.path), let reader = SQLiteDB(url: db, readOnly: true) {
            let rows = reader.rows("SELECT service, client, client_type, auth_value FROM access")
            grants += Self.grants(from: rows).map { ($0, "utente") }
        }
        if let system = context.systemEvidence?["tcc"] {
            let rows = system.components(separatedBy: "\n").filter { !$0.isEmpty }.map { $0.components(separatedBy: "|") }
            grants += Self.grants(from: rows).map { ($0, "sistema") }
        }
        var findings: [Finding] = []
        for (grant, scope) in grants where grant.allowed {
            guard let meaning = Self.sensitive[grant.service] else { continue }
            let path = grant.isPath ? grant.client : Self.appPath(bundleID: grant.client)
            let signature = path.map { context.signatures.signature(of: URL(fileURLWithPath: $0)) }
            if signature == .apple { continue }
            var reasons = ["Ha il permesso \"\(meaning.title)\": \(meaning.why)"]
            var severity = Finding.Severity.info
            switch signature {
            case .unsigned?, .adHoc?:
                reasons.append("Il programma non è firmato da uno sviluppatore identificato")
                severity = .danger
            case .invalid?:
                reasons.append("La firma del programma non è valida")
                severity = .danger
            case .signed(_, false)?:
                reasons.append("Firmato ma non notarizzato")
                severity = .warning
            case nil:
                reasons.append("App non trovata sul Mac: il permesso resta a chiunque usi lo stesso identificatore")
                severity = .warning
            default:
                break
            }
            if let path, KnownLocations.kind(of: path) != .normal {
                reasons.append("Il programma sta in una cartella temporanea o nascosta")
                severity = .danger
            }
            let name = path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? grant.client
            findings.append(Finding(category: .configuration, key: "tcc|\(scope)|\(grant.service)|\(grant.client)", severity: severity,
                                    title: "\(name): \(meaning.title)", path: path.map { URL(fileURLWithPath: $0) }, reasons: reasons,
                                    evidence: ["Servizio: \(grant.service)", "Client: \(grant.client)", "Ambito: \(scope)"],
                                    action: .openSettings(SettingsLinks.privacy), team: signature?.team))
        }
        return findings
    }

    /// Rows "service, client, client_type, auth_value": client_type 1 is a
    /// path, auth_value 2 is allowed (3 is "limited", also a grant).
    static func grants(from rows: [[String]]) -> [Grant] {
        rows.compactMap { row in
            guard row.count >= 4 else { return nil }
            let allowed = Int(row[3]).map { $0 == 2 || $0 == 3 } ?? false
            return Grant(service: row[0], client: row[1], isPath: row[2] == "1", allowed: allowed)
        }
    }

    static func appPath(bundleID: String) -> String? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.path
    }
}
