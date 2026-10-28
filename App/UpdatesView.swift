import MaestraleModules
import SwiftUI

struct UpdatesView: View {
    @Environment(AppModel.self) private var model
    private var updates: UpdatesModel { model.updates }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if let lastCheck = updates.lastCheck {
                    Text(updates.updates.isEmpty ? "Tutto aggiornato"
                         : "\(updates.updates.count) aggiornamenti disponibili").font(.title2.bold())
                    Text("su \(updates.checkedApps) app · controllo delle \(lastCheck.formatted(date: .omitted, time: .shortened))")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if updates.isChecking { ProgressView().controlSize(.small) }
                Button(updates.lastCheck == nil ? "Controlla" : "Controlla di nuovo") {
                    Task { await updates.check() }
                }
                .disabled(updates.isChecking)
            }
            .padding()
            Divider()
            if updates.lastCheck == nil && !updates.isChecking {
                ContentUnavailableView("Aggiornamenti", systemImage: "arrow.down.app",
                                       description: Text("Controlla le app con Sparkle, App Store e Homebrew."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if updates.updates.isEmpty {
                ContentUnavailableView(updates.isChecking ? "Controllo in corso…" : "Nessun aggiornamento",
                                       systemImage: updates.isChecking ? "hourglass" : "checkmark.seal")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(updates.updates) { update in row(update) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("Aggiornamenti")
        // An app updated through its own updater or the App Store must leave the list by itself.
        .task { await updates.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await updates.refresh() }
        }
    }

    private func row(_ update: AppUpdate) -> some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: update.app.url.path)).resizable().frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(update.app.name).bold()
                Text(update.versionLine).font(.callout).foregroundStyle(.secondary)
                if let message = updates.messages[update.id] {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(update.source.rawValue).font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                .background(.secondary.opacity(0.15), in: Capsule())
            if update.source == .sparkle, let notes = update.infoURL {
                Button("Novità") { NSWorkspace.shared.open(notes) }
            }
            if updates.busy.contains(update.id) {
                ProgressView().controlSize(.small)
            } else {
                Button(update.source == .appStore ? "Apri App Store" : "Aggiorna") {
                    Task { await updates.update(update) }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 4)
    }
}
