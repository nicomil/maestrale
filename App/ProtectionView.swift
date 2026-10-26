import MacCleanerCore
import MacCleanerModules
import Observation
import SwiftUI

@MainActor
@Observable
final class ProtectionModel {
    var status: ProtectionStatus?
    var findings: [Finding] = []
    var isScanning = false
    var hasScanned = false
    var message: String?
    /// Informational findings are hidden unless asked for.
    var showInfo = false
    /// Findings the user marked as trusted, remembered between launches.
    var ignored: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "ignoredFindings") ?? [])
    /// Developers (Team IDs) the user trusts: their warnings are not shown.
    var trustedTeams: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "trustedTeams") ?? [])

    var visibleFindings: [Finding] {
        findings.filter { !ignored.contains($0.id) && (showInfo || $0.severity > .info) }
    }

    var newFindings: [Finding] { visibleFindings.filter(\.isNew) }

    /// Findings grouped by category, in the order of `FindingCategory`.
    var groups: [(category: FindingCategory, findings: [Finding])] {
        FindingCategory.allCases.compactMap { category in
            let items = visibleFindings.filter { $0.category == category }
            return items.isEmpty ? nil : (category, items)
        }
    }

    /// The root-only facts of the last deep scan, reused by the next scans.
    var systemEvidence: SystemEvidence?
    var deepScanDate: Date?

    func scan() async {
        isScanning = true
        let trusted = trustedTeams
        let evidence = systemEvidence
        let result = await Task.detached {
            let scanner = MalwareScanner()
            return (scanner.protectionStatus(), ProtectionBaseline().apply(scanner.scan(trustedTeams: trusted, systemEvidence: evidence)))
        }.value
        status = result.0
        findings = result.1
        isScanning = false
        hasScanned = true
    }

    /// One password prompt, then the usual scan with the root-only facts added.
    func deepScan() async {
        do {
            systemEvidence = try await Task.detached { try MalwareScanner().collectSystemEvidence() }.value
            deepScanDate = Date()
        } catch AdminError.cancelled {
            return
        } catch {
            message = "Controllo approfondito non riuscito (\(error))"
            return
        }
        await scan()
    }

    func ignore(_ finding: Finding) {
        ignored.insert(finding.id)
        UserDefaults.standard.set(Array(ignored), forKey: "ignoredFindings")
    }

    func resetIgnored() {
        ignored = []
        UserDefaults.standard.removeObject(forKey: "ignoredFindings")
    }

    func trust(team: String) {
        trustedTeams.insert(team)
        UserDefaults.standard.set(Array(trustedTeams), forKey: "trustedTeams")
        findings.removeAll { $0.team == team && $0.severity < .danger }
    }

    /// Asks macOS for new XProtect definitions (password prompt), then rescans.
    func updateXProtect() async {
        do {
            try await Task.detached { try AdminRunner().run(.updateXProtect) }.value
            message = "Richiesto l'aggiornamento di XProtect"
        } catch AdminError.cancelled {
            message = nil
        } catch {
            message = "XProtect non aggiornato (\(error))"
        }
        await scan()
    }

    var quarantineRecords: [QuarantineRecord] = Quarantine().records()

    /// User roots the app may quarantine from without the password. Hidden
    /// folders of the home are included: that is where droppers hide.
    static func userRoots() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let hidden = ((try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? [])
            .filter { $0.hasPrefix(".") && $0 != ".Trash" }.map { home.appendingPathComponent($0) }
        return AllowedRoots.user() + AllowedRoots.userFiles() + AllowedRoots.appSupport() + hidden
            + [home.appendingPathComponent("Library/LaunchAgents")]
    }

    /// The safe removal sequence: stop the process, stop and remove the launch
    /// item, then put the file aside where it cannot run. Stops at the first
    /// step that fails, so nothing is hidden while it keeps running.
    func quarantine(_ finding: Finding) async {
        if case .terminateProcess(let pid) = finding.action { _ = kill(pid, SIGTERM) }
        if let item = finding.launchItem {
            do {
                try await Task.detached { try LaunchItemsScanner().remove(item) }.value
            } catch AdminError.cancelled {
                return
            } catch {
                message = "\(finding.title): elemento di avvio non fermato (\(error)), file lasciato al suo posto"
                await scan()
                return
            }
        }
        if let path = finding.path, !KnownLocations.isSystem(path.path) {
            let title = finding.title, reasons = finding.reasons
            let roots = Self.userRoots()
            do {
                if SafeRemover(allowedRoots: roots, mode: .dryRun, log: nil).validate(path) == nil {
                    _ = try await Task.detached { try Quarantine().quarantine(path, title: title, reasons: reasons, allowedRoots: roots) }.value
                } else {
                    let id = UUID()
                    let report = try await Task.detached { try AdminRunner().runCapturing(.quarantine([path], id: id)) }.value
                    let stored = AdminRunner.parseHelperReport(report).done.first ?? path.lastPathComponent
                    try Quarantine().add(QuarantineRecord(id: id, title: title, originalPath: path.path, reasons: reasons, date: Date(),
                                                          storedFolder: Quarantine.systemFolder + "/" + id.uuidString,
                                                          storedName: URL(fileURLWithPath: stored).lastPathComponent, isSystem: true))
                }
                message = "\(finding.title) in quarantena"
            } catch AdminError.cancelled {
                message = nil
            } catch {
                message = "\(finding.title): non messo in quarantena (\(error))"
            }
        } else {
            message = "\(finding.title) fermato"
        }
        quarantineRecords = Quarantine().records()
        await scan()
    }

    func restore(_ record: QuarantineRecord) async {
        do {
            if record.isSystem {
                let destination = URL(fileURLWithPath: record.originalPath).deletingLastPathComponent()
                try await Task.detached { try AdminRunner().run(.restoreQuarantined(id: record.id, name: record.storedName, into: destination)) }.value
                try Quarantine().forget(record)
            } else {
                try await Task.detached { try Quarantine().restore(record) }.value
            }
            message = "\(record.title) ripristinato"
        } catch AdminError.cancelled {
        } catch {
            message = "\(record.title): non ripristinato (\(error))"
        }
        quarantineRecords = Quarantine().records()
    }

    func deleteRecord(_ record: QuarantineRecord) async {
        do {
            if record.isSystem {
                try await Task.detached { try AdminRunner().run(.deleteQuarantined(id: record.id)) }.value
                try Quarantine().forget(record)
            } else {
                try await Task.detached { try Quarantine().delete(record) }.value
            }
            message = "\(record.title) eliminato"
        } catch AdminError.cancelled {
        } catch {
            message = "\(record.title): non eliminato (\(error))"
        }
        quarantineRecords = Quarantine().records()
    }

    /// Writes the Markdown report where the user chooses.
    func exportReport() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Rapporto Protezione \(Date().formatted(.iso8601.year().month().day())).md"
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = ProtectionReport.markdown(status: status, findings: findings, ignored: ignored)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            message = "Rapporto salvato"
        } catch {
            message = "Rapporto non salvato (\(error.localizedDescription))"
        }
    }

    /// New findings of the worst kind, for Smart Care and the scheduler.
    var newDangers: [Finding] { visibleFindings.filter { $0.isNew && $0.severity == .danger } }

    /// Sends SIGTERM to one of the user's processes, then rescans.
    func terminate(pid: Int32) async {
        if kill(pid, SIGTERM) == 0 {
            message = "Processo \(pid) terminato"
        } else {
            message = "Processo \(pid): non terminato (\(String(cString: strerror(errno))))"
        }
        try? await Task.sleep(for: .milliseconds(500))
        await scan()
    }

    /// Stops the launch item (if any) and moves its plist to the Trash;
    /// otherwise moves the file to the Trash (with the password when it is a
    /// system file). A launch item that does not stop is left in place.
    func remove(_ finding: Finding) async {
        if let item = finding.launchItem {
            do {
                try await Task.detached { try LaunchItemsScanner().remove(item) }.value
                message = "\(finding.title) rimosso"
            } catch AdminError.cancelled {
                message = nil
            } catch {
                message = "\(finding.title): non rimosso (\(error))"
            }
            await scan()
            return
        }
        guard let target = finding.path else { return }
        let userRoots = AllowedRoots.appSupport() + AllowedRoots.userFiles()
        let remover = SafeRemover(allowedRoots: userRoots, mode: .trash)
        if remover.validate(target) == nil {
            let outcomes = await Task.detached { remover.remove([target]) }.value
            message = AppModel.summary(outcomes, mode: .trash)
        } else {
            do {
                try await Task.detached { try AdminRunner().run(.moveToTrash([target])) }.value
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
    @State private var pendingRemoval: Finding?
    @State private var pendingQuarantine: Finding?
    @State private var showQuarantine = false
    private var protection: ProtectionModel { model.protection }

    var body: some View {
        @Bindable var protection = protection
        VStack(spacing: 0) {
            HStack {
                if protection.hasScanned {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(protection.visibleFindings.isEmpty ? "Nessuna minaccia evidente"
                             : "\(protection.visibleFindings.count) elementi da controllare").font(.title2.bold())
                        if !protection.newFindings.isEmpty {
                            Text("\(protection.newFindings.count) nuovi dall'ultimo controllo").foregroundStyle(.orange)
                        }
                    }
                }
                Spacer()
                if protection.isScanning { ProgressView().controlSize(.small) }
                Button(protection.hasScanned ? "Controlla di nuovo" : "Controlla") { Task { await protection.scan() } }
                    .disabled(protection.isScanning)
                Button("Controllo approfondito…") { Task { await protection.deepScan() } }
                    .disabled(protection.isScanning)
                    .help("Chiede la password e legge anche i permessi di sistema, i cron di root, i profili del dispositivo e le connessioni di tutti gli utenti. Solo lettura.")
                Menu {
                    Button("Esporta rapporto…") { protection.exportReport() }.disabled(!protection.hasScanned)
                    Button("Quarantena (\(protection.quarantineRecords.count))…") { showQuarantine = true }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
            }
            .padding()
            Divider()
            if let status = protection.status {
                statusCards(status).padding()
            }
            if !protection.hasScanned {
                ContentUnavailableView("Protezione", systemImage: "shield.lefthalf.filled",
                                       description: Text("Avvio automatico, login item, firme, estensioni e impostazioni dei browser, cron e shell, profili, certificati, rete, permessi di privacy e difese di macOS."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if protection.visibleFindings.isEmpty {
                ContentUnavailableView("Tutto a posto", systemImage: "checkmark.shield",
                                       description: Text(protection.showInfo ? "Nessun elemento sospetto." : "Nessun avviso. Le informazioni sono nascoste: attivale in basso per vedere tutto."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(protection.groups, id: \.category) { group in
                        Section(group.category.title) {
                            ForEach(group.findings) { finding in
                                FindingRow(finding: finding, onRemove: { pendingRemoval = $0 }, onQuarantine: { pendingQuarantine = $0 })
                            }
                        }
                    }
                }
            }
            if protection.hasScanned {
                Divider()
                HStack {
                    Toggle("Mostra anche le informazioni", isOn: $protection.showInfo).toggleStyle(.checkbox)
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
                 : "Verrà spostato nel Cestino (con la password se è un file di sistema).")
        }
        .confirmationDialog("Mettere in quarantena \(pendingQuarantine?.title ?? "")?",
                            isPresented: Binding(get: { pendingQuarantine != nil }, set: { if !$0 { pendingQuarantine = nil } }),
                            presenting: pendingQuarantine) { finding in
            Button("Metti in quarantena", role: .destructive) { Task { await protection.quarantine(finding) } }
        } message: { finding in
            Text((finding.launchItem != nil ? "L'elemento di avvio verrà fermato e rimosso. " : "")
                 + "Il file finirà nella quarantena di MacCleaner, senza permessi: non potrà più partire. Potrai ripristinarlo o eliminarlo"
                 + (finding.path.map { KnownLocations.isSystem($0.path) ? "" : ", con la password se è un file di sistema." } ?? "."))
        }
        .sheet(isPresented: $showQuarantine) { QuarantineView() }
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
}

/// One finding: severity, reasons, path, evidence on request, and the actions.
struct FindingRow: View {
    @Environment(AppModel.self) private var model
    let finding: Finding
    let onRemove: (Finding) -> Void
    let onQuarantine: (Finding) -> Void
    @State private var showEvidence = false

    private var protection: ProtectionModel { model.protection }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: finding.severity == .danger ? "exclamationmark.octagon.fill"
                  : finding.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(finding.severity == .danger ? .red : finding.severity == .warning ? .orange : .blue)
                .font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(finding.title).bold()
                    if finding.isNew {
                        Text("Nuovo").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.orange.opacity(0.2), in: Capsule()).foregroundStyle(.orange)
                    }
                }
                Text(finding.reasons.joined(separator: " · ")).font(.callout)
                if let path = finding.path {
                    Text(path.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                if !finding.evidence.isEmpty {
                    DisclosureGroup("Dettagli", isExpanded: $showEvidence) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(finding.evidence, id: \.self) { line in
                                Text(line).font(.caption.monospaced()).textSelection(.enabled)
                            }
                        }
                        .padding(.top, 2)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let path = finding.path {
                Button { NSWorkspace.shared.activateFileViewerSelecting([path]) } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.borderless).help("Mostra nel Finder")
            }
            if case .openSettings(let link) = finding.action, !link.isEmpty {
                Button("Apri Impostazioni") { if let url = URL(string: link) { NSWorkspace.shared.open(url) } }
            }
            if finding.action == .updateXProtect {
                Button("Aggiorna definizioni") { Task { await protection.updateXProtect() } }
            }
            if case .terminateProcess(let pid) = finding.action {
                Button("Termina") { Task { await protection.terminate(pid: pid) } }
            }
            Menu {
                Button("Ignora questo elemento") { protection.ignore(finding) }
                if let team = finding.team {
                    Button("Fidati dello sviluppatore \(team)") { protection.trust(team: team) }
                }
            } label: { Text("Ignora") }
            .menuStyle(.borderlessButton).fixedSize()
            if finding.action == .removeLaunchItem || finding.action == .trash || finding.action == .quarantine,
               finding.path != nil || finding.launchItem != nil {
                Button("Rimuovi") { onRemove(finding) }
            }
            if canQuarantine {
                Button("Quarantena") { onQuarantine(finding) }
                    .tint(finding.severity == .danger ? .red : nil)
            }
        }
        .padding(.vertical, 4)
    }

    /// Files the app can put aside: not Apple's, not the system's, not a
    /// setting. Processes can be stopped and their file quarantined too.
    private var canQuarantine: Bool {
        guard finding.severity >= .warning, let path = finding.path, !KnownLocations.isSystem(path.path),
              finding.category != .defense, finding.category != .configuration, finding.category != .network else { return false }
        return finding.launchItem != nil || finding.action == .trash || finding.action == .quarantine
            || { if case .terminateProcess = finding.action { return true } else { return false } }()
    }
}

/// What was put aside: restore it or delete it for good.
struct QuarantineView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    private var protection: ProtectionModel { model.protection }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Quarantena").font(.title2.bold())
                Spacer()
                Button("Chiudi") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding()
            Divider()
            if protection.quarantineRecords.isEmpty {
                ContentUnavailableView("Niente in quarantena", systemImage: "archivebox",
                                       description: Text("Gli elementi messi in quarantena da Protezione compaiono qui."))
                    .frame(width: 560, height: 300)
            } else {
                List(protection.quarantineRecords) { record in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.title).bold()
                            Text(record.reasons.joined(separator: " · ")).font(.callout)
                            Text(record.originalPath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            Text("\(record.date.formatted(date: .numeric, time: .shortened))\(record.isSystem ? " · elemento di sistema" : "")")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Button("Ripristina") { Task { await protection.restore(record) } }
                        Button("Elimina", role: .destructive) { Task { await protection.deleteRecord(record) } }
                    }
                    .padding(.vertical, 4)
                }
                .frame(width: 620, height: 360)
            }
            if let message = protection.message {
                Divider()
                Text(message).foregroundStyle(.secondary).padding()
            }
        }
    }
}
