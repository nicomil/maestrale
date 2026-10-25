import MacCleanerCore
import MacCleanerModules
import Observation
import SwiftUI

@MainActor
@Observable
final class ProtectionModel {
    var status: ProtectionStatus?
    var findings: [MalwareFinding] = []
    var isScanning = false
    var hasScanned = false
    var message: String?
    /// Findings the user marked as trusted, remembered between launches.
    var ignored: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "ignoredFindings") ?? [])

    var visibleFindings: [MalwareFinding] { findings.filter { !ignored.contains($0.id) } }

    func scan() async {
        isScanning = true
        let result = await Task.detached { (MalwareScanner().protectionStatus(), MalwareScanner().scan()) }.value
        status = result.0
        findings = result.1
        isScanning = false
        hasScanned = true
    }

    func ignore(_ finding: MalwareFinding) {
        ignored.insert(finding.id)
        UserDefaults.standard.set(Array(ignored), forKey: "ignoredFindings")
    }

    func resetIgnored() {
        ignored = []
        UserDefaults.standard.removeObject(forKey: "ignoredFindings")
    }

    /// Stops the launch item (if any), then removes the file: to the Trash
    /// when it is the user's, with the password when it is a system file.
    func remove(_ finding: MalwareFinding) async {
        let target = finding.launchItem?.plist ?? finding.path
        if let item = finding.launchItem, item.domain == .userAgent {
            _ = await Task.detached { LaunchItemsScanner().setUserAgent(item, enabled: false) }.value
        }
        let userRoots = AllowedRoots.appSupport() + AllowedRoots.userFiles()
        let remover = SafeRemover(allowedRoots: userRoots, mode: .trash)
        if remover.validate(target) == nil {
            let outcomes = await Task.detached { remover.remove([target]) }.value
            message = AppModel.summary(outcomes, mode: .trash)
        } else {
            do {
                try await Task.detached {
                    let runner = AdminRunner()
                    if let item = finding.launchItem, item.domain != .userAgent {
                        try? runner.run(.bootoutDaemon(label: item.label))
                    }
                    try runner.run(.remove([target]))
                }.value
                message = "\(finding.title) rimosso"
            } catch AdminError.cancelled {
                message = nil
            } catch {
                message = "\(finding.title): non rimosso (\(error))"
            }
        }
        await scan()
    }
}

struct ProtectionView: View {
    @Environment(AppModel.self) private var model
    @State private var pendingRemoval: MalwareFinding?
    private var protection: ProtectionModel { model.protection }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if protection.hasScanned {
                    Text(protection.visibleFindings.isEmpty ? "Nessuna minaccia evidente"
                         : "\(protection.visibleFindings.count) elementi da controllare").font(.title2.bold())
                }
                Spacer()
                if protection.isScanning { ProgressView().controlSize(.small) }
                Button(protection.hasScanned ? "Controlla di nuovo" : "Controlla") { Task { await protection.scan() } }
                    .disabled(protection.isScanning)
            }
            .padding()
            Divider()
            if let status = protection.status {
                statusCards(status).padding()
            }
            if !protection.hasScanned {
                ContentUnavailableView("Protezione", systemImage: "shield.lefthalf.filled",
                                       description: Text("Controlla firme, notarizzazione, avvio automatico ed estensioni dei browser."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if protection.visibleFindings.isEmpty {
                ContentUnavailableView("Tutto a posto", systemImage: "checkmark.shield",
                                       description: Text("Nessun elemento sospetto tra avvio automatico, app ed estensioni."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(protection.visibleFindings) { finding in row(finding) }
            }
            if protection.hasScanned {
                Divider()
                HStack {
                    if let message = protection.message { Text(message).foregroundStyle(.secondary) }
                    Spacer()
                    if !protection.ignored.isEmpty {
                        Button("Mostra \(protection.ignored.count) ignorati") { protection.resetIgnored() }
                    }
                    Text("Controlli euristici: un avviso non è una prova di malware.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .padding()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("Protezione")
        .confirmationDialog("Rimuovere \(pendingRemoval?.title ?? "")?",
                            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
                            presenting: pendingRemoval) { finding in
            Button("Rimuovi", role: .destructive) { Task { await protection.remove(finding) } }
        } message: { finding in
            Text(finding.launchItem != nil
                 ? "Verrà fermato e rimosso l'elemento di avvio. Il programma resta dov'è."
                 : "Verrà spostato nel Cestino (o eliminato con la password se è un file di sistema).")
        }
    }

    private func statusCards(_ status: ProtectionStatus) -> some View {
        HStack(spacing: 12) {
            card("Gatekeeper", status.gatekeeperEnabled, "Blocca le app non verificate")
            card("Protezione integrità (SIP)", status.sipEnabled, "Protegge i file di sistema")
            card("Firewall", status.firewallEnabled, "Filtra le connessioni in entrata")
            VStack(alignment: .leading, spacing: 4) {
                Label("XProtect", systemImage: "shield.checkered").font(.headline)
                Text(status.xprotectVersion.map { "Definizioni \($0)" } ?? "Sconosciuto").foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func card(_ title: String, _ enabled: Bool?, _ help: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: enabled == false ? "xmark.shield.fill" : "checkmark.shield.fill")
                .font(.headline)
                .foregroundStyle(enabled == false ? .red : enabled == true ? .green : .secondary)
            Text(enabled == nil ? "Sconosciuto" : enabled! ? "Attivo" : "Disattivato").foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .help(help)
    }

    private func row(_ finding: MalwareFinding) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: finding.severity == .danger ? "exclamationmark.octagon.fill"
                  : finding.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(finding.severity == .danger ? .red : finding.severity == .warning ? .orange : .blue)
                .font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text(finding.title).bold()
                Text(finding.reasons.joined(separator: " · ")).font(.callout)
                Text(finding.path.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button { NSWorkspace.shared.activateFileViewerSelecting([finding.path]) } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless).help("Mostra nel Finder")
            Button("Ignora") { protection.ignore(finding) }
            Button("Rimuovi") { pendingRemoval = finding }
        }
        .padding(.vertical, 4)
    }
}
