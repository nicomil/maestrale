import SwiftUI

@main
struct MacCleanerApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("MacCleaner") {
            ContentView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 600)
        }
        .defaultSize(width: 1180, height: 760)
    }
}
