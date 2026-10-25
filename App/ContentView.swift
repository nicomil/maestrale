import MacCleanerCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var destination: Destination? = .module("system-junk")

    var body: some View {
        NavigationSplitView {
            List(selection: $destination) {
                ForEach(model.sections) { section in
                    Section(section.title) {
                        ForEach(section.entries) { entry in
                            Label(entry.title, systemImage: entry.icon).tag(entry.destination)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            switch destination {
            case .module(let id)?:
                if let state = model.modules[id] { ModuleView(state: state) }
            case .spaceLens?:
                SpaceLensView()
            case nil:
                ContentUnavailableView("Scegli una funzione", systemImage: "sparkles")
            }
        }
    }
}

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
