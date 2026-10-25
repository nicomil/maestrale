import MacCleanerCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedModule: String? = "system-junk"

    var body: some View {
        NavigationSplitView {
            List(model.modules, selection: $selectedModule) { state in
                Label(state.module.title, systemImage: icon(for: state.id))
                    .tag(state.id)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            if let id = selectedModule, let state = model.modules.first(where: { $0.id == id }) {
                ModuleView(state: state)
            } else {
                ContentUnavailableView("Scegli un modulo", systemImage: "sparkles")
            }
        }
    }

    private func icon(for id: String) -> String {
        switch id {
        case "system-junk": "internaldrive"
        case "trash": "trash"
        default: "square.grid.2x2"
        }
    }
}

private struct ModuleView: View {
    @Environment(AppModel.self) private var model
    let state: AppModel.ModuleState
    @State private var confirmClean = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let report = state.report {
                if !report.unreadablePaths.isEmpty { fullDiskAccessBanner }
                ResultsList(report: report)
                Divider()
                footer
            } else if state.isScanning {
                ProgressView("Scansione in corso…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Nessuna scansione", systemImage: "magnifyingglass",
                                       description: Text("Premi Scansiona per cercare file da pulire."))
            }
        }
        .navigationTitle(state.module.title)
    }

    private var header: some View {
        HStack {
            if let report = state.report {
                Text("Trovati \(format(report.totalSize))").font(.title2.bold())
            }
            if let error = state.error { Text(error).foregroundStyle(.red) }
            Spacer()
            Button(state.report == nil ? "Scansiona" : "Scansiona di nuovo") {
                Task { await model.scan(state.id) }
            }
            .disabled(state.isScanning)
            .keyboardShortcut("r")
        }
        .padding()
    }

    private var fullDiskAccessBanner: some View {
        HStack {
            Image(systemName: "lock.shield")
            Text("Alcune cartelle non sono leggibili. Concedi l'Accesso completo al disco per risultati completi.")
            Spacer()
            Button("Apri Impostazioni") {
                NSWorkspace.shared.open(URL(string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
            }
        }
        .font(.callout)
        .padding(8)
        .background(.yellow.opacity(0.15))
    }

    private var footer: some View {
        @Bindable var model = model
        return HStack {
            Picker("Modalità", selection: $model.removalMode) {
                Text("Sposta nel Cestino").tag(RemovalMode.trash)
                Text("Prova (non rimuove nulla)").tag(RemovalMode.dryRun)
                Text("Elimina definitivamente").tag(RemovalMode.delete)
            }
            .fixedSize()
            if let summary = model.lastCleanSummary { Text(summary).foregroundStyle(.secondary) }
            Spacer()
            Button("Pulisci \(format(model.selectedSize(in: state.id)))") { confirmClean = true }
                .buttonStyle(.borderedProminent)
                .disabled(model.selectedItems(in: state.id).isEmpty || model.isCleaning)
                .confirmationDialog("Pulire \(model.selectedItems(in: state.id).count) elementi?",
                                    isPresented: $confirmClean) {
                    Button(model.removalMode == .delete ? "Elimina definitivamente" : "Pulisci",
                           role: model.removalMode == .delete ? .destructive : nil) {
                        Task { await model.clean(state.id) }
                    }
                } message: {
                    Text(model.removalMode == .delete
                         ? "I file verranno eliminati e non si potranno recuperare."
                         : "Potrai recuperare i file dal Cestino.")
                }
        }
        .padding()
    }
}

private struct ResultsList: View {
    @Environment(AppModel.self) private var model
    let report: ScanReport

    var body: some View {
        List {
            ForEach(report.categories) { category in
                DisclosureGroup {
                    ForEach(category.items) { item in ItemRow(item: item) }
                } label: {
                    HStack {
                        Toggle(isOn: categoryBinding(category)) { Text(category.title).bold() }
                        Spacer()
                        Text(format(category.totalSize)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func categoryBinding(_ category: ScanCategory) -> Binding<Bool> {
        let urls = category.items.filter { !$0.needsHelper }.map(\.url)
        return Binding(
            get: { !urls.isEmpty && urls.allSatisfy(model.selection.contains) },
            set: { on in
                if on { model.selection.formUnion(urls) } else { model.selection.subtract(urls) }
            }
        )
    }
}

private struct ItemRow: View {
    @Environment(AppModel.self) private var model
    let item: ScanItem

    var body: some View {
        HStack {
            Toggle(isOn: Binding(
                get: { model.selection.contains(item.url) },
                set: { on in
                    if on { model.selection.insert(item.url) } else { model.selection.remove(item.url) }
                }
            )) {
                VStack(alignment: .leading) {
                    Text(item.displayName)
                    Text(item.url.deletingLastPathComponent().path)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            .disabled(item.needsHelper)
            if item.needsHelper {
                Text("serve helper").font(.caption).padding(.horizontal, 6)
                    .background(.secondary.opacity(0.15), in: Capsule())
            }
            if item.risk == .high {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .help("Rischio alto: controlla prima di rimuovere")
            }
            Spacer()
            Text(format(item.size)).monospacedDigit().foregroundStyle(.secondary)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless)
                .help("Mostra nel Finder")
        }
    }
}

private func format(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
