import AppKit
import SwiftUI
import LanraragiKit

struct StatisticsView: View {
    @EnvironmentObject private var appModel: AppModel
    let profile: Profile

    @State private var minWeight: Int = 2
    @State private var filterText: String = ""
    @State private var isLoading: Bool = false
    @State private var statusText: String?
    @State private var serverInfo: ServerInfo?

    @State private var allWords: [Word] = []
    @State private var detailedWords: [Word] = []
    @State private var minObservedWeight: Int = 0
    @State private var maxObservedWeight: Int = 1
    @State private var renderedCloudCount: Int = 0
    @State private var renderedDetailCount: Int = 0
    @State private var stageTask: Task<Void, Never>?

    @State private var showDetailedStats: Bool = false

    private let maxRenderableCloudWords: Int = 2500
    private let maxRenderableDetailWords: Int = 8000
    private let firstCloudBatchSize: Int = 220
    private let firstDetailBatchSize: Int = 320
    private let stageCloudBatchSize: Int = 220
    private let stageDetailBatchSize: Int = 320

    struct Word: Identifiable, Hashable {
        let id: String
        let namespace: String
        let text: String
        let tag: String
        let weight: Int
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if isLoading && allWords.isEmpty {
                ProgressView("Loading tag statistics…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            } else if allWords.isEmpty {
                ContentUnavailableView(
                    "No Statistics Yet",
                    systemImage: "chart.bar.xaxis",
                    description: Text(statusText ?? "Press Refresh to load tag statistics from your server.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 14) {
                        statsHeaderCard
                        cloudSection
                        detailedSection
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                }
                .scrollIndicators(.visible)
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(18)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .task(id: profile.id) {
            let defaults = UserDefaults.standard
            if defaults.object(forKey: "tags.minWeight") == nil {
                minWeight = 2
                defaults.set(2, forKey: "tags.minWeight")
            } else {
                minWeight = max(0, defaults.integer(forKey: "tags.minWeight"))
            }
            await refresh()
        }
        .onDisappear {
            stageTask?.cancel()
            stageTask = nil
        }
        .onChange(of: showDetailedStats) { _, expanded in
            guard expanded else { return }
            let detailCap = min(detailedWords.count, maxRenderableDetailWords)
            if renderedDetailCount == 0 && detailCap > 0 {
                renderedDetailCount = min(firstDetailBatchSize, detailCap)
            }
            stageRender()
        }
        .debugFrameNumber(1)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Statistics")
                .font(.title2)
                .bold()

            Spacer()

            Stepper("Min weight: \(minWeight)", value: $minWeight, in: 0...999)
                .frame(width: 180, alignment: .trailing)
                .disabled(isLoading)
                .onChange(of: minWeight) { _, v in
                    UserDefaults.standard.set(max(0, v), forKey: "tags.minWeight")
                    Task { await refresh() }
                }

            TextField("Filter tags…", text: $filterText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .disabled(isLoading)

            Button("Refresh") {
                Task { await refresh() }
            }
            .disabled(isLoading)
        }
    }

    private var statsHeaderCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 18) {
                StatPill(systemImage: "books.vertical.fill", title: "Archives", value: serverInfo?.total_archives.map(String.init) ?? "—")
                StatPill(systemImage: "tags.fill", title: "Different tags", value: String(allWords.count))
                StatPill(systemImage: "book.fill", title: "Pages read", value: serverInfo?.total_pages_read.map(String.init) ?? "—")
                Spacer()
            }

            let cloudRendered = min(renderedCloudCount, min(allWords.count, maxRenderableCloudWords))
            Text("Tag cloud: showing \(cloudVisibleWords.count) tags (\(cloudRendered) rendered of \(allWords.count) total).")
                .font(.caption)
                .foregroundStyle(.secondary)

            if allWords.count > maxRenderableCloudWords && filterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Cloud rendering is capped to \(maxRenderableCloudWords) tags for responsiveness.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let statusText, !statusText.isEmpty {
                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var cloudSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tag Cloud")
                .font(.headline)

            if cloudVisibleWords.isEmpty {
                Text("No tags to display.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                FlowLayout(spacing: 7, lineSpacing: 7) {
                    ForEach(cloudVisibleWords) { word in
                        Button {
                            openTagSearch(word)
                        } label: {
                            Text(word.tag)
                                .font(.system(size: fontSize(for: word.weight), weight: .semibold, design: .rounded))
                                .foregroundStyle(tint(forNamespace: word.namespace))
                        }
                        .buttonStyle(.plain)
                        .help("\(word.tag) (\(word.weight))")
                    }
                }
            }
        }
    }

    private var detailedSection: some View {
        Group {
            if !detailedWords.isEmpty {
                DisclosureGroup("Detailed Stats", isExpanded: $showDetailedStats) {
                    VStack(alignment: .leading, spacing: 10) {
                        if detailedVisibleWords.isEmpty {
                            Text("No matching tags.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
                                ForEach(detailedVisibleWords) { word in
                                    Button {
                                        openTagSearch(word)
                                    } label: {
                                        HStack(spacing: 8) {
                                            Text(word.tag)
                                                .lineLimit(nil)
                                                .fixedSize(horizontal: false, vertical: true)
                                                .frame(maxWidth: .infinity, alignment: .leading)

                                            Text("(\(word.weight))")
                                                .font(.caption.monospacedDigit().weight(.bold))
                                                .foregroundStyle(.secondary)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .buttonStyle(.plain)
                                    .help("\(word.tag) (\(word.weight))")
                                }
                            }
                        }

                        Text("(Detailed stats exclude namespaces `source` and `date_added`, matching LANraragi stats.)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)
                }
            }
        }
    }

    private var cloudVisibleWords: [Word] {
        let needle = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if needle.isEmpty {
            let limit = min(renderedCloudCount, min(allWords.count, maxRenderableCloudWords))
            return Array(allWords.prefix(limit))
        }
        let matched = allWords.lazy.filter { $0.tag.lowercased().contains(needle) }
        return Array(matched.prefix(maxRenderableCloudWords))
    }

    private var detailedVisibleWords: [Word] {
        guard showDetailedStats else { return [] }
        let needle = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if needle.isEmpty {
            let limit = min(renderedDetailCount, min(detailedWords.count, maxRenderableDetailWords))
            return Array(detailedWords.prefix(limit))
        }
        let matched = detailedWords.lazy.filter { $0.tag.lowercased().contains(needle) }
        return Array(matched.prefix(maxRenderableDetailWords))
    }

    private func refresh() async {
        stageTask?.cancel()
        stageTask = nil

        isLoading = true
        statusText = "Loading…"
        defer { isLoading = false }

        do {
            let account = "apiKey.\(profile.id.uuidString)"
            let apiKeyString = try KeychainService.getString(account: account)
            let apiKey = apiKeyString.map { LANraragiAPIKey($0) }

            let client = LANraragiClient(configuration: .init(
                baseURL: profile.baseURL,
                apiKey: apiKey,
                acceptLanguage: profile.language,
                maxConnectionsPerHost: AppSettings.maxConnectionsPerHost(defaultValue: 8)
            ))

            async let statsReq = client.getDatabaseStats(minWeight: minWeight)
            async let infoReq = client.getServerInfo()

            let loaded = try await statsReq
            let info = try? await infoReq

            let mapped = mapWords(from: loaded.tags)
            allWords = mapped.words
            detailedWords = mapped.words.filter { $0.namespace != "source" && $0.namespace != "date_added" }
            minObservedWeight = mapped.minWeight
            maxObservedWeight = mapped.maxWeight
            serverInfo = info

            renderedCloudCount = min(firstCloudBatchSize, min(allWords.count, maxRenderableCloudWords))
            if showDetailedStats {
                renderedDetailCount = min(firstDetailBatchSize, min(detailedWords.count, maxRenderableDetailWords))
            } else {
                renderedDetailCount = 0
            }

            statusText = "Loaded \(allWords.count) tags."
            appModel.activity.add(.init(kind: .action, title: "Loaded statistics", detail: "tags \(allWords.count)"))

            stageRender()
        } catch {
            allWords = []
            detailedWords = []
            renderedCloudCount = 0
            renderedDetailCount = 0
            statusText = "Failed: \(ErrorPresenter.short(error))"
            appModel.activity.add(.init(kind: .error, title: "Statistics load failed", detail: String(describing: error)))
        }
    }

    private func stageRender() {
        stageTask?.cancel()
        let cloudCap = min(allWords.count, maxRenderableCloudWords)
        let detailCap = min(detailedWords.count, maxRenderableDetailWords)
        let cloudPending = renderedCloudCount < cloudCap
        let detailPending = showDetailedStats && renderedDetailCount < detailCap
        guard cloudPending || detailPending else { return }

        stageTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 90_000_000)
                if Task.isCancelled { return }
                await MainActor.run {
                    if renderedCloudCount < cloudCap {
                        renderedCloudCount = min(cloudCap, renderedCloudCount + stageCloudBatchSize)
                    }
                    if showDetailedStats && renderedDetailCount < detailCap {
                        renderedDetailCount = min(detailCap, renderedDetailCount + stageDetailBatchSize)
                    }
                }
                let detailDone = !showDetailedStats || renderedDetailCount >= detailCap
                if renderedCloudCount >= cloudCap && detailDone {
                    return
                }
            }
        }
    }

    private func mapWords(from tags: [TagStat]) -> (words: [Word], minWeight: Int, maxWeight: Int) {
        var out: [Word] = []
        out.reserveCapacity(tags.count)

        var seen: Set<String> = []
        var minW = Int.max
        var maxW = Int.min

        for t in tags {
            let ns = (t.namespace ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let tx = (t.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let tag: String = {
                if !ns.isEmpty, !tx.isEmpty { return "\(ns):\(tx)" }
                return tx
            }()
            if tag.isEmpty { continue }
            if !seen.insert(tag).inserted { continue }

            let weight = max(0, t.weight ?? t.count ?? 0)
            minW = min(minW, weight)
            maxW = max(maxW, weight)

            out.append(Word(id: tag, namespace: ns, text: tx, tag: tag, weight: weight))
        }

        out.sort { a, b in
            if a.weight != b.weight { return a.weight > b.weight }
            return a.tag.localizedCaseInsensitiveCompare(b.tag) == .orderedAscending
        }

        if minW == Int.max { minW = 0 }
        if maxW == Int.min { maxW = 1 }
        return (out, minW, maxW)
    }

    private func fontSize(for weight: Int) -> CGFloat {
        if maxObservedWeight <= minObservedWeight {
            return 13
        }
        let t = CGFloat(weight - minObservedWeight) / CGFloat(maxObservedWeight - minObservedWeight)
        return 11 + (24 * sqrt(max(0, min(1, t))))
    }

    private func tint(forNamespace namespace: String) -> Color {
        switch namespace {
        case "artist": return .blue
        case "group": return .orange
        case "character": return .pink
        case "series": return .indigo
        case "language": return .green
        case "source": return .teal
        default: return .primary
        }
    }

    private func openTagSearch(_ word: Word) {
        let token = word.namespace.isEmpty ? word.text : "\(word.namespace):\(word.text)"
        guard !token.isEmpty else { return }

        guard var comps = URLComponents(url: profile.baseURL, resolvingAgainstBaseURL: false) else { return }
        if comps.path.isEmpty { comps.path = "/" }
        comps.queryItems = [URLQueryItem(name: "filter", value: token)]

        if let url = comps.url {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct StatPill: View {
    let systemImage: String
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.headline.monospacedDigit())
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
