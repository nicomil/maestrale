import MaestraleCore
import MaestraleModules
import SwiftUI

/// Live CPU, memory, disk and battery in the menu bar, with quick actions.
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var monitor = SystemMonitor()
    @State private var snapshot: SystemSnapshot?
    @State private var message: String?
    @State private var watcher = BusyProcessWatcher()
    @State private var busy: BusyProcessWatcher.Alert?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Maestrale").font(.headline)
            if let snapshot {
                meter("CPU", value: snapshot.cpuUsage, text: "\(Int(snapshot.cpuUsage * 100))%")
                meter("Memoria", value: snapshot.memoryPressure,
                      text: "\(formatBytes(Int64(snapshot.memoryUsed))) di \(formatBytes(Int64(snapshot.memoryTotal)))")
                meter("Disco", value: snapshot.diskUsedFraction, text: "\(formatBytes(snapshot.diskFree)) liberi")
                if let battery = snapshot.batteryLevel {
                    meter("Batteria", value: battery, text: "\(Int(battery * 100))%\(snapshot.isCharging ? " · in carica" : "")",
                          inverted: true)
                }
            } else {
                ProgressView().controlSize(.small)
            }
            if let busy {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(busy.name) usa il \(Int(busy.cpu * 100))% della CPU da più di un minuto").font(.callout)
                        Text(busy.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            HStack {
                Button("Libera RAM") {
                    Task {
                        do {
                            try await Task.detached { try AdminRunner().run(.freeRAM) }.value
                            message = "RAM liberata"
                        } catch { message = nil }
                    }
                }
                Button("Apri Maestrale") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                .keyboardShortcut(.defaultAction)
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            Divider()
            Button("Esci da Maestrale") { NSApp.terminate(nil) }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 280)
        .task {
            while !Task.isCancelled {
                snapshot = monitor.snapshot()
                let watcher = self.watcher
                busy = await Task.detached { watcher.check() }.value
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func meter(_ title: String, value: Double, text: String, inverted: Bool = false) -> some View {
        let level = inverted ? 1 - value : value
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                Spacer()
                Text(text).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.callout)
            ProgressView(value: min(max(value, 0), 1))
                .tint(level > 0.9 ? .red : level > 0.75 ? .orange : .accentColor)
        }
    }
}

/// The user's YARA rule sets and hash lists. The app downloads nothing: the
/// user gets the files from the publisher and checks the digest shown here.
struct RulesSettings: View {
    @State private var files: [RuleFile] = RuleStore().files()
    @State private var message: String?

    var body: some View {
        Text("Le regole di base di Maestrale sono sempre attive. Aggiungi set aperti come YARA-Forge o le regole macOS di Elastic, "
             + "e l'esportazione di MalwareBazaar per gli hash noti. Confronta lo SHA-256 con quello pubblicato.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        ForEach(files) { file in
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name).bold()
                    Text("\(file.isHashList ? "Elenco di hash" : "Regole YARA") · \(formatBytes(file.size))").font(.caption).foregroundStyle(.secondary)
                    Text(file.sha256).font(.caption2.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button("Rimuovi") {
                    try? RuleStore().remove(file)
                    files = RuleStore().files()
                }
            }
        }
        HStack {
            Button("Aggiungi file…") { add() }
            Spacer()
            Link("YARA-Forge", destination: URL(string: "https://github.com/YARAHQ/yara-forge/releases")!)
            Link("Elastic", destination: URL(string: "https://github.com/elastic/protections-artifacts/tree/main/yara/rules")!)
            Link("MalwareBazaar", destination: URL(string: "https://bazaar.abuse.ch/export/")!)
        }
        .font(.callout)
        if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.data]
        panel.message = "Scegli file .yar/.yara (regole) o .csv/.txt (hash SHA-256)"
        guard panel.runModal() == .OK else { return }
        var problems: [String] = []
        for url in panel.urls {
            do { try RuleStore().add(url) } catch { problems.append("\(url.lastPathComponent): \(error)") }
        }
        files = RuleStore().files()
        message = problems.isEmpty ? "Aggiunti \(panel.urls.count) file; la prossima scansione li userà." : problems.joined(separator: " · ")
    }
}

/// Notices a non-Apple process that keeps a core busy for over a minute.
final class BusyProcessWatcher: @unchecked Sendable {
    struct Alert: Equatable {
        let name: String
        let cpu: Double
        let detail: String
    }

    private let sampler = ProcessSampler()
    private let signatures = CachedSignatures()
    private var streaks: [Int32: Int] = [:]
    private let lock = NSLock()

    /// Called every 2 seconds; 30 consecutive busy samples make a minute.
    func check() -> Alert? {
        lock.lock(); defer { lock.unlock() }
        let sample = sampler.sample()
        var alert: Alert?
        var next: [Int32: Int] = [:]
        for activity in sample where activity.cpu >= 0.8 {
            let streak = (streaks[activity.process.pid] ?? 0) + 1
            next[activity.process.pid] = streak
            guard streak >= 30, let path = activity.process.path,
                  signatures.signature(of: URL(fileURLWithPath: path)) != .apple else { continue }
            if alert == nil || activity.cpu > alert!.cpu {
                alert = Alert(name: activity.process.name, cpu: activity.cpu, detail: path)
            }
        }
        streaks = next
        return alert
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Scheduler.intervalKey) private var interval = "never"
    @AppStorage("showMenuBar") private var showMenuBar = true
    @AppStorage("largeFileMB") private var largeFileMB = 50
    @AppStorage("defaultRemovalMode") private var defaultMode = RemovalMode.trash.rawValue

    var body: some View {
        Form {
            Section("Pulizia") {
                Picker("Modalità predefinita", selection: $defaultMode) {
                    Text("Sposta nel Cestino").tag(RemovalMode.trash.rawValue)
                    Text("Prova (non rimuove nulla)").tag(RemovalMode.dryRun.rawValue)
                    Text("Elimina definitivamente").tag(RemovalMode.delete.rawValue)
                }
                Stepper("File grandi da \(largeFileMB) MB", value: $largeFileMB, in: 10...2000, step: 10)
            }
            Section("Automatico") {
                Picker("Scansione automatica", selection: $interval) {
                    Text("Mai").tag("never")
                    Text("Ogni giorno").tag("daily")
                    Text("Ogni settimana").tag("weekly")
                }
                Text("Controlla i file inutili e la Protezione: manda una notifica se c'è più di 500 MB da liberare o se compare un nuovo pericolo. Non rimuove nulla da sola.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Mostra il monitor nella barra dei menu", isOn: $showMenuBar)
            }
            Section("Firme malware (Protezione)") {
                RulesSettings()
            }
            Section("Permessi") {
                LabeledContent("Accesso completo al disco") {
                    Button("Apri Impostazioni") {
                        NSWorkspace.shared.open(URL(string:
                            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                    }
                }
                LabeledContent("Registro delle operazioni") {
                    Button("Mostra") { NSWorkspace.shared.activateFileViewerSelecting([OperationLog.standard.fileURL]) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding(.vertical)
        .onChange(of: interval) { _, value in if value != "never" { Scheduler.requestNotifications() } }
        .onChange(of: largeFileMB) { _, value in model.setLargeFileThreshold(megabytes: value) }
        .onChange(of: defaultMode) { _, value in model.removalMode = RemovalMode(rawValue: value) ?? .trash }
    }
}
