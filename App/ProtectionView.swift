import MaestraleCore
import MaestraleModules
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

    /// How much of the list the user wants to see.
    enum SeverityFilter: String, CaseIterable, Identifiable {
        case warnings = "Pericoli e avvisi"
        case dangers = "Solo pericoli"
        case everything = "Tutto"
        var id: String { rawValue }

        var minimum: Finding.Severity {
            switch self {
            case .warnings: .warning
            case .dangers: .danger
            case .everything: .info
            }
        }
    }

    /// Which findings the screen shows: one category or all of them.
    enum CategoryChoice: Hashable {
        case all
        case one(FindingCategory)
    }

    var severityFilter: SeverityFilter = .warnings
    var onlyNew = false
    var search = ""
    var category: CategoryChoice = .all
    /// Informational findings are hidden unless asked for.
    var showInfo: Bool { severityFilter == .everything }
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

    /// The visible findings that pass the severity, "new" and text filters,
    /// in every category: the category column counts these.
    var filteredFindings: [Finding] {
        Self.filter(visibleFindings, minimum: severityFilter.minimum, onlyNew: onlyNew, search: search)
    }

    /// What the results list shows: the filtered findings of the chosen category.
    var shownFindings: [Finding] {
        guard case .one(let chosen) = category else { return filteredFindings }
        return filteredFindings.filter { $0.category == chosen }
    }

    /// The categories with something to show, with their count and worst severity.
    var categoryRows: [(category: FindingCategory, count: Int, worst: Finding.Severity)] {
        FindingCategory.allCases.compactMap { category in
            let items = filteredFindings.filter { $0.category == category }
            guard let worst = items.map(\.severity).max() else { return nil }
            return (category, items.count, worst)
        }
    }

    /// Applies the filters and sorts: dangers first, then what is new, then by title.
    nonisolated static func filter(_ findings: [Finding], minimum: Finding.Severity, onlyNew: Bool,
                                   search: String) -> [Finding] {
        let text = search.trimmingCharacters(in: .whitespaces)
        return findings
            .filter { finding in
                guard finding.severity >= minimum, !onlyNew || finding.isNew else { return false }
                guard !text.isEmpty else { return true }
                return finding.title.localizedCaseInsensitiveContains(text)
                    || finding.reasons.contains { $0.localizedCaseInsensitiveContains(text) }
                    || finding.path?.path.localizedCaseInsensitiveContains(text) == true
            }
            .sorted { a, b in
                if a.severity != b.severity { return a.severity > b.severity }
                if a.isNew != b.isNew { return a.isNew }
                return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
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
        let center = ProgressCenter.shared
        center.begin("Rimozione: \(finding.title)", detail: "Sposto nel Cestino e ricontrollo…")
        defer { center.end() }
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
            header
            Divider()
            if let status = protection.status {
                statusCards(status).padding([.horizontal, .top])
            }
            if !protection.hasScanned {
                ContentUnavailableView("Protezione", systemImage: "shield.lefthalf.filled",
                                       description: Text("Avvio automatico, login item, firme, estensioni e impostazioni dei browser, cron e shell, profili, certificati, rete, permessi di privacy e difese di macOS."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                filterBar.padding()
                Divider()
                // Fixed category column, results take the rest: no minimum
                // widths that could push the content beyond the window.
                HStack(spacing: 0) {
                    categoryColumn.frame(width: 220)
                    Divider()
                    results.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
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
                 : "Verrà spostato nel Cestino (con la password se è un file di sistema).")
        }
        .confirmationDialog("Mettere in quarantena \(pendingQuarantine?.title ?? "")?",
                            isPresented: Binding(get: { pendingQuarantine != nil }, set: { if !$0 { pendingQuarantine = nil } }),
                            presenting: pendingQuarantine) { finding in
            Button("Metti in quarantena", role: .destructive) { Task { await protection.quarantine(finding) } }
        } message: { finding in
            Text((finding.launchItem != nil ? "L'elemento di avvio verrà fermato e rimosso. " : "")
                 + "Il file finirà nella quarantena di Maestrale, senza permessi: non potrà più partire. Potrai ripristinarlo o eliminarlo"
                 + (finding.path.map { KnownLocations.isSystem($0.path) ? "" : ", con la password se è un file di sistema." } ?? "."))
        }
        .sheet(isPresented: $showQuarantine) { QuarantineView() }
    }

    /// Title with the counts by severity, and the scan buttons.
    private var header: some View {
        let visible = protection.visibleFindings
        let dangers = visible.filter { $0.severity == .danger }.count
        let warnings = visible.filter { $0.severity == .warning }.count
        let infos = protection.findings.filter { !protection.ignored.contains($0.id) && $0.severity == .info }.count
        return HStack {
            if protection.hasScanned {
                VStack(alignment: .leading, spacing: 4) {
                    Text(dangers + warnings == 0 ? "Nessuna minaccia evidente"
                         : "\(dangers + warnings) elementi da controllare").font(.title2.bold())
                    HStack(spacing: 10) {
                        severityCount(dangers, "pericoli", .red)
                        severityCount(warnings, "avvisi", .orange)
                        severityCount(infos, "informazioni", .blue)
                        if !protection.newFindings.isEmpty {
                            Text("\(protection.newFindings.count) nuovi dall'ultimo controllo").foregroundStyle(.orange)
                        }
                    }
                    .font(.callout)
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
    }

    private func severityCount(_ count: Int, _ label: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(count > 0 ? color : Color.secondary.opacity(0.4)).frame(width: 8, height: 8)
            Text("\(count) \(label)").foregroundStyle(count > 0 ? .primary : .secondary)
        }
    }

    /// Severity, "only new" and text: what narrows the list.
    private var filterBar: some View {
        @Bindable var protection = protection
        return HStack(spacing: 12) {
            Picker("Gravità", selection: $protection.severityFilter) {
                ForEach(ProtectionModel.SeverityFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Toggle("Solo nuovi", isOn: $protection.onlyNew).toggleStyle(.checkbox)
                .disabled(protection.newFindings.isEmpty && !protection.onlyNew)
            Spacer()
            TextField("Cerca titolo, motivo o percorso", text: $protection.search)
                .textFieldStyle(.roundedBorder).frame(width: 240)
        }
    }

    /// One row per category with something to show, "Tutte" first.
    private var categoryColumn: some View {
        @Bindable var protection = protection
        let rows = protection.categoryRows
        let total = protection.filteredFindings.count
        return List(selection: $protection.category) {
            categoryRow("Tutte le categorie", icon: "shield.lefthalf.filled", count: total,
                        worst: rows.map(\.worst).max())
                .tag(ProtectionModel.CategoryChoice.all)
            ForEach(rows, id: \.category) { row in
                categoryRow(row.category.title, icon: Self.icon(for: row.category), count: row.count, worst: row.worst)
                    .tag(ProtectionModel.CategoryChoice.one(row.category))
            }
        }
        .listStyle(.sidebar)
        .onChange(of: rows.map(\.category)) { _, categories in
            // The chosen category emptied out (filters changed): go back to "all".
            if case .one(let chosen) = protection.category, !categories.contains(chosen) { protection.category = .all }
        }
    }

    private func categoryRow(_ title: String, icon: String, count: Int, worst: Finding.Severity?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 18)
            Text(title).lineLimit(1)
            Spacer()
            Text("\(count)").monospacedDigit().font(.callout).foregroundStyle(.secondary)
            Circle().fill(Self.color(for: worst)).frame(width: 8, height: 8)
        }
    }

    @ViewBuilder private var results: some View {
        let shown = protection.shownFindings
        if shown.isEmpty {
            let nothingAtAll = protection.filteredFindings.isEmpty
            ContentUnavailableView(nothingAtAll && protection.search.isEmpty && !protection.onlyNew ? "Tutto a posto" : "Nessun risultato",
                                   systemImage: nothingAtAll && protection.search.isEmpty && !protection.onlyNew ? "checkmark.shield" : "line.3.horizontal.decrease.circle",
                                   description: Text(nothingAtAll && protection.search.isEmpty && !protection.onlyNew
                                                     ? (protection.showInfo ? "Nessun elemento sospetto." : "Nessun avviso. Scegli \"Tutto\" per vedere anche le informazioni.")
                                                     : "Nessun elemento corrisponde ai filtri scelti."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(shown) { finding in
                FindingRow(finding: finding, showsCategory: protection.category == .all,
                           onRemove: { pendingRemoval = $0 }, onQuarantine: { pendingQuarantine = $0 })
            }
        }
    }

    static func icon(for category: FindingCategory) -> String {
        switch category {
        case .persistence: "power"
        case .application: "app.badge"
        case .browser: "globe"
        case .process: "cpu"
        case .network: "network"
        case .configuration: "gearshape"
        case .defense: "lock.shield"
        case .signature: "doc.text.magnifyingglass"
        }
    }

    static func color(for severity: Finding.Severity?) -> Color {
        switch severity {
        case .danger?: .red
        case .warning?: .orange
        case .info?: .blue
        case nil: Color.secondary.opacity(0.4)
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
}

/// One finding, compact: severity, title, first reason and path. A click
/// opens the other reasons and the evidence. The main action stays on the
/// row; the rest is in a menu.
struct FindingRow: View {
    @Environment(AppModel.self) private var model
    let finding: Finding
    /// Show the category next to the title (when the list mixes categories).
    var showsCategory = false
    let onRemove: (Finding) -> Void
    let onQuarantine: (Finding) -> Void
    @State private var expanded = false

    private var protection: ProtectionModel { model.protection }

    private var hasMore: Bool { finding.reasons.count > 1 || !finding.evidence.isEmpty || finding.team != nil }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: finding.severity == .danger ? "exclamationmark.octagon.fill"
                  : finding.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(ProtectionView.color(for: finding.severity))
                .font(.title3)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(finding.title).bold().lineLimit(1)
                    if finding.isNew {
                        Text("Nuovo").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.orange.opacity(0.2), in: Capsule()).foregroundStyle(.orange)
                    }
                    if showsCategory {
                        Text(finding.category.title).font(.caption2).padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.secondary.opacity(0.15), in: Capsule()).foregroundStyle(.secondary)
                    }
                }
                if expanded {
                    ForEach(finding.reasons, id: \.self) { reason in
                        Text("· " + reason).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                } else if let first = finding.reasons.first {
                    Text(finding.reasons.count > 1 ? "\(first) · +\(finding.reasons.count - 1)" : first)
                        .font(.callout).lineLimit(1)
                }
                if let path = finding.path {
                    Text(path.path).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(expanded ? nil : 1).truncationMode(.middle).textSelection(.enabled)
                }
                if expanded {
                    if let team = finding.team {
                        Text("Team ID \(team)").font(.caption).foregroundStyle(.secondary)
                    }
                    if !finding.evidence.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(finding.evidence, id: \.self) { line in
                                Text(line).font(.caption.monospaced()).textSelection(.enabled)
                            }
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            Spacer(minLength: 8)
            actions
            // Always present, so the buttons line up from row to row.
            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                .font(.caption).foregroundStyle(.tertiary).frame(width: 14)
                .padding(.top, 4)
                .opacity(hasMore ? 1 : 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { if hasMore { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } } }
        .help(hasMore && !expanded ? "Clic per vedere tutti i motivi e i dettagli" : "")
    }

    /// The main action on the row, the rest in the menu.
    private var actions: some View {
        HStack(spacing: 6) {
            if case .openSettings(let link) = finding.action, !link.isEmpty {
                Button("Apri Impostazioni") { if let url = URL(string: link) { NSWorkspace.shared.open(url) } }
            }
            if finding.action == .updateXProtect {
                Button("Aggiorna definizioni") { Task { await protection.updateXProtect() } }
            }
            if case .terminateProcess(let pid) = finding.action {
                Button("Termina") { Task { await protection.terminate(pid: pid) } }
            }
            if canQuarantine {
                Button("Quarantena") { onQuarantine(finding) }
                    .tint(finding.severity == .danger ? .red : nil)
            } else if canRemove {
                Button("Rimuovi") { onRemove(finding) }
            }
            Menu {
                if canQuarantine && canRemove {
                    Button("Rimuovi (senza quarantena)") { onRemove(finding) }
                }
                if let path = finding.path {
                    Button("Mostra nel Finder") { NSWorkspace.shared.activateFileViewerSelecting([path]) }
                    Button("Copia percorso") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(path.path, forType: .string)
                    }
                }
                Divider()
                Button("Ignora questo elemento") { protection.ignore(finding) }
                if let team = finding.team {
                    Button("Fidati dello sviluppatore \(team)") { protection.trust(team: team) }
                }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Altre azioni")
        }
        .controlSize(.small)
    }

    private var canRemove: Bool {
        (finding.action == .removeLaunchItem || finding.action == .trash || finding.action == .quarantine)
            && (finding.path != nil || finding.launchItem != nil)
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
