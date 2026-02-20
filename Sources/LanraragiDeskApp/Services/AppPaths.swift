import Foundation
import CryptoKit

enum AppPaths {
    static func appSupportDirectory() -> URL {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("LanraragiDesk", isDirectory: true)
    }

    static func indexDBURL() -> URL {
        appSupportDirectory().appendingPathComponent("index.sqlite")
    }

    static func cacheDirectory() -> URL {
        let dir = appSupportDirectory().appendingPathComponent("Cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func tagStatsCacheURL(baseURL: URL) -> URL {
        cacheDirectory().appendingPathComponent("tagstats-\(serverID(baseURL: baseURL)).json")
    }

    static func activityLogURL() -> URL {
        appSupportDirectory().appendingPathComponent("activity.json")
    }

    static func savedBatchQueriesURL() -> URL {
        appSupportDirectory().appendingPathComponent("saved-batch-queries.json")
    }

    private static func serverID(baseURL: URL) -> String {
        let s = baseURL.absoluteString.lowercased()
        let digest = SHA256.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
