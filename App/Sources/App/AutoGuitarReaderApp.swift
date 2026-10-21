import SwiftUI

@main
@MainActor
struct AutoGuitarReaderApp: App {
    @State private var store = ScoreStore(seedSamples: true)
    @State private var settings = SettingsStore()
    @State private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(settings)
                .environment(appModel)
                .onOpenURL { url in
                    appModel.handleOpenURL(url)
                }
        }
    }
}
