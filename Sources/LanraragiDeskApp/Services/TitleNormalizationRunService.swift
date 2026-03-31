import Foundation
import LanraragiKit

struct TitleNormalizationPlan: Sendable {
    struct Item: Identifiable, Sendable, Codable {
        let id: String
        let arcid: String
        let originalTitle: String
        let englishTitle: String
        let detectedLanguage: String
        let beforeTags: String
        let afterTags: String
        let shouldUpdate: Bool

        init(
            arcid: String,
            originalTitle: String,
            englishTitle: String,
            detectedLanguage: String,
            beforeTags: String,
            afterTags: String,
            shouldUpdate: Bool
        ) {
            self.id = arcid
            self.arcid = arcid
            self.originalTitle = originalTitle
            self.englishTitle = englishTitle
            self.detectedLanguage = detectedLanguage
            self.beforeTags = beforeTags
            self.afterTags = afterTags
            self.shouldUpdate = shouldUpdate
        }
    }

    let snapshotCount: Int
    let candidateCount: Int
    let itemCount: Int
    let planFilePath: String
    let previewItems: [Item]
}

struct TitleNormalizationProgress: Sendable {
    enum Stage: String, Sendable {
        case scanning
        case translating
        case applying
        case finished
    }

    let stage: Stage
    let scanned: Int
    let candidates: Int
    let translated: Int
    let applied: Int
    let failed: Int
    let message: String
}

struct TitleNormalizationApplyResult: Sendable {
    let successCount: Int
    let failures: [Failure]

    struct Failure: Identifiable, Sendable {
        let id: String
        let arcid: String
        let reason: String

        init(arcid: String, reason: String) {
            self.id = arcid
            self.arcid = arcid
            self.reason = reason
        }
    }
}

actor TitleNormalizationRunService {
    private let translationChunkSize = 50
    private let maxConcurrentTranslationChunks = 4
    private let codexTranslationChunkSize = 40
    private let codexMaxConcurrentTranslationChunks = 1

    struct SnapshotEntry: Sendable {
        let arcid: String
        let title: String
        let tags: String
    }

    private struct ChunkTranslationOutcome: Sendable {
        let index: Int
        let chunkSize: Int
        let translatedCount: Int
        let duration: TimeInterval
        let updates: [TitleNormalizationPlan.Item]
    }

    func buildPlan(
        profile: Profile,
        translationConfig: TitleTranslationConfig,
        report: @escaping @Sendable (TitleNormalizationProgress) -> Void
    ) async throws -> TitleNormalizationPlan {
        let client = try makeClient(profile: profile)
        let translationClient = try await makeTranslationClient(config: translationConfig)
        let chunkSize = translationConfig.provider == .codexCLI ? codexTranslationChunkSize : translationChunkSize
        let maxConcurrentChunks = translationConfig.provider == .codexCLI ? codexMaxConcurrentTranslationChunks : maxConcurrentTranslationChunks
        report(.init(stage: .scanning, scanned: 0, candidates: 0, translated: 0, applied: 0, failed: 0, message: "Loading archive IDs…"))
        let arcids = try await loadAllArcids(client: client)

        report(.init(stage: .scanning, scanned: 0, candidates: 0, translated: 0, applied: 0, failed: 0, message: "Loading metadata snapshot…"))
        let snapshot = try await loadSnapshot(client: client, arcids: arcids, report: report)

        let candidates = snapshot.filter { shouldConsiderForTranslation(title: $0.title, tags: $0.tags) }
        if candidates.isEmpty {
            report(.init(stage: .finished, scanned: snapshot.count, candidates: 0, translated: 0, applied: 0, failed: 0, message: "No translation candidates found."))
            return TitleNormalizationPlan(snapshotCount: snapshot.count, candidateCount: 0, itemCount: 0, planFilePath: "", previewItems: [])
        }

        var translatedCount = 0
        var plannedCount = 0
        var previewItems: [TitleNormalizationPlan.Item] = []
        previewItems.reserveCapacity(50)
        let runFileURL = try makeRunFileURL()
        let writer = try PlanFileWriter(url: runFileURL)
        defer { try? writer.close() }

        let chunks = chunkedCandidates(candidates, maxItems: chunkSize)
        report(.init(
            stage: .translating,
            scanned: snapshot.count,
            candidates: candidates.count,
            translated: 0,
            applied: 0,
            failed: 0,
            message: "Candidate scan complete: \(candidates.count) titles across \(chunks.count) translation chunks (up to \(min(maxConcurrentChunks, chunks.count)) in flight)."
        ))
        var nextChunkIndex = 0
        let initialInFlight = min(maxConcurrentChunks, chunks.count)
        var inFlightCount = 0

        try await withThrowingTaskGroup(of: ChunkTranslationOutcome.self) { group in
            func addChunkTask(index: Int, translatedBefore: Int) {
                let chunk = chunks[index]
                inFlightCount += 1
                report(.init(
                    stage: .translating,
                    scanned: snapshot.count,
                    candidates: candidates.count,
                    translated: translatedBefore,
                    applied: 0,
                    failed: 0,
                    message: "Translating chunk \(index + 1)/\(chunks.count) (\(chunk.count) titles, \(inFlightCount) in flight)…"
                ))
                group.addTask {
                    try Task.checkCancellation()
                    let started = Date()
                    let batchItems = chunk.map { OpenAITranslationService.BatchItem(arcid: $0.arcid, title: $0.title) }
                    let results = try await Self.translateWithRetry(
                        client: translationClient,
                        model: translationConfig.model,
                        items: batchItems,
                        report: report,
                        snapshotCount: snapshot.count,
                        candidateCount: candidates.count,
                        translatedCount: translatedBefore
                    )
                    // Model output can occasionally contain duplicate arcids; keep the first to avoid a trap.
                    let resultMap = Dictionary(results.map { ($0.arcid, $0) }, uniquingKeysWith: { first, _ in first })
                    var updates: [TitleNormalizationPlan.Item] = []
                    updates.reserveCapacity(chunk.count)
                    var localTranslatedCount = 0
                    for entry in chunk {
                        guard let result = resultMap[entry.arcid] else { continue }
                        localTranslatedCount += 1
                        let detected = Self.normalizeLanguage(result.detectedLanguage)
                        let translated = result.englishTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                        let finalTitle = translated.isEmpty ? entry.title : translated
                        let adjusted = Self.adjustTags(
                            tags: entry.tags,
                            originalTitle: entry.title,
                            detectedLanguage: detected
                        )
                        let shouldUpdate = result.shouldTranslate && detected != "english" && finalTitle != entry.title
                        let hasTagChange = Self.normalizeTags(entry.tags) != Self.normalizeTags(adjusted)
                        if shouldUpdate || hasTagChange {
                            updates.append(.init(
                                arcid: entry.arcid,
                                originalTitle: entry.title,
                                englishTitle: finalTitle,
                                detectedLanguage: detected,
                                beforeTags: entry.tags,
                                afterTags: adjusted,
                                shouldUpdate: true
                            ))
                        }
                    }
                    return .init(
                        index: index,
                        chunkSize: chunk.count,
                        translatedCount: localTranslatedCount,
                        duration: Date().timeIntervalSince(started),
                        updates: updates
                    )
                }
            }

            for _ in 0..<initialInFlight {
                addChunkTask(index: nextChunkIndex, translatedBefore: translatedCount)
                nextChunkIndex += 1
            }

            while let outcome = try await group.next() {
                inFlightCount = max(0, inFlightCount - 1)
                translatedCount += outcome.translatedCount
                for item in outcome.updates {
                    try writer.append(item)
                    if previewItems.count < 50 {
                        previewItems.append(item)
                    }
                }
                plannedCount += outcome.updates.count

                report(.init(
                    stage: .translating,
                    scanned: snapshot.count,
                    candidates: candidates.count,
                    translated: translatedCount,
                    applied: 0,
                    failed: 0,
                    message: "Translated chunk \(outcome.index + 1)/\(chunks.count) in \(String(format: "%.1fs", outcome.duration))."
                ))

                if nextChunkIndex < chunks.count {
                    addChunkTask(index: nextChunkIndex, translatedBefore: translatedCount)
                    nextChunkIndex += 1
                }
            }
        }

        report(.init(
            stage: .finished,
            scanned: snapshot.count,
            candidates: candidates.count,
            translated: translatedCount,
            applied: 0,
            failed: 0,
            message: "Dry run ready. \(plannedCount) archives would be updated."
        ))

        return TitleNormalizationPlan(
            snapshotCount: snapshot.count,
            candidateCount: candidates.count,
            itemCount: plannedCount,
            planFilePath: runFileURL.path,
            previewItems: previewItems
        )
    }

    func applyPlan(
        profile: Profile,
        archives: ArchiveLoader,
        plan: TitleNormalizationPlan,
        onlyArcids: Set<String>? = nil,
        report: @escaping @Sendable (TitleNormalizationProgress) -> Void
    ) async -> TitleNormalizationApplyResult {
        let planFileURL = URL(fileURLWithPath: plan.planFilePath)
        guard FileManager.default.fileExists(atPath: planFileURL.path) else {
            report(.init(stage: .finished, scanned: plan.snapshotCount, candidates: plan.candidateCount, translated: plan.candidateCount, applied: 0, failed: 1, message: "Plan file missing. Run dry-run again."))
            return .init(successCount: 0, failures: [.init(arcid: "plan", reason: "Plan file missing.")])
        }

        let selectedCount: Int
        do {
            selectedCount = try countSelectedItems(in: planFileURL, onlyArcids: onlyArcids)
        } catch {
            report(.init(stage: .finished, scanned: plan.snapshotCount, candidates: plan.candidateCount, translated: plan.candidateCount, applied: 0, failed: 1, message: "Failed to read plan file."))
            return .init(successCount: 0, failures: [.init(arcid: "plan", reason: ErrorPresenter.short(error))])
        }

        if selectedCount == 0 {
            report(.init(stage: .finished, scanned: plan.snapshotCount, candidates: plan.candidateCount, translated: plan.candidateCount, applied: 0, failed: 0, message: "Nothing to apply."))
            return .init(successCount: 0, failures: [])
        }

        let counter = ProgressCounter(total: selectedCount)
        let failureCollector = FailureCollector()
        do {
            try await forEachPlanItem(in: planFileURL, onlyArcids: onlyArcids) { item in
                if Task.isCancelled {
                    return
                }
                do {
                    let latest = try await archives.metadata(profile: profile, arcid: item.arcid, forceRefresh: true)
                    let summary = latest.summary ?? ""
                    _ = try await archives.updateMetadata(
                        profile: profile,
                        arcid: item.arcid,
                        title: item.englishTitle,
                        tags: item.afterTags,
                        summary: summary
                    )
                    let progress = await counter.markApplied()
                    report(progress)
                } catch {
                    let reason = ErrorPresenter.short(error)
                    let progress = await counter.markFailed(reason: reason)
                    report(progress)
                    await failureCollector.append(.init(arcid: item.arcid, reason: reason))
                }
            }
        } catch {
            await failureCollector.append(.init(arcid: "plan", reason: ErrorPresenter.short(error)))
        }

        let failures = await failureCollector.values()
        let operationalFailures = failures.filter { $0.arcid != "plan" }
        let successCount = max(0, selectedCount - operationalFailures.count)
        report(.init(
            stage: .finished,
            scanned: plan.snapshotCount,
            candidates: plan.candidateCount,
            translated: plan.candidateCount,
            applied: successCount,
            failed: operationalFailures.count,
            message: failures.isEmpty ? "Apply completed." : "Apply completed with failures."
        ))

        return .init(successCount: successCount, failures: failures)
    }

    private func loadAllArcids(client: LANraragiClient) async throws -> [String] {
        var out: [String] = []
        out.reserveCapacity(10_000)
        var start = 0

        while true {
            try Task.checkCancellation()
            let response = try await client.search(start: start, sortBy: "title", order: "asc")
            let chunk = response.data.map(\.arcid)
            out.append(contentsOf: chunk)
            start += chunk.count
            if chunk.isEmpty || out.count >= response.recordsFiltered {
                break
            }
        }

        return out
    }

    private func loadSnapshot(
        client: LANraragiClient,
        arcids: [String],
        report: @escaping @Sendable (TitleNormalizationProgress) -> Void
    ) async throws -> [SnapshotEntry] {
        if arcids.isEmpty { return [] }

        let queue = WorkQueue(items: arcids)
        let counter = ScanCounter(total: arcids.count)
        var all: [SnapshotEntry] = []
        all.reserveCapacity(arcids.count)

        try await withThrowingTaskGroup(of: [SnapshotEntry].self) { group in
            let workers = 4
            for _ in 0..<workers {
                group.addTask {
                    var local: [SnapshotEntry] = []
                    while let arcid = await queue.next() {
                        try Task.checkCancellation()
                        let meta = try await client.getArchiveMetadata(arcid: arcid)
                        let entry = SnapshotEntry(
                            arcid: arcid,
                            title: (meta.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                            tags: Self.normalizeTags(meta.tags ?? "")
                        )
                        local.append(entry)
                        if let progress = await counter.bump() {
                            report(progress)
                        }
                    }
                    return local
                }
            }
            for try await local in group {
                all.append(contentsOf: local)
            }
        }

        return all
    }

    private static func translateWithRetry(
        client: any TitleTranslationProviderClient,
        model: String,
        items: [OpenAITranslationService.BatchItem],
        report: @escaping @Sendable (TitleNormalizationProgress) -> Void,
        snapshotCount: Int,
        candidateCount: Int,
        translatedCount: Int
    ) async throws -> [OpenAITranslationService.BatchResult] {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                if attempt > 0 {
                    report(.init(
                        stage: .translating,
                        scanned: snapshotCount,
                        candidates: candidateCount,
                        translated: translatedCount,
                        applied: 0,
                        failed: 0,
                        message: "Retrying translation chunk (attempt \(attempt + 1), \(items.count) titles)…"
                    ))
                }
                return try await client.translateBatch(model: model, items: items)
            } catch {
                attempt += 1
                if Self.isTimeoutLike(error), items.count > 20 {
                    report(.init(
                        stage: .translating,
                        scanned: snapshotCount,
                        candidates: candidateCount,
                        translated: translatedCount,
                        applied: 0,
                        failed: 0,
                        message: "Chunk timed out (\(items.count) titles). Splitting and retrying in smaller batches…"
                    ))
                    let split = max(10, items.count / 2)
                    let head = Array(items.prefix(split))
                    let tail = Array(items.dropFirst(split))
                    let first = try await Self.translateWithRetry(
                        client: client,
                        model: model,
                        items: head,
                        report: report,
                        snapshotCount: snapshotCount,
                        candidateCount: candidateCount,
                        translatedCount: translatedCount
                    )
                    let second = try await Self.translateWithRetry(
                        client: client,
                        model: model,
                        items: tail,
                        report: report,
                        snapshotCount: snapshotCount,
                        candidateCount: candidateCount,
                        translatedCount: translatedCount
                    )
                    return first + second
                }
                if attempt >= 3 {
                    throw error
                }
                let delay = UInt64(attempt * 400_000_000)
                report(.init(
                    stage: .translating,
                    scanned: snapshotCount,
                    candidates: candidateCount,
                    translated: translatedCount,
                    applied: 0,
                    failed: 0,
                    message: "Translation request failed (\(ErrorPresenter.short(error))). Retrying in \(String(format: "%.1f", Double(delay) / 1_000_000_000.0))s…"
                ))
                try await Task.sleep(nanoseconds: delay)
            }
        }
    }

    private static func isTimeoutLike(_ error: Error) -> Bool {
        if let codexError = error as? CodexCLITranslationService.ServiceError, case .timedOut = codexError {
            return true
        }
        if let runnerError = error as? ProcessRunner.RunnerError, case .timedOut = runnerError {
            return true
        }
        if let urlError = error as? URLError, urlError.code == .timedOut {
            return true
        }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == URLError.timedOut.rawValue {
            return true
        }
        return false
    }

    private func makeTranslationClient(config: TitleTranslationConfig) async throws -> any TitleTranslationProviderClient {
        switch config.provider {
        case .openAIAPI:
            let key = (config.openAIKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                throw NSError(
                    domain: "TitleNormalizationRunService",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "OpenAI API key is required."]
                )
            }
            return OpenAITranslationProviderClient(apiKey: key)
        case .codexCLI:
            let service = CodexCLITranslationService()
            try await service.validateEnvironment()
            return service
        }
    }

    private func shouldConsiderForTranslation(title: String, tags: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return false
        }

        let isASCIIOnly = trimmed.unicodeScalars.allSatisfy(\.isASCII)

        let lowerTags = Self.splitTags(tags).map { $0.lowercased() }
        let hasEnglishTag = lowerTags.contains("language:english")
        let hasTranslatedTag = lowerTags.contains("language:translated")
        if hasEnglishTag && !hasTranslatedTag {
            return false
        }

        if hasTranslatedTag && isASCIIOnly {
            return false
        }

        // Non-ASCII titles are always candidates.
        if !isASCIIOnly {
            return true
        }

        // If existing language tags mark non-English content, include it.
        if lowerTags.contains(where: { $0.hasPrefix("language:") && $0 != "language:english" && $0 != "language:translated" }) {
            return true
        }

        // Explicit original romanji tag implies non-English source title.
        if lowerTags.contains(where: { $0.hasPrefix("romanji_title:") }) {
            return true
        }

        // English+translated can still hold romanji titles; use tighter word-boundary checks.
        if Self.isLikelyRomanjiASCIITitle(trimmed) {
            return true
        }

        return false
    }

    private static func isLikelyRomanjiASCIITitle(_ title: String) -> Bool {
        let lower = title.lowercased()
        let words = asciiWords(lower)
        if words.isEmpty {
            return false
        }

        let highConfidenceHints: Set<String> = [
            "senpai", "sensei", "onee", "onii", "kanojo", "isekai", "maou", "yuusha"
        ]
        let weakHints: Set<String> = [
            "futanari", "doujin", "ecchi", "oppai", "seme", "uke"
        ]
        if words.contains(where: { highConfidenceHints.contains($0) }) {
            return true
        }

        let weakHintMatches = words.filter { weakHints.contains($0) }.count
        if weakHintMatches >= 2 {
            return true
        }

        let honorificSuffixes = ["chan", "kun", "sama", "san"]
        let hasHonorificSuffix = words.contains { word in
            honorificSuffixes.contains { suffix in
                word.count > suffix.count + 1 && word.hasSuffix(suffix)
            }
        }
        if hasHonorificSuffix {
            return true
        }

        if words.count < 2 {
            return false
        }

        return false
    }

    private static func asciiWords(_ value: String) -> [String] {
        value
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private static func normalizeLanguage(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch value {
        case "english":
            return "english"
        case "japanese":
            return "japanese"
        case "korean":
            return "korean"
        case "chinese":
            return "chinese"
        case "spanish":
            return "spanish"
        case "romanji", "romaji":
            return "romanji"
        default:
            return "other"
        }
    }

    private static func adjustTags(tags: String, originalTitle: String, detectedLanguage: String) -> String {
        var tokens = splitTags(tags)
        let lower = Set(tokens.map { $0.lowercased() })

        let hasAnyLanguageTag = tokens.contains { $0.lowercased().hasPrefix("language:") }
        let hasEnglishOrTranslated = lower.contains("language:english") || lower.contains("language:translated")

        if !hasAnyLanguageTag && !(hasEnglishOrTranslated && detectedLanguage == "romanji") {
            if let languageTag = languageTag(for: detectedLanguage) {
                tokens = addUnique(tag: languageTag, to: tokens)
            }
        }

        if let namespace = originalTitleNamespace(for: detectedLanguage) {
            let exists = tokens.contains { token in
                token.lowercased().hasPrefix("\(namespace.lowercased()):")
            }
            if !exists {
                tokens = addUnique(tag: "\(namespace):\(originalTitle)", to: tokens)
            }
        }

        return normalizeTags(tokens.joined(separator: ", "))
    }

    private static func languageTag(for detectedLanguage: String) -> String? {
        switch detectedLanguage {
        case "japanese":
            return "language:japanese"
        case "korean":
            return "language:korean"
        case "chinese":
            return "language:chinese"
        case "spanish":
            return "language:spanish"
        case "romanji":
            return "language:japanese"
        default:
            return nil
        }
    }

    private static func originalTitleNamespace(for detectedLanguage: String) -> String? {
        switch detectedLanguage {
        case "romanji":
            return "romanji_title"
        case "japanese", "korean", "chinese", "spanish":
            return "\(detectedLanguage)_title"
        default:
            return nil
        }
    }

    private static func splitTags(_ tags: String) -> [String] {
        tags
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func normalizeTags(_ tags: String) -> String {
        var seen: Set<String> = []
        var ordered: [String] = []

        for token in splitTags(tags) {
            let key = token.lowercased()
            if seen.insert(key).inserted {
                ordered.append(token)
            }
        }

        return ordered.joined(separator: ", ")
    }

    private static func addUnique(tag: String, to tags: [String]) -> [String] {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return tags }
        if tags.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return tags
        }
        return tags + [trimmed]
    }

    private func makeClient(profile: Profile) throws -> LANraragiClient {
        let account = "apiKey.\(profile.id.uuidString)"
        guard let apiKeyString = try KeychainService.getString(account: account) else {
            throw ArchiveLoader.ArchiveLoaderError.missingAPIKey
        }

        return LANraragiClient(configuration: .init(
            baseURL: profile.baseURL,
            apiKey: LANraragiAPIKey(apiKeyString),
            acceptLanguage: profile.language,
            maxConnectionsPerHost: AppSettings.maxConnectionsPerHost(defaultValue: 8)
        ))
    }

    private func chunkedCandidates(_ entries: [SnapshotEntry], maxItems: Int) -> [[SnapshotEntry]] {
        guard maxItems > 0 else { return [entries] }
        var chunks: [[SnapshotEntry]] = []
        chunks.reserveCapacity((entries.count / maxItems) + 1)

        var i = 0
        while i < entries.count {
            let end = min(entries.count, i + maxItems)
            chunks.append(Array(entries[i..<end]))
            i = end
        }
        return chunks
    }

    private func makeRunFileURL() throws -> URL {
        let root = AppPaths.cacheDirectory().appendingPathComponent("TitleNormalizationRuns", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("run-\(UUID().uuidString).jsonl")
    }

    private func countSelectedItems(in url: URL, onlyArcids: Set<String>?) throws -> Int {
        var count = 0
        try withPlanFileReader(url: url) { reader in
            while let item = try reader.nextItem() {
                if let onlyArcids, !onlyArcids.contains(item.arcid) {
                    continue
                }
                count += 1
            }
        }
        return count
    }

    private func forEachPlanItem(
        in url: URL,
        onlyArcids: Set<String>?,
        operation: @escaping @Sendable (TitleNormalizationPlan.Item) async throws -> Void
    ) async throws {
        let reader = try PlanFileReader(url: url)
        defer { try? reader.close() }

        while let item = try reader.nextItem() {
            try Task.checkCancellation()
            if let onlyArcids, !onlyArcids.contains(item.arcid) {
                continue
            }
            try await operation(item)
        }
    }

    private func withPlanFileReader<T>(url: URL, _ body: (PlanFileReader) throws -> T) throws -> T {
        let reader = try PlanFileReader(url: url)
        defer { try? reader.close() }
        return try body(reader)
    }
}

private final class PlanFileWriter {
    private let handle: FileHandle
    private let encoder = JSONEncoder()

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: Data())
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }

    func append(_ item: TitleNormalizationPlan.Item) throws {
        let data = try encoder.encode(item)
        try handle.write(contentsOf: data)
        try handle.write(contentsOf: Data([0x0A]))
    }

    func close() throws {
        try handle.close()
    }
}

private final class PlanFileReader {
    private let handle: FileHandle
    private var buffer = Data()
    private let decoder = JSONDecoder()
    private let chunkSize = 64 * 1024

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
    }

    func nextItem() throws -> TitleNormalizationPlan.Item? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                if let item = try decodeLine(line) {
                    return item
                }
                continue
            }

            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty {
                if buffer.isEmpty {
                    return nil
                }
                let final = buffer
                buffer.removeAll(keepingCapacity: false)
                return try decodeLine(final)
            }
            buffer.append(chunk)
        }
    }

    func close() throws {
        try handle.close()
    }

    private func decodeLine(_ line: Data) throws -> TitleNormalizationPlan.Item? {
        if line.isEmpty {
            return nil
        }
        if isWhitespaceOnly(line) {
            return nil
        }
        return try decoder.decode(TitleNormalizationPlan.Item.self, from: line)
    }

    private func isWhitespaceOnly(_ data: Data) -> Bool {
        data.allSatisfy { byte in
            byte == 0x20 || byte == 0x09 || byte == 0x0D || byte == 0x0A
        }
    }
}

private actor WorkQueue<T: Sendable> {
    private let items: [T]
    private var index: Int = 0

    init(items: [T]) {
        self.items = items
    }

    func next() -> T? {
        guard index < items.count else { return nil }
        let item = items[index]
        index += 1
        return item
    }
}

private actor FailureCollector {
    private var items: [TitleNormalizationApplyResult.Failure] = []

    func append(_ item: TitleNormalizationApplyResult.Failure) {
        items.append(item)
    }

    func values() -> [TitleNormalizationApplyResult.Failure] {
        items
    }
}

private actor ScanCounter {
    private let total: Int
    private var scanned: Int = 0

    init(total: Int) {
        self.total = total
    }

    func bump() -> TitleNormalizationProgress? {
        scanned += 1
        if scanned % 25 == 0 || scanned == total {
            return .init(
                stage: .scanning,
                scanned: scanned,
                candidates: 0,
                translated: 0,
                applied: 0,
                failed: 0,
                message: "Scanned \(scanned)/\(total) archives."
            )
        }
        return nil
    }
}

private actor ProgressCounter {
    private let total: Int
    private var applied: Int = 0
    private var failed: Int = 0

    init(total: Int) {
        self.total = total
    }

    func markApplied() -> TitleNormalizationProgress {
        applied += 1
        return .init(
            stage: .applying,
            scanned: 0,
            candidates: total,
            translated: total,
            applied: applied,
            failed: failed,
            message: "Applied \(applied + failed)/\(total)."
        )
    }

    func markFailed(reason: String) -> TitleNormalizationProgress {
        _ = reason
        failed += 1
        return .init(
            stage: .applying,
            scanned: 0,
            candidates: total,
            translated: total,
            applied: applied,
            failed: failed,
            message: "Applied \(applied + failed)/\(total) with failures."
        )
    }
}
