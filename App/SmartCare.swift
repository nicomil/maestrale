import MacCleanerCore
import MacCleanerModules
import Observation
import SwiftUI
import UserNotifications

/// One-click check of the whole Mac, built on the other screens' models.
/// Only safe, preselected junk is cleaned automatically; everything else
/// links to its screen for review.
@MainActor
@Observable
final class SmartCareModel {
    var isRunning = false
    var lastRun: Date?
    var summary: String?

    func run(_ app: AppModel) async {
        isRunning = true
        summary = nil
        async let junk: Void = app.scan("system-junk")
        async let trash: Void = app.scan("trash")
        async let protection: Void = app.protection.scan()
        async let updates: Void = app.updates.check()
        async let performance: Void = app.performance.scan()
        _ = await (junk, trash, protection, updates, performance)
        lastRun = Date()
        isRunning = false
    }

    /// Cleans the preselected user-level junk (to the Trash).
    func cleanJunk(_ app: AppModel) async {
        guard let report = app.modules["system-junk"]?.report else { return }
        let safe = Set(report.allItems.filter { $0.autoSelect && !$0.needsHelper }.map(\.url))
        app.selection = app.selection.subtracting(report.allItems.map(\.url)).union(safe)
        let previousMode = app.removalMode
        app.removalMode = .trash
        await app.clean("system-junk")
        app.removalMode = previousMode
        summary = app.modules["system-junk"]?.lastCleanSummary
    }
}

struct SmartCareView: View {
    @Environment(AppModel.self) private var model
    @Binding var destination: Destination?
    @State private var stats = SystemMonitor().snapshot()

    private var care: SmartCareModel { model.smartCare }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 14)], spacing: 14) {
                    cleanupCard
                    protectionCard
                    updatesCard
                    performanceCard
                    diskCard
                }
            }
            .padding(24)
        }
        .navigationTitle("Smart Care")
        .task { stats = SystemMonitor().snapshot() }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles").font(.system(size: 44)).foregroundStyle(.tint)
            Text(care.lastRun == nil ? "Controlla tutto il Mac in un clic" : "Ultimo controllo \(care.lastRun!.formatted(date: .omitted, time: .shortened))")
                .font(.title2.bold())
            Text("Pulizia, protezione, aggiornamenti e prestazioni. Niente viene rimosso senza conferma.")
                .foregroundStyle(.secondary)
            Button {
                Task { await care.run(model) }
            } label: {
                Label(care.isRunning ? "Controllo in corso…" : "Avvia Smart Care", systemImage: "play.fill")
                    .frame(minWidth: 200)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(care.isRunning)
            if let summary = care.summary { Text(summary).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity)
    }

    private var cleanupCard: some View {
        let junk = model.modules["system-junk"]?.report
        let trash = model.modules["trash"]?.report
        let safeSize = junk?.allItems.filter { $0.autoSelect && !$0.needsHelper }.reduce(Int64(0)) { $0 + $1.size }
        return CareCard(title: "Pulizia", icon: "internaldrive", tint: .blue,
                        value: safeSize.map(formatBytes),
                        detail: junk == nil ? "Cache, log e file inutili"
                            : "pronti da pulire · Cestino \(formatBytes(trash?.totalSize ?? 0))",
                        isBusy: model.modules["system-junk"]?.isScanning == true) {
            HStack {
                Button("Rivedi") { destination = .module("system-junk") }
                if (safeSize ?? 0) > 0 {
                    Button("Pulisci ora") { Task { await care.cleanJunk(model) } }.buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var protectionCard: some View {
        let count = model.protection.visibleFindings.filter { $0.severity >= .warning }.count
        return CareCard(title: "Protezione", icon: "shield.lefthalf.filled", tint: count == 0 ? .green : .orange,
                        value: model.protection.hasScanned ? (count == 0 ? "Nessun rischio" : "\(count) avvisi") : nil,
                        detail: "Avvio automatico, firme ed estensioni",
                        isBusy: model.protection.isScanning) {
            Button("Apri") { destination = .protection }
        }
    }

    private var updatesCard: some View {
        CareCard(title: "Aggiornamenti", icon: "arrow.down.app", tint: .purple,
                 value: model.updates.lastCheck == nil ? nil : "\(model.updates.updates.count) disponibili",
                 detail: "App Store, Sparkle e Homebrew", isBusy: model.updates.isChecking) {
            Button("Apri") { destination = .updates }
        }
    }

    private var performanceCard: some View {
        let broken = model.performance.launchItems.filter(\.isBroken).count
        let agents = model.performance.launchItems.filter { !$0.isDisabled }.count
        return CareCard(title: "Prestazioni", icon: "gauge.with.dots.needle.67percent", tint: .teal,
                        value: model.performance.hasScanned ? "\(agents) avvii automatici" : nil,
                        detail: broken > 0 ? "\(broken) elementi di avvio rotti" : "RAM \(Int(stats.memoryPressure * 100))% in uso",
                        isBusy: false) {
            Button("Apri") { destination = .performance }
        }
    }

    private var diskCard: some View {
        CareCard(title: "Spazio", icon: "chart.pie", tint: stats.diskUsedFraction > 0.9 ? .red : .indigo,
                 value: "\(formatBytes(stats.diskFree)) liberi",
                 detail: "su \(formatBytes(stats.diskTotal)) · \(Int(stats.diskUsedFraction * 100))% occupato",
                 isBusy: false) {
            Button("Space Lens") { destination = .spaceLens }
        }
    }
}

/// A summary tile on the Smart Care screen.
struct CareCard<Actions: View>: View {
    let title: String
    let icon: String
    let tint: Color
    let value: String?
    let detail: String
    let isBusy: Bool
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: icon).font(.title2).foregroundStyle(tint)
                    .frame(width: 36, height: 36).background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                Text(title).font(.headline)
                Spacer()
                if isBusy { ProgressView().controlSize(.small) }
            }
            Text(value ?? "—").font(.title2.bold()).monospacedDigit()
            Text(detail).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            Spacer(minLength: 0)
            actions()
        }
        .padding()
        .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Background scans on a schedule, with a notification when there is a lot to clean.
@MainActor
final class Scheduler {
    static let intervalKey = "autoScanInterval"   // "never" | "daily" | "weekly"
    static let lastRunKey = "lastAutoScan"
    private var task: Task<Void, Never>?

    func start(_ app: AppModel) {
        task?.cancel()
        task = Task { [weak app] in
            while !Task.isCancelled {
                if let app { await self.runIfDue(app) }
                try? await Task.sleep(for: .seconds(1800))
            }
        }
    }

    private func runIfDue(_ app: AppModel) async {
        let interval: TimeInterval
        switch UserDefaults.standard.string(forKey: Self.intervalKey) ?? "never" {
        case "daily": interval = 86_400
        case "weekly": interval = 7 * 86_400
        default: return
        }
        let last = UserDefaults.standard.object(forKey: Self.lastRunKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= interval else { return }
        UserDefaults.standard.set(Date(), forKey: Self.lastRunKey)
        await app.scan("system-junk")
        let size = app.modules["system-junk"]?.report?.allItems.filter(\.autoSelect).reduce(Int64(0)) { $0 + $1.size } ?? 0
        guard size > 500_000_000 else { return }
        let content = UNMutableNotificationContent()
        content.title = "MacCleaner"
        content.body = "Puoi liberare \(formatBytes(size)) di file inutili."
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "auto-scan", content: content, trigger: nil))
    }

    static func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}
