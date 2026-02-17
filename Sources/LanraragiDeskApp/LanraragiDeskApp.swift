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
        .commands {
            ReaderZoomCommands()
        }

        Window("Reader", id: "reader") {
            if let route = appModel.activeReaderRoute {
                ReaderView(route: route)
                    .environmentObject(appModel)
                    .frame(minWidth: 960, minHeight: 640)
            } else {
                ContentUnavailableView("No Archive Selected", systemImage: "book.closed")
                    .frame(minWidth: 520, minHeight: 360)
            }
        }
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
    }
}

private struct ReaderZoomCommands: Commands {
    @AppStorage("reader.zoomPercent") private var zoomPercent: Double = 100

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Menu("Zoom") {
                Button("Increase") {
                    zoomPercent = min(200, zoomPercent + 10)
                }
                .keyboardShortcut("=", modifiers: [.command])

                Button("Decrease") {
                    zoomPercent = max(50, zoomPercent - 10)
                }
                .keyboardShortcut("-", modifiers: [.command])

                Divider()

                Button("Reset") {
                    zoomPercent = 100
                }
                .keyboardShortcut("0", modifiers: [.command])
            }
        }
    }
}
