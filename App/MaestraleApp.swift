import SwiftUI

@main
struct MaestraleApp: App {
    @State private var model = AppModel()
    @AppStorage("showMenuBar") private var showMenuBar = true

    init() {
        // Log, quarantine and preferences kept under the previous name.
        if !AppModel.isRunningTests { LegacyMigration.run() }
    }

    var body: some Scene {
        Window("Maestrale", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 1000, minHeight: 600)
                .task { if !AppModel.isRunningTests { model.startScheduler() } }
        }
        .defaultSize(width: 1180, height: 760)

        MenuBarExtra("Maestrale", systemImage: "sparkles", isInserted: $showMenuBar) {
            MenuBarContent().environment(model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environment(model)
        }
    }
}
