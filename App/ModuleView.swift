import MacCleanerCore
import SwiftUI

/// What each list-based module does, shown under its title.
let moduleDescriptions: [String: String] = [
    "system-junk": "Cache, log e file temporanei che le app e macOS ricreano da soli.",
    "trash": "Il Cestino e i cestini dei dischi esterni. Svuotarli è definitivo.",
    "mail-attachments": "Copie locali degli allegati degli account IMAP ed Exchange: Mail li riscarica dal server quando apri il messaggio. Non usarlo con account POP. Mail deve essere chiusa.",
    "installers": "Immagini disco e pacchetti in Download, Scrivania e Documenti, soprattutto di app già installate.",
    "large-old-files": "I file più grandi delle tue cartelle e i download che non apri da tempo. Niente è preselezionato.",
    "duplicates": "File identici byte per byte. In ogni gruppo una copia resta sempre; sono preselezionate solo le copie in Download.",
    "similar-images": "Foto quasi uguali (copie ridimensionate, scatti ripetuti). La migliore resta.",
    "orphan-leftovers": "Dati lasciati da app che non sono più installate. Controlla prima di rimuovere.",
]

/// Scan → review → clean screen shared by every list-based module.
struct ModuleView: View {
    @Environment(AppModel.self) private var model
    let state: AppModel.ModuleState
    @State private var confirmClean = false
    @State private var filter = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let report = state.report {
                if !report.unreadablePaths.isEmpty { FullDiskAccessBanner() }
                if let outcome = state.lastClean { CleanBanner(outcome: outcome) }
                if report.categories.isEmpty {
                    ContentUnavailableView("Tutto pulito", systemImage: "checkmark.seal",
                                           description: Text("Nessun elemento trovato."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ResultsList(report: report, filter: filter)
                }
                Divider()
                footer
            } else if state.isScanning {
                ScanningPlaceholder(started: state.scanStarted) { model.cancelScan(state.id) }
            } else {
                ContentUnavailableView {
                    Label(state.module.title, systemImage: state.icon)
                } description: {
                    Text(moduleDescriptions[state.id] ?? "")
                } actions: {
                    Button("Scansiona") { model.startScan(state.id) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut("r")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle(state.module.title)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if let report = state.report {
                    Text(report.totalSize > 0 ? "Trovati \(formatBytes(report.totalSize))" : "Niente da pulire")
                        .font(.title2.bold())
                    Text("\(report.allItems.count) elementi in \(report.categories.count) gruppi")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text(moduleDescriptions[state.id] ?? "").foregroundStyle(.secondary).lineLimit(2)
                }
            }
            if let error = state.error { Text(error).foregroundStyle(.red) }
            Spacer()
            if state.report != nil {
                TextField("Filtra", text: $filter).textFieldStyle(.roundedBorder).frame(width: 160)
            }
            if state.isScanning && state.report != nil {
                ProgressView().controlSize(.small)
                Button("Annulla") { model.cancelScan(state.id) }
            } else if state.report != nil {
                Button("Scansiona di nuovo") { model.startScan(state.id) }.keyboardShortcut("r")
            }
        }
        .padding()
    }

    private var footer: some View {
        @Bindable var model = model
        let blocked = model.fullySelectedCopyGroups(in: state.id)
        let selected = model.selectedItems(in: state.id)
        let needsPassword = selected.contains(where: \.needsHelper)
        let size = model.selectedSize(in: state.id)
        // The filter only hides rows: hidden items that are selected are cleaned too.
        let hidden = filter.isEmpty ? 0 : selected.filter { !$0.url.path.localizedCaseInsensitiveContains(filter) }.count
        return HStack {
            RemovalModePicker(mode: $model.removalMode)
            if !blocked.isEmpty {
                Label("Lascia almeno una copia in \(blocked.count) gruppi", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else if hidden > 0 {
                Label("\(hidden) selezionati nascosti dal filtro", systemImage: "eye.slash").foregroundStyle(.orange)
            } else if needsPassword {
                Label("Alcuni elementi chiedono la password", systemImage: "lock.fill").foregroundStyle(.secondary)
            }
            Spacer()
            Button("Pulisci \(formatBytes(size))") { confirmClean = true }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(selected.isEmpty || model.isCleaning || !blocked.isEmpty)
                .confirmationDialog("Pulire \(selected.count) elementi (\(formatBytes(size)))?",
                                    isPresented: $confirmClean) {
                    Button(model.removalMode == .delete ? "Elimina definitivamente" : "Pulisci",
                           role: model.removalMode == .delete ? .destructive : nil) {
                        Task { await model.clean(state.id) }
                    }
                } message: {
                    Text((hidden > 0 ? "Attenzione: \(hidden) elementi selezionati sono nascosti dal filtro e verranno puliti anche loro. " : "")
                         + model.removalMode.confirmation
                         + (needsPassword ? " Per gli elementi di sistema macOS chiederà la password di amministratore." : ""))
                }
        }
        .padding()
    }
}

/// Shown while a scan runs, with elapsed time and a cancel button.
struct ScanningPlaceholder: View {
    let started: Date?
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let seconds = Int(context.date.timeIntervalSince(started ?? context.date))
                Text(seconds < 5 ? "Scansione in corso…" : "Scansione in corso… \(seconds) s")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            Button("Annulla", action: onCancel)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Confirmation after a clean, with a shortcut to the Trash to undo.
struct CleanBanner: View {
    let outcome: AppModel.CleanOutcome

    var body: some View {
        HStack {
            Image(systemName: outcome.mode == .dryRun ? "eye" : "checkmark.circle.fill")
                .foregroundStyle(outcome.mode == .dryRun ? Color.secondary : Color.green)
            Text(outcome.summary)
            Spacer()
            if outcome.mode == .trash {
                Button("Apri Cestino") {
                    NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash"))
                }
                .help("I file spostati nel Cestino si possono ripristinare da lì")
            }
        }
        .font(.callout)
        .padding(8)
        .background((outcome.mode == .dryRun ? Color.secondary : Color.green).opacity(0.12))
    }
}

struct RemovalModePicker: View {
    @Binding var mode: RemovalMode

    var body: some View {
        Picker("Modalità", selection: $mode) {
            Text("Sposta nel Cestino").tag(RemovalMode.trash)
            Text("Prova (non rimuove nulla)").tag(RemovalMode.dryRun)
            Text("Elimina definitivamente").tag(RemovalMode.delete)
        }
        .fixedSize()
    }
}

extension RemovalMode {
    var confirmation: String {
        switch self {
        case .trash: "Potrai recuperare i file dal Cestino."
        case .dryRun: "Nessun file verrà toccato: vedrai solo quanto spazio si libererebbe."
        case .delete: "I file verranno eliminati e non si potranno recuperare."
        }
    }
}

struct FullDiskAccessBanner: View {
    var text = "Alcune cartelle non sono leggibili. Concedi l'Accesso completo al disco per risultati completi."

    var body: some View {
        HStack {
            Image(systemName: "lock.shield")
            Text(text)
            Spacer()
            Button("Apri Impostazioni") { openFullDiskAccessSettings() }
        }
        .font(.callout)
        .padding(8)
        .background(.yellow.opacity(0.15))
    }
}

func openFullDiskAccessSettings() {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
}

private struct ResultsList: View {
    @Environment(AppModel.self) private var model
    let report: ScanReport
    let filter: String

    var body: some View {
        List {
            ForEach(report.categories) { category in
                let items = filter.isEmpty ? category.items : category.items.filter {
                    $0.url.path.localizedCaseInsensitiveContains(filter)
                }
                if !items.isEmpty {
                    DisclosureGroup {
                        ForEach(items) { item in
                            ItemRow(item: item, isKeep: item.url == category.keep)
                        }
                    } label: {
                        HStack {
                            Toggle(isOn: categoryBinding(category)) { Text(category.title).bold() }
                            Spacer()
                            Text("\(items.count)").foregroundStyle(.tertiary)
                            Text(formatBytes(category.totalSize)).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func categoryBinding(_ category: ScanCategory) -> Binding<Bool> {
        let urls = category.items.filter { $0.url != category.keep }.map(\.url)
        return Binding(
            get: { !urls.isEmpty && urls.allSatisfy(model.selection.contains) },
            set: { model.setCategory(category, selected: $0) }
        )
    }
}

private struct ItemRow: View {
    @Environment(AppModel.self) private var model
    let item: ScanItem
    let isKeep: Bool

    var body: some View {
        HStack {
            Toggle(isOn: Binding(
                get: { model.selection.contains(item.url) },
                set: { on in
                    if on { model.selection.insert(item.url) } else { model.selection.remove(item.url) }
                }
            )) {
                HStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path)).resizable().frame(width: 18, height: 18)
                    VStack(alignment: .leading) {
                        HStack(spacing: 6) {
                            Text(item.displayName).lineLimit(1)
                            if isKeep {
                                Text("da tenere").font(.caption2.bold()).padding(.horizontal, 5)
                                    .background(.green.opacity(0.2), in: Capsule())
                            }
                        }
                        Text(item.detail ?? item.url.deletingLastPathComponent().path)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            if item.needsHelper {
                Label("password", systemImage: "lock.fill").font(.caption)
                    .padding(.horizontal, 6).background(.secondary.opacity(0.15), in: Capsule())
                    .help("Elemento di sistema: macOS chiederà la password di amministratore")
            }
            if item.risk == .high {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .help("Rischio alto: controlla prima di rimuovere")
            }
            Spacer()
            Text(formatBytes(item.size)).monospacedDigit().foregroundStyle(.secondary)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless)
                .help("Mostra nel Finder")
        }
        .contextMenu { FileContextMenu(url: item.url) }
    }
}

/// Open, reveal and copy-path actions for any file row.
struct FileContextMenu: View {
    let url: URL

    var body: some View {
        Button("Apri") { NSWorkspace.shared.open(url) }
        Button("Mostra nel Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        Button("Copia percorso") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.path, forType: .string)
        }
    }
}
