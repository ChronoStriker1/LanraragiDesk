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
    private var lastErrorByBaseURL: [String: String] = [:]

    func refresh(profile: Profile, settings: Settings) async throws {
        let baseKey = profile.baseURL.absoluteString
        let entry = try await fetchFromServer(profile: profile, settings: settings)
        cacheByBaseURL[baseKey] = entry
        lastErrorByBaseURL[baseKey] = nil
        try saveToDisk(baseURL: profile.baseURL, entry: entry)
    }

    func suggestions(profile: Profile, settings: Settings, prefix: String, limit: Int = 20) async -> [Suggestion] {
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        do {
            try await ensureLoaded(profile: profile, settings: settings)
        } catch {
            // No suggestions available.
            let baseKey = profile.baseURL.absoluteString
            lastErrorByBaseURL[baseKey] = ErrorPresenter.short(error)
        }

        let baseKey = profile.baseURL.absoluteString
        guard let entry = cacheByBaseURL[baseKey] else { return [] }

        let needle = trimmed.lowercased()
        let allowContainsMatch = needle.count >= 2
        // Score matches so plain-text typing can still find namespaced tags:
        // 0: full token prefix, 1: value-after-namespace prefix, 2: contains.
        var ranked: [(Int, Suggestion)] = []
        ranked.reserveCapacity(min(entry.tags.count, 256))

        for s in entry.tags {
            let lower = s.value.lowercased()
            if lower.hasPrefix(needle) {
                ranked.append((0, s))
                continue
            }

            if let idx = lower.firstIndex(of: ":") {
                let rhs = lower[lower.index(after: idx)...]
                if rhs.hasPrefix(needle) {
                    ranked.append((1, s))
                    continue
                }
            }

            if allowContainsMatch, lower.contains(needle) {
                ranked.append((2, s))
            }
        }

        ranked.sort { a, b in
            if a.0 != b.0 { return a.0 < b.0 }
            if a.1.weight != b.1.weight { return a.1.weight > b.1.weight }
            return a.1.value.localizedCaseInsensitiveCompare(b.1.value) == .orderedAscending
        }
        return Array(ranked.prefix(limit).map(\.1))
    }

    func prewarm(profile: Profile, settings: Settings) async {
        do {
            try await ensureLoaded(profile: profile, settings: settings)
        } catch {
            let baseKey = profile.baseURL.absoluteString
            lastErrorByBaseURL[baseKey] = ErrorPresenter.short(error)
        }
    }

    func lastError(profile: Profile) -> String? {
        lastErrorByBaseURL[profile.baseURL.absoluteString]
    }

    private func ensureLoaded(profile: Profile, settings: Settings) async throws {
        let baseKey = profile.baseURL.absoluteString
        if let entry = cacheByBaseURL[baseKey], isFresh(entry: entry, settings: settings) {
            lastErrorByBaseURL[baseKey] = nil
            return
        }

        let disk = loadFromDisk(baseURL: profile.baseURL)
        if let disk, isFreshDisk(disk: disk, settings: settings) {
            let tags = disk.tags.map { Suggestion(value: $0.value, weight: $0.weight) }
            cacheByBaseURL[baseKey] = CacheEntry(fetchedAt: disk.fetchedAt, minWeight: disk.minWeight, tags: tags)
            lastErrorByBaseURL[baseKey] = nil
            return
        }

        do {
            let entry = try await fetchFromServer(profile: profile, settings: settings)
            cacheByBaseURL[baseKey] = entry
            lastErrorByBaseURL[baseKey] = nil
            try saveToDisk(baseURL: profile.baseURL, entry: entry)
        } catch {
            // Fallback to stale on-disk cache when online refresh fails.
            if let disk {
                let tags = disk.tags.map { Suggestion(value: $0.value, weight: $0.weight) }
                cacheByBaseURL[baseKey] = CacheEntry(fetchedAt: disk.fetchedAt, minWeight: disk.minWeight, tags: tags)
            }
            throw error
        }
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
            maxConnectionsPerHost: AppSettings.maxConnectionsPerHost(defaultValue: 8)
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
