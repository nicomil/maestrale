import MacCleanerCore
import MacCleanerModules
import SwiftUI

struct PrivacyView: View {
    @Environment(AppModel.self) private var model
    @State private var confirm = false
    private var privacy: PrivacyModel { model.privacy }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if privacy.hasScanned {
                    Text("\(privacy.items.count) tipi di dati trovati").font(.title2.bold())
                }
                Spacer()
                if privacy.hasScanned && !privacy.items.isEmpty {
                    Button("Seleziona tutto") { privacy.selectAll() }
                        .disabled(privacy.selection.count == privacy.items.count)
                    Button("Deseleziona tutto") { privacy.deselectAll() }
                        .disabled(privacy.selection.isEmpty)
                }
                if privacy.isScanning { ProgressView().controlSize(.small) }
                Button(privacy.hasScanned ? "Scansiona di nuovo" : "Scansiona") { Task { await privacy.scan() } }
                    .disabled(privacy.isScanning)
            }
            .padding()
            Divider()
            if !privacy.hasScanned {
                ContentUnavailableView("Privacy", systemImage: "hand.raised",
                                       description: Text("Cronologia, cookie e tracce dei browser e di macOS."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if !privacy.unreadable.isEmpty {
                    FullDiskAccessBanner(text: "Per vedere i dati di \(privacy.unreadable.joined(separator: ", ")) serve l'Accesso completo al disco.")
                }
                List {
                    ForEach(privacy.groups, id: \.owner) { group in
                        Section(group.owner) {
                            ForEach(group.items) { item in row(item) }
                        }
                    }
                    if !privacy.wifiNetworks.isEmpty {
                        Section("Reti Wi‑Fi salvate") {
                            ForEach(privacy.wifiNetworks, id: \.self) { network in
                                HStack {
                                    Image(systemName: "wifi").foregroundStyle(.secondary)
                                    Text(network)
                                    Spacer()
                                    Button("Dimentica") { Task { await privacy.forget(network) } }
                                }
                            }
                        }
                    }
                }
                Divider()
                HStack {
                    @Bindable var model = model
                    Toggle("Solo prova", isOn: Binding(get: { model.removalMode == .dryRun },
                                                       set: { model.removalMode = $0 ? .dryRun : .trash }))
                    if let message = privacy.message { Text(message).foregroundStyle(.secondary) }
                    Spacer()
                    Text("I browser devono essere chiusi").font(.caption).foregroundStyle(.tertiary)
                    Button("Pulisci \(privacy.selection.count) voci") { confirm = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(privacy.selection.isEmpty)
                        .confirmationDialog("Pulire le voci selezionate?", isPresented: $confirm) {
                            Button("Pulisci") { Task { await privacy.clean(dryRun: model.removalMode == .dryRun) } }
                        } message: {
                            Text("Prima di modificare i database dei browser ne viene messa una copia nel Cestino. Dopo la pulizia dovrai rifare l'accesso ai siti.")
                        }
                }
                .padding()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("Privacy")
    }

    private func row(_ item: PrivacyItem) -> some View {
        HStack {
            Toggle(isOn: Binding(get: { privacy.selection.contains(item.id) },
                                 set: { on in
                                     if on { privacy.selection.insert(item.id) } else { privacy.selection.remove(item.id) }
                                 })) {
                VStack(alignment: .leading) {
                    Text(item.kind.title)
                    if let profile = item.profile { Text(profile).font(.caption).foregroundStyle(.secondary) }
                }
            }
            if item.kind == .passwords {
                Image(systemName: "key.fill").foregroundStyle(.orange)
                    .help("Le password salvate nel browser verranno cancellate")
            }
            Spacer()
            Text("\(item.count)").monospacedDigit().foregroundStyle(.secondary)
        }
    }
}

struct PerformanceView: View {
    @Environment(AppModel.self) private var model
    @State private var pendingTask: MaintenanceTask?
    @State private var pendingRemoval: LaunchItem?
    private var performance: PerformanceModel { model.performance }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Manutenzione").font(.title2.bold())
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12)], spacing: 12) {
                    ForEach(performance.tasks) { task in taskCard(task) }
                }

                HStack {
                    Text("Avvio automatico").font(.title2.bold())
                    Spacer()
                    Button("Elementi login di macOS…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                    }
                }
                if let message = performance.message { Text(message).foregroundStyle(.secondary) }
                VStack(spacing: 0) {
                    ForEach(performance.launchItems) { item in
                        launchRow(item)
                        Divider()
                    }
                }
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
            }
            .padding()
        }
        .navigationTitle("Prestazioni")
        .task { if !performance.hasScanned { await performance.scan() } }
        .confirmationDialog("\(pendingTask?.title ?? "")?",
                            isPresented: Binding(get: { pendingTask != nil }, set: { if !$0 { pendingTask = nil } }),
                            presenting: pendingTask) { task in
            Button("Esegui", role: .destructive) { Task { await performance.run(task) } }
        } message: { task in
            Text(task.warning ?? "")
        }
        .confirmationDialog("Rimuovere \(pendingRemoval?.label ?? "")?",
                            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
                            presenting: pendingRemoval) { item in
            Button("Rimuovi", role: .destructive) { Task { await performance.remove(item) } }
        } message: { _ in
            Text("Verrà fermato e il suo file di avvio spostato nel Cestino. Il programma resta dov'è.")
        }
    }

    private func taskCard(_ task: MaintenanceTask) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: task.icon).font(.title2).foregroundStyle(Color.accentColor)
                Text(task.title).font(.headline)
                Spacer()
                if task.adminOperation != nil {
                    Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                        .help("Richiede la password di amministratore")
                }
            }
            Text(task.explanation).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack(alignment: .bottom) {
                if let result = performance.results[task.id] {
                    resultLabel(result)
                }
                Spacer()
                if performance.running.contains(task.id) {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Esegui") {
                        if task.warning != nil { pendingTask = task } else { Task { await performance.run(task) } }
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }

    /// The outcome of a task: what it did, why it was skipped, or what went wrong.
    private func resultLabel(_ result: PerformanceModel.MaintenanceResult) -> some View {
        let (icon, color, text): (String, Color, String) = switch result {
        case .done(let summary, let date):
            ("checkmark.circle.fill", .green, "\(summary)\nFatto alle \(date.formatted(date: .omitted, time: .shortened))")
        case .skipped(let why): ("minus.circle.fill", .secondary, why)
        case .failed(let why): ("exclamationmark.triangle.fill", .orange, "Non riuscito: \(why)")
        }
        return Label {
            Text(text).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        } icon: {
            Image(systemName: icon).foregroundStyle(color)
        }
        .help(text)
    }

    private func launchRow(_ item: LaunchItem) -> some View {
        HStack(spacing: 10) {
            if let app = item.ownerApp, FileManager.default.fileExists(atPath: app.path) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 24, height: 24)
            } else {
                Image(systemName: "gearshape").frame(width: 24, height: 24).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.label).lineLimit(1)
                    if item.isBroken {
                        Text("rotto").font(.caption2.bold()).padding(.horizontal, 5)
                            .background(.red.opacity(0.2), in: Capsule())
                            .help("Il programma che dovrebbe avviare non esiste più")
                    }
                }
                Text("\(item.domain.rawValue) · \(item.program ?? "—")").font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if item.domain != .systemDaemon || !item.isDisabled {
                Toggle("", isOn: Binding(get: { !item.isDisabled }, set: { _ in Task { await performance.toggle(item) } }))
                    .toggleStyle(.switch).labelsHidden()
                    .help(item.stopNeedsAdmin ? "Fermarlo richiede la password" : "Attiva o disattiva")
            }
            Button(role: .destructive) { pendingRemoval = item } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help(item.needsAdmin ? "Rimuovi (richiede la password)" : "Sposta nel Cestino")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
