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

        WindowGroup(for: ReaderRoute.self) { $route in
            if let route {
                ReaderView(route: route)
                    .environmentObject(appModel)
                    .frame(minWidth: 860, minHeight: 640)
            } else {
                ContentUnavailableView("No Archive Selected", systemImage: "book.closed")
                    .frame(minWidth: 520, minHeight: 360)
            }
        }
    }
}
