import Foundation
import LanraragiKit

actor TagSuggestionStore {
    struct Settings: Sendable, Equatable {
        var minWeight: Int
        var ttlSeconds: Int

        init(minWeight: Int = 0, ttlSeconds: Int = 24 * 60 * 60) {
            self.minWeight = max(0, minWeight)
            self.ttlSeconds = max(60, ttlSeconds)
        }
    }

    struct Suggestion: Sendable, Equatable, Hashable {
        let value: String
        let weight: Int
    }

    private struct CacheFile: Codable {
        var fetchedAt: Date
        var minWeight: Int
        var tags: [SuggestionRecord]
    }

    private struct SuggestionRecord: Codable {
        var value: String
        var weight: Int
    }

    private struct CacheEntry {
        var fetchedAt: Date
        var minWeight: Int
        var tags: [Suggestion]
    }

    private var cacheByBaseURL: [String: CacheEntry] = [:]

    func refresh(profile: Profile, settings: Settings) async throws {
        let baseKey = profile.baseURL.absoluteString
        let entry = try await fetchFromServer(profile: profile, settings: settings)
        cacheByBaseURL[baseKey] = entry
        try saveToDisk(baseURL: profile.baseURL, entry: entry)
    }

    func suggestions(profile: Profile, settings: Settings, prefix: String, limit: Int = 20) async -> [Suggestion] {
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        do {
            try await ensureLoaded(profile: profile, settings: settings)
        } catch {
            // No suggestions available.
        }

        let baseKey = profile.baseURL.absoluteString
        guard let entry = cacheByBaseURL[baseKey] else { return [] }

        let needle = trimmed.lowercased()
        var out: [Suggestion] = []
        out.reserveCapacity(min(limit, 40))

        for s in entry.tags {
            if s.value.lowercased().hasPrefix(needle) {
                out.append(s)
                if out.count >= limit { break }
            }
        }

        return out
    }

    private func ensureLoaded(profile: Profile, settings: Settings) async throws {
        let baseKey = profile.baseURL.absoluteString
        if let entry = cacheByBaseURL[baseKey], isFresh(entry: entry, settings: settings) {
            return
        }

        if let disk = loadFromDisk(baseURL: profile.baseURL), isFreshDisk(disk: disk, settings: settings) {
            let tags = disk.tags.map { Suggestion(value: $0.value, weight: $0.weight) }
            cacheByBaseURL[baseKey] = CacheEntry(fetchedAt: disk.fetchedAt, minWeight: disk.minWeight, tags: tags)
            return
        }

        let entry = try await fetchFromServer(profile: profile, settings: settings)
        cacheByBaseURL[baseKey] = entry
        try saveToDisk(baseURL: profile.baseURL, entry: entry)
    }

    private func isFresh(entry: CacheEntry, settings: Settings) -> Bool {
        if entry.minWeight != settings.minWeight { return false }
        let age = Int(Date().timeIntervalSince(entry.fetchedAt))
        return age <= settings.ttlSeconds
    }

    private func isFreshDisk(disk: CacheFile, settings: Settings) -> Bool {
        if disk.minWeight != settings.minWeight { return false }
        let age = Int(Date().timeIntervalSince(disk.fetchedAt))
        return age <= settings.ttlSeconds
    }

    private func fetchFromServer(profile: Profile, settings: Settings) async throws -> CacheEntry {
        let account = "apiKey.\(profile.id.uuidString)"
        let apiKeyString = try KeychainService.getString(account: account)
        let apiKey = apiKeyString.map { LANraragiAPIKey($0) }

        let client = LANraragiClient(configuration: .init(
            baseURL: profile.baseURL,
            apiKey: apiKey,
            acceptLanguage: profile.language,
            maxConnectionsPerHost: 6
        ))

        let stats = try await client.getDatabaseStats(minWeight: settings.minWeight)

        var out: [Suggestion] = []
        out.reserveCapacity(stats.tags.count)

        for t in stats.tags {
            let ns = (t.namespace ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let tx = (t.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let w = t.weight ?? t.count ?? 0

            if !ns.isEmpty, !tx.isEmpty {
                out.append(Suggestion(value: "\(ns):\(tx)", weight: w))
            } else if !tx.isEmpty {
                out.append(Suggestion(value: tx, weight: w))
            }
        }

        // Highest weight first, then alphabetically.
        out.sort { a, b in
            if a.weight != b.weight { return a.weight > b.weight }
            return a.value.localizedCaseInsensitiveCompare(b.value) == .orderedAscending
        }

        // De-dupe while preserving order.
        var seen: Set<String> = []
        var uniq: [Suggestion] = []
        uniq.reserveCapacity(out.count)
        for s in out {
            if seen.insert(s.value).inserted {
                uniq.append(s)
            }
        }

        return CacheEntry(fetchedAt: Date(), minWeight: settings.minWeight, tags: uniq)
    }

    private func saveToDisk(baseURL: URL, entry: CacheEntry) throws {
        let url = AppPaths.tagStatsCacheURL(baseURL: baseURL)
        let disk = CacheFile(
            fetchedAt: entry.fetchedAt,
            minWeight: entry.minWeight,
            tags: entry.tags.map { SuggestionRecord(value: $0.value, weight: $0.weight) }
        )
        let data = try JSONEncoder().encode(disk)
        try data.write(to: url, options: [.atomic])
    }

    private func loadFromDisk(baseURL: URL) -> CacheFile? {
        let url = AppPaths.tagStatsCacheURL(baseURL: baseURL)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CacheFile.self, from: data)
    }
}

