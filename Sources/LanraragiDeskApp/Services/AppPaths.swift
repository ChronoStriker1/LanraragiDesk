import Foundation

enum AppPaths {
    static func appSupportDirectory() -> URL {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("LanraragiDesk", isDirectory: true)
    }

    static func indexDBURL() -> URL {
        appSupportDirectory().appendingPathComponent("index.sqlite")
    }
}

