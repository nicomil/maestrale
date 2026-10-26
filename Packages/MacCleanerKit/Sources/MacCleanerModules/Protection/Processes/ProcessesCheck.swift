import Foundation
import MacCleanerCore

/// Looks at what is running right now the way an expert would in Activity
/// Monitor: who is it, where does it live, is it signed, what is it doing
/// with the CPU and the network.
public struct ProcessesCheck: ProtectionCheck {
    public let id = "processes"
    public let title = "Processi in esecuzione"
    let samples: [[ProcessActivity]]?
    let sockets: [SocketInfo]?
    let intervals: Int
    let interval: TimeInterval

    /// Live sampling, or fixed samples for tests.
    public init(samples: [[ProcessActivity]]? = nil, sockets: [SocketInfo]? = nil, intervals: Int = 3, interval: TimeInterval = 1) {
        self.samples = samples
        self.sockets = sockets
        self.intervals = intervals
        self.interval = interval
    }

    /// Names a user process may legitimately have only when it comes from the system.
    static let systemNames: Set<String> = ["kernel_task", "launchd", "WindowServer", "loginwindow", "mds", "mds_stores", "mdworker",
                                           "coreaudiod", "cfprefsd", "securityd", "trustd", "syspolicyd", "XProtect", "xpcproxy",
                                           "softwareupdated", "sshd", "cupsd", "bluetoothd", "Finder", "Dock", "SystemUIServer"]

    /// Ports used by mining pools, IRC bots and common reverse shells.
    static let suspiciousPorts: Set<Int> = [3333, 4444, 5555, 6666, 6667, 6697, 7777, 8333, 9999, 14433, 14444, 1337, 31337, 45560]

    public func run(_ context: CheckContext) -> [Finding] {
        let samples = self.samples ?? Self.collect(intervals: intervals, interval: interval, commands: context.commands)
        guard let latest = samples.last else { return [] }
        let sockets = self.sockets ?? Sockets.list(commands: context.commands)
            + (context.systemEvidence?["lsof"].map(Sockets.parseTable) ?? [])
        let socketsByPid = Dictionary(grouping: sockets, by: \.pid)
        let byPid = Dictionary(latest.map { ($0.process.pid, $0.process) }, uniquingKeysWith: { a, _ in a })
        var findings: [Finding] = []

        for activity in latest {
            let process = activity.process
            var reasons: [String] = []
            var severity = Finding.Severity.info
            var evidence = ["PID \(process.pid), avviato \(process.started?.formatted(date: .numeric, time: .shortened) ?? "?")"]
            if let parent = byPid[process.parent] { evidence.append("Avviato da \(parent.name) (\(parent.pid))") }
            let path = process.path
            let signature = path.map { context.signatures.signature(of: URL(fileURLWithPath: $0)) }
            var team: String?

            if let path {
                evidence.append("Percorso: \(path)")
                let developerTool = KnownLocations.isDeveloperTooling(path) || KnownLocations.isFromPackageManager(path)
                if let signature {
                    team = signature.team
                    if signature != .apple {
                        let assessed = signature.assess(path: path)
                        reasons += assessed.reasons
                        // Interpreters and tool chains in ~/.pyenv, ~/.local… are rarely signed.
                        severity = max(severity, developerTool && assessed.severity == .warning ? .info : assessed.severity)
                    }
                }
                switch KnownLocations.kind(of: path) {
                case .temporary:
                    reasons.append("Gira da una cartella temporanea o condivisa")
                    severity = .danger
                case .hidden where developerTool:
                    reasons.append("Gira da una cartella di strumenti di sviluppo (es. ~/.local, ~/.pyenv)")
                case .hidden:
                    reasons.append("Gira da una cartella nascosta")
                    severity = max(severity, .warning)
                case .normal:
                    break
                }
                if !FileManager.default.fileExists(atPath: path) {
                    reasons.append("L'eseguibile è stato cancellato mentre il processo gira: tecnica per nascondersi")
                    severity = .danger
                }
                if Self.systemNames.contains(process.name), !KnownLocations.isSystem(path) {
                    reasons.append("Ha il nome di un processo di sistema ma non viene dal sistema")
                    severity = .danger
                }
            }

            // Sustained CPU: busy in every sample, not just a spike.
            let history = samples.compactMap { sample in sample.first { $0.process.pid == process.pid }?.cpu }
            let sustained = history.count == samples.count && history.allSatisfy { $0 >= 0.8 }
            let procSockets = socketsByPid[process.pid] ?? []
            let remotePorts = Set(procSockets.compactMap { $0.remote?.port })
            let miningPort = !remotePorts.isDisjoint(with: Self.suspiciousPorts)
            if sustained, signature != .apple {
                reasons.append(String(format: "Usa il %.0f%% di un core da %d secondi", history.last! * 100, Int(Double(samples.count - 1) * interval)))
                severity = max(severity, miningPort ? .danger : .warning)
                evidence.append("CPU nei campioni: " + history.map { String(format: "%.0f%%", $0 * 100) }.joined(separator: ", "))
            }
            if miningPort {
                reasons.append("Collegato a una porta usata da mining pool, bot IRC o shell remote (\(remotePorts.intersection(Self.suspiciousPorts).sorted().map(String.init).joined(separator: ", ")))")
                severity = max(severity, .warning)
            }
            let listening = procSockets.filter(\.listensOnAllInterfaces)
            if !listening.isEmpty, signature?.isAppleOrNotarized != true {
                reasons.append("In ascolto sulla rete su \(listening.compactMap(\.localPort).map(String.init).joined(separator: ", ")): accetta connessioni da altri computer")
                severity = max(severity, .warning)
            }
            let rawRemote = procSockets.compactMap(\.remote).filter { Self.isRawIP($0.host) && ![80, 443, 53, 123, 5223, 993, 587, 465, 22].contains($0.port) }
            if !rawRemote.isEmpty, signature?.isAppleOrNotarized != true {
                reasons.append("Connesso a indirizzi IP diretti su porte insolite")
                severity = max(severity, .warning)
            }
            evidence += procSockets.prefix(10).map { "\($0.proto) \($0.name)\($0.state.map { " (\($0))" } ?? "")" }

            guard !reasons.isEmpty else { continue }
            findings.append(Finding(category: .process, key: "\(process.pid)|\(path ?? process.name)", severity: severity,
                                    title: "\(process.name) (PID \(process.pid))", path: path.map { URL(fileURLWithPath: $0) },
                                    reasons: reasons, evidence: evidence,
                                    action: process.uid == getuid() ? .terminateProcess(pid: process.pid) : .none, team: team))
        }
        return findings
    }

    static func collect(intervals: Int, interval: TimeInterval, commands: any CommandRunner) -> [[ProcessActivity]] {
        let sampler = ProcessSampler(commands: commands)
        _ = sampler.sample()
        var samples: [[ProcessActivity]] = []
        for _ in 0..<max(intervals, 1) {
            Thread.sleep(forTimeInterval: interval)
            samples.append(sampler.sample())
        }
        return samples
    }

    static func isRawIP(_ host: String) -> Bool {
        host.range(of: #"^\d+\.\d+\.\d+\.\d+$"#, options: .regularExpression) != nil || host.contains(":")
    }
}
