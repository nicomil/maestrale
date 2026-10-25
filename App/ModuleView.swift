import MacCleanerCore
import SwiftUI

/// Scan → review → clean screen shared by every list-based module.
struct ModuleView: View {
    @Environment(AppModel.self) private var model
    let state: AppModel.ModuleState
    @State private var confirmClean = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let report = state.report {
                if !report.unreadablePaths.isEmpty { FullDiskAccessBanner() }
                if report.categories.isEmpty {
                    ContentUnavailableView("Tutto pulito", systemImage: "checkmark.seal",
                                           description: Text("Nessun elemento trovato."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ResultsList(report: report)
                }
                Divider()
                footer
            } else if state.isScanning {
                ProgressView("Scansione in corso…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(state.module.title, systemImage: state.icon,
                                       description: Text("Premi Scansiona per cominciare."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle(state.module.title)
    }

    private var header: some View {
        HStack {
            if let report = state.report {
                Text("Trovati \(formatBytes(report.totalSize))").font(.title2.bold())
            }
            if state.isScanning && state.report != nil { ProgressView().controlSize(.small) }
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

    private var footer: some View {
        @Bindable var model = model
        let blocked = model.fullySelectedCopyGroups(in: state.id)
        return HStack {
            RemovalModePicker(mode: $model.removalMode)
            if !blocked.isEmpty {
                Label("Lascia almeno una copia in \(blocked.count) gruppi", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else if let summary = state.lastCleanSummary {
                Text(summary).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Pulisci \(formatBytes(model.selectedSize(in: state.id)))") { confirmClean = true }
                .buttonStyle(.borderedProminent)
                .disabled(model.selectedItems(in: state.id).isEmpty || model.isCleaning || !blocked.isEmpty)
                .confirmationDialog("Pulire \(model.selectedItems(in: state.id).count) elementi?",
                                    isPresented: $confirmClean) {
                    Button(model.removalMode == .delete ? "Elimina definitivamente" : "Pulisci",
                           role: model.removalMode == .delete ? .destructive : nil) {
                        Task { await model.clean(state.id) }
                    }
                } message: {
                    Text(model.removalMode.confirmation)
                }
        }
        .padding()
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
    var body: some View {
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
}

private struct ResultsList: View {
    @Environment(AppModel.self) private var model
    let report: ScanReport

    var body: some View {
        List {
            ForEach(report.categories) { category in
                DisclosureGroup {
                    ForEach(category.items) { item in
                        ItemRow(item: item, isKeep: item.url == category.keep)
                    }
                } label: {
                    HStack {
                        Toggle(isOn: categoryBinding(category)) { Text(category.title).bold() }
                        Spacer()
                        Text("\(category.items.count)").foregroundStyle(.tertiary)
                        Text(formatBytes(category.totalSize)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func categoryBinding(_ category: ScanCategory) -> Binding<Bool> {
        let urls = category.items.filter { !$0.needsHelper && $0.url != category.keep }.map(\.url)
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
                VStack(alignment: .leading) {
                    HStack(spacing: 6) {
                        Text(item.displayName)
                        if isKeep {
                            Text("da tenere").font(.caption2.bold()).padding(.horizontal, 5)
                                .background(.green.opacity(0.2), in: Capsule())
                        }
                    }
                    Text(item.detail ?? item.url.deletingLastPathComponent().path)
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
            Text(formatBytes(item.size)).monospacedDigit().foregroundStyle(.secondary)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless)
                .help("Mostra nel Finder")
        }
    }
}
