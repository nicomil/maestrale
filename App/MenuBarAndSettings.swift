import MacCleanerCore
import MacCleanerModules
import SwiftUI

/// Live CPU, memory, disk and battery in the menu bar, with quick actions.
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var monitor = SystemMonitor()
    @State private var snapshot: SystemSnapshot?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("MacCleaner").font(.headline)
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
                Button("Apri MacCleaner") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                .keyboardShortcut(.defaultAction)
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            Divider()
            Button("Esci da MacCleaner") { NSApp.terminate(nil) }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 280)
        .task {
            while !Task.isCancelled {
                snapshot = monitor.snapshot()
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
                Text("Controlla i file inutili e manda una notifica se c'è più di 500 MB da liberare. Non rimuove nulla da sola.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Mostra il monitor nella barra dei menu", isOn: $showMenuBar)
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
