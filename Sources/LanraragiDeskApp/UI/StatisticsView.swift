import SwiftUI
import LanraragiKit

struct StatisticsView: View {
    @EnvironmentObject private var appModel: AppModel
    let profile: Profile

    @State private var minWeight: Int = 1
    @State private var filterText: String = ""
    @State private var isLoading: Bool = false
    @State private var statusText: String?

    @State private var allWords: [Word] = []
    @State private var minObservedWeight: Int = 0
    @State private var maxObservedWeight: Int = 1
    @State private var renderedCount: Int = 0
    @State private var stageTask: Task<Void, Never>?

    private let maxRenderableWords: Int = 2500
    private let firstBatchSize: Int = 220
    private let stageBatchSize: Int = 220

    struct Word: Identifiable, Hashable {
        let id: String
        let namespace: String
        let tag: String
        let weight: Int
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if isLoading {
                ProgressView("Loading tag statistics…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            } else if visibleWords.isEmpty {
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
                    VStack(alignment: .leading, spacing: 12) {
                        statsSummary

                        FlowLayout(spacing: 8, lineSpacing: 8) {
                            ForEach(visibleWords) { word in
                                StatisticsWordChip(
                                    text: word.tag,
                                    weight: word.weight,
                                    fontSize: fontSize(for: word.weight),
                                    tint: tint(forNamespace: word.namespace)
                                )
                            }
                        }
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
            minWeight = max(0, UserDefaults.standard.integer(forKey: "tags.minWeight"))
            await refresh()
        }
        .onDisappear {
            stageTask?.cancel()
            stageTask = nil
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
                .frame(width: 260)
                .disabled(isLoading)

            Button("Refresh") {
                Task { await refresh() }
            }
            .disabled(isLoading)
        }
    }

    private var statsSummary: some View {
        let total = allWords.count
        let visible = visibleWords.count
        let rendered = min(renderedCount, min(total, maxRenderableWords))
        return VStack(alignment: .leading, spacing: 4) {
            Text("Tag cloud")
                .font(.headline)
            Text("Showing \(visible) tags (\(rendered) rendered of \(total) total).")
                .font(.caption)
                .foregroundStyle(.secondary)
            if total > maxRenderableWords && filterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Rendering is capped to \(maxRenderableWords) tags for responsiveness.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var visibleWords: [Word] {
        let needle = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if needle.isEmpty {
            let limit = min(renderedCount, min(allWords.count, maxRenderableWords))
            return Array(allWords.prefix(limit))
        }
        let matched = allWords.lazy.filter { $0.tag.lowercased().contains(needle) }
        return Array(matched.prefix(maxRenderableWords))
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

            let loaded = try await client.getDatabaseStats(minWeight: minWeight)
            let mapped = mapWords(from: loaded.tags)
            allWords = mapped.words
            minObservedWeight = mapped.minWeight
            maxObservedWeight = mapped.maxWeight
            renderedCount = min(firstBatchSize, min(allWords.count, maxRenderableWords))
            statusText = "Loaded \(allWords.count) tags."
            appModel.activity.add(.init(kind: .action, title: "Loaded statistics", detail: "tags \(allWords.count)"))

            stageRender()
        } catch {
            allWords = []
            renderedCount = 0
            statusText = "Failed: \(ErrorPresenter.short(error))"
            appModel.activity.add(.init(kind: .error, title: "Statistics load failed", detail: String(describing: error)))
        }
    }

    private func stageRender() {
        stageTask?.cancel()
        let cap = min(allWords.count, maxRenderableWords)
        guard renderedCount < cap else { return }

        stageTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 90_000_000)
                if Task.isCancelled { return }
                await MainActor.run {
                    renderedCount = min(cap, renderedCount + stageBatchSize)
                }
                if renderedCount >= cap { return }
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
            let ns = (t.namespace ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
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

            out.append(Word(id: tag, namespace: ns.lowercased(), tag: tag, weight: weight))
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
        // Similar spirit to jQCloud classes: smaller floor, larger cap.
        return 11 + (26 * sqrt(max(0, min(1, t))))
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
}

private struct StatisticsWordChip: View {
    let text: String
    let weight: Int
    let fontSize: CGFloat
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Text(text)
                .font(.system(size: fontSize, weight: .semibold, design: .rounded))
                .lineLimit(nil)
                .multilineTextAlignment(.leading)
            Text("(\(weight))")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.28))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
