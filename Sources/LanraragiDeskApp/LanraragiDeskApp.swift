import SwiftUI

@main
struct LanraragiDeskApp: App {
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appModel)
        }
        .windowStyle(.automatic)
    }
}
