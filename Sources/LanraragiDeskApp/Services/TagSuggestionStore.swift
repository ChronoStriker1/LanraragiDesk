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

    private struct CacheFile: Codable, Sendable {
        var fetchedAt: Date
        var minWeight: Int
        var tags: [SuggestionRecord]
    }

    private struct SuggestionRecord: Codable, Sendable {
        var value: String
        var weight: Int
    }

    private struct CacheEntry: Sendable {
        var fetchedAt: Date
        var minWeight: Int
        var tags: [IndexedSuggestion]
    }

    private struct IndexedSuggestion: Sendable {
        let suggestion: Suggestion
        let lowercaseValue: String
        let lowercaseNamespaceValue: String?
    }

    private struct LoadKey: Hashable {
        let baseURL: String
        let minWeight: Int
    }

    private struct InFlightLoad {
        let id: UUID
        let task: Task<CacheEntry, Error>
    }

    private var cacheByBaseURL: [String: CacheEntry] = [:]
    private var lastErrorByBaseURL: [String: String] = [:]
    private var inFlightLoads: [LoadKey: InFlightLoad] = [:]

    func refresh(profile: Profile, settings: Settings) async throws {
        _ = try await sharedServerLoad(profile: profile, settings: settings, staleDisk: nil)
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

        for indexed in entry.tags {
            let s = indexed.suggestion
            let lower = indexed.lowercaseValue
            if lower.hasPrefix(needle) {
                ranked.append((0, s))
                continue
            }

            if indexed.lowercaseNamespaceValue?.hasPrefix(needle) == true {
                ranked.append((1, s))
                continue
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
            cacheByBaseURL[baseKey] = makeCacheEntry(from: disk)
            lastErrorByBaseURL[baseKey] = nil
            return
        }

        _ = try await sharedServerLoad(profile: profile, settings: settings, staleDisk: disk)
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

    private func sharedServerLoad(profile: Profile, settings: Settings, staleDisk: CacheFile?) async throws -> CacheEntry {
        let baseKey = profile.baseURL.absoluteString
        let key = LoadKey(baseURL: baseKey, minWeight: settings.minWeight)
        if let existing = inFlightLoads[key] {
            return try await existing.task.value
        }

        let loadID = UUID()
        let task = Task<CacheEntry, Error> {
            do {
                let entry = try await fetchFromServer(profile: profile, settings: settings)
                cacheByBaseURL[baseKey] = entry
                lastErrorByBaseURL[baseKey] = nil
                try saveToDisk(baseURL: profile.baseURL, entry: entry)
                return entry
            } catch {
                // Keep stale suggestions useful while still surfacing the refresh failure.
                if let staleDisk {
                    cacheByBaseURL[baseKey] = makeCacheEntry(from: staleDisk)
                }
                lastErrorByBaseURL[baseKey] = ErrorPresenter.short(error)
                throw error
            }
        }
        inFlightLoads[key] = InFlightLoad(id: loadID, task: task)
        defer {
            if inFlightLoads[key]?.id == loadID {
                inFlightLoads[key] = nil
            }
        }
        return try await task.value
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

        return makeCacheEntry(fetchedAt: Date(), minWeight: settings.minWeight, suggestions: uniq)
    }

    private func saveToDisk(baseURL: URL, entry: CacheEntry) throws {
        let url = AppPaths.tagStatsCacheURL(baseURL: baseURL)
        let disk = CacheFile(
            fetchedAt: entry.fetchedAt,
            minWeight: entry.minWeight,
            tags: entry.tags.map {
                SuggestionRecord(value: $0.suggestion.value, weight: $0.suggestion.weight)
            }
        )
        let data = try JSONEncoder().encode(disk)
        try data.write(to: url, options: [.atomic])
    }

    private func loadFromDisk(baseURL: URL) -> CacheFile? {
        let url = AppPaths.tagStatsCacheURL(baseURL: baseURL)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CacheFile.self, from: data)
    }

    private func makeCacheEntry(from disk: CacheFile) -> CacheEntry {
        makeCacheEntry(
            fetchedAt: disk.fetchedAt,
            minWeight: disk.minWeight,
            suggestions: disk.tags.map { Suggestion(value: $0.value, weight: $0.weight) }
        )
    }

    private func makeCacheEntry(fetchedAt: Date, minWeight: Int, suggestions: [Suggestion]) -> CacheEntry {
        let indexed = suggestions.map { suggestion in
            let lowercaseValue = suggestion.value.lowercased()
            let namespaceValue: String?
            if let separator = lowercaseValue.firstIndex(of: ":") {
                namespaceValue = String(lowercaseValue[lowercaseValue.index(after: separator)...])
            } else {
                namespaceValue = nil
            }
            return IndexedSuggestion(
                suggestion: suggestion,
                lowercaseValue: lowercaseValue,
                lowercaseNamespaceValue: namespaceValue
            )
        }
        return CacheEntry(fetchedAt: fetchedAt, minWeight: minWeight, tags: indexed)
    }
}
