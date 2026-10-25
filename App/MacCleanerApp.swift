import SwiftUI

@main
struct MacCleanerApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("MacCleaner") {
            ContentView()
                .environment(model)
                .frame(minWidth: 820, minHeight: 520)
        }
    }
}
