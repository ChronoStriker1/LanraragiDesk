import SwiftUI
import LanraragiKit

struct StatisticsView: View {
    @EnvironmentObject private var appModel: AppModel
    let profile: Profile

    @State private var minWeight: Int = 1
    @State private var filterText: String = ""
    @State private var isLoading: Bool = false
    @State private var statusText: String?
    @State private var stats: DatabaseStats?

    @State private var sortOrder: [KeyPathComparator<TagRow>] = [
        .init(\.count, order: .reverse),
        .init(\.tag, order: .forward),
    ]

    struct TagRow: Identifiable, Hashable {
        let id: String
        let tag: String
        let count: Int
        let weight: Int
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if let stats, !rows(for: stats).isEmpty {
                Table(sortedRows(for: stats), sortOrder: $sortOrder) {
                    TableColumn("Tag", value: \.tag) { row in
                        Text(row.tag)
                            .textSelection(.enabled)
                    }
                    TableColumn("Count", value: \.count) { row in
                        Text(row.count == 0 ? "" : String(row.count))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 80, ideal: 90, max: 110)

                    TableColumn("Weight", value: \.weight) { row in
                        Text(row.weight == 0 ? "" : String(row.weight))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 80, ideal: 90, max: 110)
                }
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            } else if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            } else {
                ContentUnavailableView(
                    "No Statistics Yet",
                    systemImage: "chart.bar.xaxis",
                    description: Text(statusText ?? "Press Refresh to load tag statistics from your server.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                .frame(width: 240)
                .disabled(isLoading)

            Button("Refresh") {
                Task { await refresh() }
            }
            .disabled(isLoading)
        }
    }

    private func sortedRows(for stats: DatabaseStats) -> [TagRow] {
        rows(for: stats).sorted(using: sortOrder)
    }

    private func rows(for stats: DatabaseStats) -> [TagRow] {
        let needle = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        var out: [TagRow] = []
        out.reserveCapacity(stats.tags.count)

        for t in stats.tags {
            let ns = (t.namespace ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let tx = (t.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let tag: String = {
                if !ns.isEmpty, !tx.isEmpty { return "\(ns):\(tx)" }
                return tx
            }()
            if tag.isEmpty { continue }
            if !needle.isEmpty, !tag.lowercased().contains(needle) { continue }

            out.append(TagRow(
                id: tag,
                tag: tag,
                count: t.count ?? 0,
                weight: t.weight ?? 0
            ))
        }

        return out
    }

    private func refresh() async {
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
            stats = loaded
            statusText = "Loaded \(loaded.tags.count) tags."
            appModel.activity.add(.init(kind: .action, title: "Loaded statistics", detail: "tags \(loaded.tags.count)"))
        } catch {
            stats = nil
            statusText = "Failed: \(ErrorPresenter.short(error))"
            appModel.activity.add(.init(kind: .error, title: "Statistics load failed", detail: String(describing: error)))
        }
    }
}

