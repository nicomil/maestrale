import SwiftUI

@main
struct MacCleanerApp: App {
    @State private var model = AppModel()
    @AppStorage("showMenuBar") private var showMenuBar = true

    var body: some Scene {
        Window("MacCleaner", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 600)
                .task { model.startScheduler() }
        }
        .defaultSize(width: 1180, height: 760)

        MenuBarExtra("MacCleaner", systemImage: "sparkles", isInserted: $showMenuBar) {
            MenuBarContent().environment(model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environment(model)
        }
    }
}
