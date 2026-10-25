import Foundation
import MacCleanerCore

/// A launch agent or daemon: something that starts by itself.
public struct LaunchItem: Identifiable, Sendable, Hashable {
    public enum Domain: String, Sendable {
        case userAgent = "Utente"
        case systemAgent = "Agente di sistema"
        case systemDaemon = "Servizio di sistema"
    }

    public var id: URL { plist }
    public let plist: URL
    public let label: String
    public let program: String?
    public let domain: Domain
    public let isDisabled: Bool
    /// The program file no longer exists: the item is broken.
    public let isBroken: Bool
    /// The app that ships the program, when it lives inside an app bundle.
    public let ownerApp: URL?

    public var needsAdmin: Bool { domain != .userAgent }
}

/// Reads launch agents and daemons, and enables, disables or removes them.
public struct LaunchItemsScanner: Sendable {
    let home: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    public func scan() -> [LaunchItem] {
        let disabledUser = Self.disabledLabels(domain: "gui/\(getuid())")
        let folders: [(URL, LaunchItem.Domain)] = [
            (home.appendingPathComponent("Library/LaunchAgents"), .userAgent),
            (URL(fileURLWithPath: "/Library/LaunchAgents"), .systemAgent),
            (URL(fileURLWithPath: "/Library/LaunchDaemons"), .systemDaemon),
        ]
        var items: [LaunchItem] = []
        for (folder, domain) in folders {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasSuffix(".plist") {
                let plist = folder.appendingPathComponent(name)
                guard let dict = NSDictionary(contentsOf: plist) as? [String: Any] else { continue }
                let label = dict["Label"] as? String ?? name.replacingOccurrences(of: ".plist", with: "")
                let program = (dict["Program"] as? String) ?? (dict["ProgramArguments"] as? [String])?.first
                let broken = program.map { $0.hasPrefix("/") && !FileManager.default.fileExists(atPath: $0) } ?? false
                let disabled = (dict["Disabled"] as? Bool ?? false) || (domain == .userAgent && disabledUser.contains(label))
                items.append(LaunchItem(plist: plist, label: label, program: program, domain: domain,
                                        isDisabled: disabled, isBroken: broken, ownerApp: program.flatMap(Self.ownerApp)))
            }
        }
        return items.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    static func ownerApp(_ program: String) -> URL? {
        guard let range = program.range(of: ".app/") else { return nil }
        return URL(fileURLWithPath: String(program[..<range.lowerBound]) + ".app")
    }

    /// Labels disabled with `launchctl disable` in a domain.
    static func disabledLabels(domain: String) -> Set<String> {
        let output = run("/bin/launchctl", ["print-disabled", domain])
        var labels: Set<String> = []
        for line in output.components(separatedBy: "\n") {
            // "com.vendor.agent" => disabled   (or => true on older systems)
            let parts = line.components(separatedBy: "=>")
            guard parts.count == 2 else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            guard value == "disabled" || value == "true" else { continue }
            labels.insert(parts[0].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
        }
        return labels
    }

    /// Stops and disables a user agent (no password needed).
    public func setUserAgent(_ item: LaunchItem, enabled: Bool) -> Bool {
        guard item.domain == .userAgent else { return false }
        let domain = "gui/\(getuid())"
        if enabled {
            _ = Self.run("/bin/launchctl", ["enable", "\(domain)/\(item.label)"])
            _ = Self.run("/bin/launchctl", ["bootstrap", domain, item.plist.path])
        } else {
            _ = Self.run("/bin/launchctl", ["bootout", "\(domain)/\(item.label)"])
            _ = Self.run("/bin/launchctl", ["disable", "\(domain)/\(item.label)"])
        }
        return true
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// A one-click maintenance task.
public struct MaintenanceTask: Identifiable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case freeRAM, flushDNS, reindexSpotlight, speedUpMail, freePurgeable, repairPermissions, periodicScripts
    }

    public let kind: Kind
    public var id: String { kind.rawValue }

    public var title: String {
        switch kind {
        case .freeRAM: "Libera RAM"
        case .flushDNS: "Svuota cache DNS"
        case .reindexSpotlight: "Reindicizza Spotlight"
        case .speedUpMail: "Velocizza Mail"
        case .freePurgeable: "Libera spazio eliminabile"
        case .repairPermissions: "Ripara permessi"
        case .periodicScripts: "Script di manutenzione"
        }
    }

    public var explanation: String {
        switch kind {
        case .freeRAM: "Svuota la memoria inattiva. Utile quando il Mac rallenta dopo aver chiuso app pesanti."
        case .flushDNS: "Risolve siti che non si aprono o che portano al server sbagliato."
        case .reindexSpotlight: "Ricostruisce l'indice di ricerca se Spotlight non trova i file. Richiede tempo."
        case .speedUpMail: "Compatta il database di Mail per ricerche più veloci. Mail deve essere chiusa."
        case .freePurgeable: "Elimina le istantanee locali di Time Machine e lo spazio che macOS tiene di riserva."
        case .repairPermissions: "Ripristina i permessi della cartella Inizio se compaiono errori di accesso."
        case .periodicScripts: "Ruota i log e pulisce i file temporanei di sistema."
        }
    }

    public var icon: String {
        switch kind {
        case .freeRAM: "memorychip"
        case .flushDNS: "network"
        case .reindexSpotlight: "magnifyingglass"
        case .speedUpMail: "envelope"
        case .freePurgeable: "externaldrive.badge.timemachine"
        case .repairPermissions: "lock.rotation"
        case .periodicScripts: "gearshape.2"
        }
    }

    /// The admin operation, or nil when the task runs as the user.
    public var adminOperation: AdminOperation? {
        switch kind {
        case .freeRAM: .freeRAM
        case .flushDNS: .flushDNS
        case .reindexSpotlight: .reindexSpotlight
        case .speedUpMail: nil
        case .freePurgeable: .thinLocalSnapshots
        case .repairPermissions: .repairPermissions
        case .periodicScripts: .runPeriodicScripts
        }
    }

    /// Tasks that make sense on this Mac.
    public static func available(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [MaintenanceTask] {
        Kind.allCases.filter { kind in
            switch kind {
            case .speedUpMail: return mailEnvelopeIndex(home: home) != nil
            case .periodicScripts: return FileManager.default.isExecutableFile(atPath: "/usr/sbin/periodic")
            default: return true
            }
        }
        .map(MaintenanceTask.init(kind:))
    }

    static func mailEnvelopeIndex(home: URL) -> URL? {
        let mail = home.appendingPathComponent("Library/Mail")
        let versions = ((try? FileManager.default.contentsOfDirectory(atPath: mail.path)) ?? [])
            .filter { $0.hasPrefix("V") }.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        for version in versions {
            let index = mail.appendingPathComponent("\(version)/MailData/Envelope Index")
            if FileManager.default.fileExists(atPath: index.path) { return index }
        }
        return nil
    }

    /// Runs a task. Admin tasks show the macOS password prompt.
    public func run(home: URL = FileManager.default.homeDirectoryForCurrentUser) async throws {
        if let operation = adminOperation {
            try AdminRunner().run(operation)
            return
        }
        // Speed up Mail: compact the envelope database while Mail is closed.
        if await PrivacyScanner.isRunning("com.apple.mail") { throw PrivacyError.browserRunning("Mail") }
        guard let index = Self.mailEnvelopeIndex(home: home), let db = SQLiteDB(url: index, readOnly: false),
              db.execute("VACUUM") else { throw PrivacyError.failed("Envelope Index") }
    }
}
