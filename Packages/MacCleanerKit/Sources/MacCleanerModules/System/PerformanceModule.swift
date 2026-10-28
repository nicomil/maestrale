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

    /// Removing the plist needs the password unless it is in the user's own folder.
    public var needsAdmin: Bool { domain != .userAgent }
    /// Agents, also the ones in /Library/LaunchAgents, run in the user's session
    /// and can be stopped there without a password; daemons need it.
    public var stopNeedsAdmin: Bool { domain == .systemDaemon }
    /// The launchd service, e.g. "gui/501/com.vendor.agent" or "system/com.vendor.daemon".
    public var service: String {
        "\(domain == .systemDaemon ? "system" : "gui/\(getuid())")/\(label)"
    }
}

public enum LaunchItemError: Error, Equatable, Sendable {
    /// launchd still has the item after it was asked to stop it.
    case stillRunning(String)
    case failed(String)
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
                let disabled = (dict["Disabled"] as? Bool ?? false) || (domain != .systemDaemon && disabledUser.contains(label))
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

    /// True while launchd has the item loaded.
    public func isLoaded(_ item: LaunchItem) -> Bool {
        Self.status("/bin/launchctl", ["print", item.service]) == 0
    }

    /// Starts or stops an agent in the user's session (no password needed) and
    /// keeps it that way across logins. Throws if it is still loaded after stopping.
    public func setAgent(_ item: LaunchItem, enabled: Bool) throws {
        guard item.domain != .systemDaemon else { throw LaunchItemError.failed("\(item.label) è un servizio di sistema") }
        let domain = "gui/\(getuid())"
        if enabled {
            _ = Self.run("/bin/launchctl", ["enable", item.service])
            _ = Self.run("/bin/launchctl", ["bootstrap", domain, item.plist.path])
        } else {
            _ = Self.run("/bin/launchctl", ["bootout", item.service])
            _ = Self.run("/bin/launchctl", ["disable", item.service])
            if isLoaded(item) { throw LaunchItemError.stillRunning(item.label) }
        }
    }

    /// Stops a system daemon with the password and checks that it stopped.
    public func stopDaemon(_ item: LaunchItem, runner: AdminRunner = AdminRunner()) throws {
        guard item.domain == .systemDaemon else { return try setAgent(item, enabled: false) }
        guard isLoaded(item) else { return }
        try runner.run(.bootoutDaemon(label: item.label))
        if isLoaded(item) { throw LaunchItemError.stillRunning(item.label) }
    }

    /// Stops the item, then moves its plist to the Trash. If it cannot be
    /// stopped, the plist stays where it is, so the item is not hidden from
    /// the list while it keeps running.
    public func remove(_ item: LaunchItem, runner: AdminRunner = AdminRunner()) throws {
        switch item.domain {
        case .userAgent:
            try setAgent(item, enabled: false)
            let remover = SafeRemover(allowedRoots: [home.appendingPathComponent("Library/LaunchAgents")], mode: .trash)
            if case .failure(let error) = remover.remove([item.plist]).first?.result {
                throw LaunchItemError.failed("\(item.label): \(error)")
            }
        case .systemAgent:
            try setAgent(item, enabled: false)
            try runner.run(.moveToTrash([item.plist]))
        case .systemDaemon:
            // One password prompt: the root shell stops the daemon and moves the
            // plist only if launchd no longer has it.
            try runner.run(.removeDaemon(label: item.label, plist: item.plist))
            if isLoaded(item) { throw LaunchItemError.stillRunning(item.label) }
        }
    }

    static func status(_ tool: String, _ args: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
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

    /// For tasks that remove something you may want back, what to tell the
    /// user before running them; nil when no confirmation is needed.
    public var warning: String? {
        switch kind {
        case .freePurgeable:
            "Verranno eliminate tutte le istantanee locali di Time Machine: non potrai più recuperare "
                + "da lì versioni precedenti o file cancellati. I backup sul disco di Time Machine restano."
        case .repairPermissions:
            "I permessi personalizzati delle cartelle nella tua Inizio verranno riportati a quelli standard."
        default: nil
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

    /// Runs a task and returns what it achieved, in one line for the card.
    /// Admin tasks show the macOS password prompt. Measurements are taken
    /// before and after, so the user sees an effect, not only "done".
    public func run(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                    commands: any CommandRunner = SystemCommands()) async throws -> String {
        switch kind {
        case .freeRAM:
            let before = SystemMonitor.cachedFiles()
            try AdminRunner().run(.freeRAM)
            // The kernel takes a moment to account for the freed pages.
            try? await Task.sleep(for: .seconds(1))
            return Self.ramSummary(before: before, after: SystemMonitor.cachedFiles())
        case .flushDNS:
            try AdminRunner().run(.flushDNS)
            return "Cache DNS svuotata e mDNSResponder riavviato"
        case .reindexSpotlight:
            try AdminRunner().run(.reindexSpotlight)
            return "Indice cancellato: Spotlight lo ricostruisce in background. Le ricerche saranno incomplete per un po'."
        case .freePurgeable:
            let snapshots = Self.localSnapshots(commands: commands)
            guard !snapshots.isEmpty else {
                throw MaintenanceError.nothingToDo("Nessuna istantanea locale di Time Machine: niente da eliminare")
            }
            let before = SystemMonitor.disk().free
            try AdminRunner().run(.thinLocalSnapshots)
            let remaining = Self.localSnapshots(commands: commands)
            return Self.snapshotsSummary(before: snapshots.count, after: remaining.count,
                                         freed: SystemMonitor.disk().free - before)
        case .repairPermissions:
            try AdminRunner().run(.repairPermissions)
            return "Permessi della cartella Inizio riportati a quelli standard"
        case .periodicScripts:
            try AdminRunner().run(.runPeriodicScripts)
            return "Script giornalieri, settimanali e mensili eseguiti"
        case .speedUpMail:
            // Compact the envelope database while Mail is closed.
            if await PrivacyScanner.isRunning("com.apple.mail") { throw PrivacyError.browserRunning("Mail") }
            guard let index = Self.mailEnvelopeIndex(home: home) else { throw PrivacyError.failed("database di Mail non trovato") }
            let before = FileSizer.allocatedSize(of: index)
            guard let db = SQLiteDB(url: index, readOnly: false), db.execute("VACUUM") else {
                throw PrivacyError.failed("il database di Mail non si lascia compattare")
            }
            let after = FileSizer.allocatedSize(of: index)
            return "Database di Mail: \(Self.bytes(before)) → \(Self.bytes(after))"
        }
    }

    /// Names of the local Time Machine snapshots of the startup disk.
    static func localSnapshots(commands: any CommandRunner) -> [String] {
        parseSnapshots(commands.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"]))
    }

    /// "com.apple.TimeMachine.2026-10-28-101500.local" lines, header skipped.
    static func parseSnapshots(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("com.apple.TimeMachine.") }
    }

    static func ramSummary(before: UInt64, after: UInt64) -> String {
        let freed = before > after ? before - after : 0
        let effect = freed < 50_000_000 ? "quasi nulla da liberare" : "liberati \(bytes(Int64(freed)))"
        return "File in cache: \(bytes(Int64(before))) → \(bytes(Int64(after))) · \(effect)"
    }

    static func snapshotsSummary(before: Int, after: Int, freed: Int64) -> String {
        let removed = max(0, before - after)
        let what = removed == 0 ? "Nessuna istantanea eliminata (macOS le ha ritenute necessarie)"
            : "Eliminate \(removed) istantanee su \(before)"
        return freed > 0 ? "\(what) · liberati \(bytes(freed))" : what
    }

    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, value), countStyle: .file)
    }
}

/// A task that had nothing to do: not a failure, but not "done" either.
public enum MaintenanceError: Error, Equatable, Sendable {
    case nothingToDo(String)
}
