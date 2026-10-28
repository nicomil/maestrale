import MaestraleCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var destination: Destination? = .smartCare
    @AppStorage("didShowWelcome") private var didShowWelcome = false

    var body: some View {
        NavigationSplitView {
            List(selection: $destination) {
                ForEach(model.sections) { section in
                    if section.title.isEmpty {
                        ForEach(section.entries) { entry in
                            SidebarRow(entry: entry).tag(entry.destination)
                        }
                    } else {
                        Section(section.title) {
                            ForEach(section.entries) { entry in
                                SidebarRow(entry: entry).tag(entry.destination)
                            }
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 250)
        } detail: {
            Group {
                switch destination {
            case .smartCare?:
                SmartCareView(destination: $destination)
            case .module(let id)?:
                if let state = model.modules[id] { ModuleView(state: state) }
            case .spaceLens?:
                SpaceLensView()
            case .uninstaller?:
                UninstallerView()
            case .updates?:
                UpdatesView()
            case .privacy?:
                PrivacyView()
            case .performance?:
                PerformanceView()
            case .protection?:
                ProtectionView()
            case .activity?:
                ActivityView()
            case nil:
                ContentUnavailableView("Scegli una funzione", systemImage: "sparkles")
                }
            }
            .overlay(alignment: .bottom) {
                ProgressBanner()
                    .animation(.easeInOut(duration: 0.2), value: ProgressCenter.shared.current != nil)
            }
        }
        .sheet(isPresented: Binding(get: { !didShowWelcome }, set: { if !$0 { didShowWelcome = true } })) {
            WelcomeView { didShowWelcome = true }
        }
    }
}

private struct SidebarRow: View {
    @Environment(AppModel.self) private var model
    let entry: SidebarEntry

    var body: some View {
        Label(entry.title, systemImage: entry.icon)
            .badge(model.badge(for: entry.destination).map { Text($0) })
    }
}

/// First launch: what the app does, the safety rules and the one permission it needs.
struct WelcomeView: View {
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 84, height: 84)
            Text("Benvenuto in Maestrale").font(.largeTitle.bold())
            VStack(alignment: .leading, spacing: 14) {
                point("sparkles", "Smart Care", "Un clic per controllare pulizia, protezione, aggiornamenti e prestazioni.")
                point("trash", "Niente sparisce per sbaglio",
                      "Di default i file vanno nel Cestino, e c'è la modalità Prova. Ogni operazione finisce nel registro.")
                point("lock.shield", "Accesso completo al disco",
                      "Serve per leggere Safari, i profili dei browser e i dati delle altre app. Puoi darlo ora o più tardi.")
            }
            .frame(maxWidth: 440)
            HStack {
                Button("Apri Accesso completo al disco") { openFullDiskAccessSettings() }
                Spacer()
                Button("Inizia", action: onDone).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
            .frame(maxWidth: 440)
        }
        .padding(32)
    }

    private func point(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.title2).foregroundStyle(.tint).frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

func formatBytes(_ bytes: Int64) -> String {
    bytes == 0 ? "0 KB" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
