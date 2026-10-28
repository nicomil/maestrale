import MacCleanerCore
import MacCleanerModules
import Observation
import SwiftUI

/// Live view of the processes: who uses the CPU, the memory, the disk and the
/// network, with the Protection verdict next to each one.
@MainActor
@Observable
final class ActivityModel {
    enum SortKey: String, CaseIterable { case cpu = "CPU", memory = "Memoria", network = "Rete", disk = "Disco" }

    var activities: [ProcessActivity] = []
    var findings: [Int32: Finding] = [:]
    var signatures: [String: CodeSignature] = [:]
    var sortKey: SortKey = .cpu
    var onlyMine = true
    var message: String?
    var isRunning = false

    private let sampler = ProcessSampler()
    private var history: [[ProcessActivity]] = []
    private var sockets: [SocketInfo] = []
    private var ticks = 0
    private var task: Task<Void, Never>?

    var sorted: [ProcessActivity] {
        let mine = getuid()
        return activities
            .filter { !onlyMine || $0.process.uid == mine }
            .sorted {
                switch sortKey {
                case .cpu: $0.cpu > $1.cpu
                case .memory: $0.memory > $1.memory
                case .network: $0.networkInPerSecond + $0.networkOutPerSecond > $1.networkInPerSecond + $1.networkOutPerSecond
                case .disk: $0.diskReadPerSecond + $0.diskWritePerSecond > $1.diskReadPerSecond + $1.diskWritePerSecond
                }
            }
    }

    func start() {
        guard task == nil else { return }
        isRunning = true
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isRunning = false
    }

    private func tick() async {
        let sampler = self.sampler
        let refreshSockets = ticks % 5 == 0
        let known = signatures
        let result = await Task.detached { () -> ([ProcessActivity], [SocketInfo]?, [String: CodeSignature]) in
            let sample = sampler.sample()
            let sockets = refreshSockets ? Sockets.list(commands: SystemCommands()) : nil
            var signatures = known
            let evaluator = SecurityFrameworkSignatures()
            for activity in sample {
                guard let path = activity.process.path, signatures[path] == nil else { continue }
                signatures[path] = evaluator.signature(of: URL(fileURLWithPath: path))
            }
            return (sample, sockets, signatures)
        }.value
        ticks += 1
        activities = result.0
        if let sockets = result.1 { self.sockets = sockets }
        signatures = result.2
        history.append(result.0)
        if history.count > 3 { history.removeFirst(history.count - 3) }
        let samples = history
        let sockets = self.sockets
        let signatureTable = signatures
        let found = await Task.detached {
            ProcessesCheck(samples: samples, sockets: sockets, interval: 2)
                .run(CheckContext(signatures: FakeSignatures(signatureTable, fallback: .unsigned), launchItems: []))
        }.value
        findings = Dictionary(found.compactMap { finding -> (Int32, Finding)? in
            guard case .terminateProcess(let pid) = finding.action else {
                return Int32(finding.id.split(separator: "|")[1]).map { ($0, finding) }
            }
            return (pid, finding)
        }, uniquingKeysWith: { a, _ in a })
    }

    func terminate(_ activity: ProcessActivity) {
        guard activity.process.uid == getuid() else { return }
        if kill(activity.process.pid, SIGTERM) == 0 {
            message = "\(activity.process.name) terminato"
        } else {
            message = "\(activity.process.name): non terminato (\(String(cString: strerror(errno))))"
        }
    }
}

struct ActivityView: View {
    @Environment(AppModel.self) private var model
    @State private var pendingKill: ProcessActivity?
    private var activity: ActivityModel { model.activity }

    var body: some View {
        @Bindable var activity = activity
        VStack(spacing: 0) {
            HStack {
                Text("\(activity.sorted.count) processi").font(.title2.bold())
                if activity.findings.values.contains(where: { $0.severity >= .warning }) {
                    Text("\(activity.findings.values.filter { $0.severity >= .warning }.count) da controllare").foregroundStyle(.orange)
                }
                Spacer()
                Picker("Ordina per", selection: $activity.sortKey) {
                    ForEach(ActivityModel.SortKey.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).fixedSize()
                Toggle("Solo i miei", isOn: $activity.onlyMine).toggleStyle(.checkbox)
            }
            .padding()
            Divider()
            Table(activity.sorted) {
                TableColumn("Processo") { row in
                    HStack(spacing: 6) {
                        if let finding = activity.findings[row.process.pid] {
                            Image(systemName: finding.severity == .danger ? "exclamationmark.octagon.fill"
                                  : finding.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                                .foregroundStyle(finding.severity == .danger ? .red : finding.severity == .warning ? .orange : .blue)
                                .help(finding.reasons.joined(separator: "\n"))
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.process.name)
                            if let path = row.process.path {
                                Text(path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                        }
                    }
                }
                .width(min: 180, ideal: 240)
                TableColumn("PID") { row in Text(String(row.process.pid)).monospacedDigit() }.width(60)
                TableColumn("CPU") { row in Text(String(format: "%.0f%%", row.cpu * 100)).monospacedDigit() }.width(60)
                TableColumn("Memoria") { row in Text(formatBytes(Int64(row.memory))).monospacedDigit() }.width(80)
                TableColumn("Rete") { row in Text(rate(row.networkInPerSecond + row.networkOutPerSecond)).monospacedDigit() }.width(80)
                TableColumn("Disco") { row in Text(rate(row.diskReadPerSecond + row.diskWritePerSecond)).monospacedDigit() }.width(80)
                TableColumn("Firma") { row in Text(signatureText(row)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail) }.width(120)
                TableColumn("") { row in
                    HStack {
                        if let path = row.process.path {
                            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } label: { Image(systemName: "magnifyingglass") }
                                .buttonStyle(.borderless)
                        }
                        if row.process.uid == getuid(), row.process.pid != ProcessInfo.processInfo.processIdentifier {
                            Button("Termina") { pendingKill = row }.controlSize(.small)
                        }
                    }
                }
                .width(90)
            }
            Divider()
            HStack {
                if let message = activity.message { Text(message).foregroundStyle(.secondary) }
                Spacer()
                Text("Aggiornato ogni 2 secondi. CPU: 100% = un core intero.").font(.caption).foregroundStyle(.tertiary)
            }
            .padding()
        }
        .navigationTitle("Attività")
        .onAppear { activity.start() }
        .onDisappear { activity.stop() }
        .confirmationDialog("Terminare \(pendingKill?.process.name ?? "")?",
                            isPresented: Binding(get: { pendingKill != nil }, set: { if !$0 { pendingKill = nil } }),
                            presenting: pendingKill) { row in
            Button("Termina", role: .destructive) { activity.terminate(row) }
        } message: { row in
            Text("Il processo \(row.process.pid) riceverà il segnale di chiusura. Se riparte da solo, cerca il suo elemento di avvio in Protezione.")
        }
    }

    private func rate(_ bytesPerSecond: Double) -> String {
        bytesPerSecond < 1024 ? "—" : formatBytes(Int64(bytesPerSecond)) + "/s"
    }

    private func signatureText(_ row: ProcessActivity) -> String {
        guard let path = row.process.path, let signature = activity.signatures[path] else { return "" }
        switch signature {
        case .apple: return "Apple"
        case .signed(let team, let notarized): return (notarized ? "Notarizzata" : "Firmata") + (team.map { " · \($0)" } ?? "")
        case .adHoc: return "Ad-hoc"
        case .unsigned: return "Non firmato"
        case .invalid: return "Firma non valida"
        }
    }
}
