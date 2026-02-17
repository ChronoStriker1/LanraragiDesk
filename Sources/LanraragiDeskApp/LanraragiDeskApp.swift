import SwiftUI
import AppKit

@main
struct LanraragiDeskApp: App {
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appModel)
        }
        .windowStyle(.automatic)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands {
            ReaderZoomCommands()
            ReaderOpenInLANraragiCommands(appModel: appModel)
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

private struct ReaderOpenInLANraragiCommands: Commands {
    @ObservedObject var appModel: AppModel

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Open in LANraragi") {
                guard
                    let route = appModel.activeReaderRoute,
                    let profile = appModel.profileStore.profiles.first(where: { $0.id == route.profileID }),
                    var comps = URLComponents(url: profile.baseURL, resolvingAgainstBaseURL: false)
                else { return }
                comps.path = "/reader"
                comps.queryItems = [URLQueryItem(name: "id", value: route.arcid)]
                guard let url = comps.url else { return }
                NSWorkspace.shared.open(url)
                appModel.activity.add(.init(kind: .action, title: "Opened in LANraragi", detail: route.arcid, component: "Reader"))
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .disabled(appModel.activeReaderRoute == nil)
        }
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
