import MacCleanerCore
import MacCleanerModules
import SwiftUI

/// Apps on the left, the selected app's files on the right.
struct UninstallerView: View {
    @Environment(AppModel.self) private var model
    @State private var confirm: Action?

    enum Action: Identifiable { case uninstall, reset; var id: Self { self } }

    private var uninstaller: UninstallerModel { model.uninstaller }

    var body: some View {
        @Bindable var uninstaller = uninstaller
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    TextField("Cerca", text: $uninstaller.search).textFieldStyle(.roundedBorder)
                    Picker("Ordina", selection: $uninstaller.sort) {
                        ForEach(UninstallerModel.Sort.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                .padding(8)
                if uninstaller.isLoading && uninstaller.apps.isEmpty {
                    ProgressView("Lettura delle app…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(uninstaller.visibleApps, selection: Binding(
                        get: { uninstaller.selectedApp?.url },
                        set: { url in
                            guard !uninstaller.isWorking else { return }
                            Task { await uninstaller.select(uninstaller.apps.first { $0.url == url }) }
                        }
                    )) { app in
                        AppRow(app: app).tag(app.url)
                    }
                    .disabled(uninstaller.isWorking)
                }
            }
            .frame(minWidth: 280, idealWidth: 320)

            detail.frame(minWidth: 360)
        }
        .navigationTitle("Disinstallazione")
        .task { if uninstaller.apps.isEmpty { await uninstaller.load() } }
    }

    @ViewBuilder private var detail: some View {
        if let app = uninstaller.selectedApp {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                        .resizable().frame(width: 48, height: 48)
                    VStack(alignment: .leading) {
                        Text(app.name).font(.title2.bold())
                        Text("\(app.bundleID) · versione \(app.version)").foregroundStyle(.secondary).font(.callout)
                    }
                    Spacer()
                }
                .padding()
                Divider()
                List(uninstaller.files) { file in
                    FileRow(file: file, selection: Binding(
                        get: { uninstaller.fileSelection.contains(file.url) },
                        set: { on in
                            if on { uninstaller.fileSelection.insert(file.url) }
                            else { uninstaller.fileSelection.remove(file.url) }
                        }))
                }
                Divider()
                footer(app)
            }
        } else {
            ContentUnavailableView("Scegli un'app", systemImage: "app.dashed",
                                   description: Text("Vedrai l'app e tutti i file che ha sparso nel sistema."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func footer(_ app: InstalledApp) -> some View {
        @Bindable var model = model
        let size = uninstaller.selectedFiles.reduce(Int64(0)) { $0 + $1.size }
        return HStack {
            RemovalModePicker(mode: $model.removalMode)
            if let message = uninstaller.message { Text(message).foregroundStyle(.secondary) }
            Spacer()
            Button("Reset") { confirm = .reset }
                .help("Cancella dati e preferenze, l'app resta installata")
                .disabled(uninstaller.isWorking || uninstaller.selectedFiles.allSatisfy { $0.url == app.url })
            Button("Disinstalla \(formatBytes(size))") { confirm = .uninstall }
                .buttonStyle(.borderedProminent)
                .disabled(uninstaller.isWorking || uninstaller.selectedFiles.isEmpty)
        }
        .padding()
        .confirmationDialog(confirm == .reset ? "Resettare \(app.name)?" : "Disinstallare \(app.name)?",
                            isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            presenting: confirm) { action in
            Button(action == .reset ? "Reset" : "Disinstalla",
                   role: model.removalMode == .delete ? .destructive : nil) {
                Task { await uninstaller.run(reset: action == .reset, mode: model.removalMode) }
            }
        } message: { _ in
            Text("L'app verrà chiusa se è aperta. " + model.removalMode.confirmation)
        }
    }
}

private struct AppRow: View {
    let app: InstalledApp

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).lineLimit(1)
                Text(RelativeAge.text(since: app.lastUsed).map { "Usata \($0)" } ?? "Mai aperta")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if app.isAppStore {
                Image(systemName: "bag").foregroundStyle(.secondary).help("App Store")
            }
            Text(formatBytes(app.size)).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}

private struct FileRow: View {
    let file: ScanItem
    @Binding var selection: Bool

    var body: some View {
        HStack {
            Toggle(isOn: $selection) {
                VStack(alignment: .leading) {
                    Text(file.displayName).lineLimit(1)
                    Text(file.detail ?? "").font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            if file.needsHelper {
                Label("password", systemImage: "lock.fill").font(.caption)
                    .padding(.horizontal, 6).background(.secondary.opacity(0.15), in: Capsule())
                    .help("File di sistema: macOS chiederà la password di amministratore")
            }
            if file.risk == .medium && file.detail != "Applicazione" {
                Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
                    .help("Trovato per nome: controlla che appartenga davvero a questa app")
            }
            Spacer()
            Text(formatBytes(file.size)).monospacedDigit().foregroundStyle(.secondary)
            Button { NSWorkspace.shared.activateFileViewerSelecting([file.url]) } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
        }
    }
}
