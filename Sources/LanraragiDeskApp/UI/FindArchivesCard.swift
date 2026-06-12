import Foundation
import SwiftUI
import LanraragiKit

// MARK: - Find Archives card

struct FindArchivesCard: View {
    @EnvironmentObject private var appModel: AppModel
    let profile: Profile

    @AppStorage("batch.findArchives.expanded") private var expanded: Bool = false
    @State private var conditions: [BatchQueryCondition] = []
    @State private var categories: [LanraragiKit.Category] = []
    @State private var searchStatus: SearchStatus = .idle
    @State private var selectedResultIDs: Set<String> = []
    @State private var showSaveSheet: Bool = false
    @State private var saveNameDraft: String = ""
    @State private var selectedSavedQueryID: UUID? = nil
    @State private var searchTask: Task<Void, Never>? = nil

    enum SearchStatus {
        case idle
        case loading
        case results([String])
        case failed(String)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach($conditions) { $condition in
                    ConditionRowView(
                        condition: $condition,
                        categories: categories,
                        onRemove: { conditions.removeAll { $0.id == condition.id } }
                    )
                }

                HStack(spacing: 8) {
                    Text("Main page searches")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    mainPageSearchPresetButton(kind: .newArchives)
                    mainPageSearchPresetButton(kind: .untaggedArchives)

                    Spacer()
                }

                HStack {
                    let hasCategoryCondition = conditions.contains { $0.type == .serverCategory }
                    Menu {
                        ForEach(BatchQueryCondition.ConditionType.allCases, id: \.self) { type in
                            Button(type.label) {
                                conditions.append(BatchQueryCondition(type: type))
                            }
                            .disabled(type == .serverCategory && hasCategoryCondition)
                        }
                    } label: {
                        Label("Add Condition", systemImage: "plus")
                    }
                    .fixedSize()

                    Spacer()

                    Button("Search") {
                        searchTask?.cancel()
                        searchStatus = .loading
                        searchTask = Task { await runSearch() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(conditions.isEmpty)
                }

                Divider()

                Text("Saved Queries")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                let profileQueries = appModel.savedQueryStore.queries(for: profile.id)
                HStack(spacing: 8) {
                    Picker("Saved query", selection: $selectedSavedQueryID) {
                        Text("Select a query").tag(Optional<UUID>.none)
                        ForEach(profileQueries) { q in
                            Text(q.name).tag(Optional(q.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()

                    Button("Load") {
                        if let id = selectedSavedQueryID,
                           let q = profileQueries.first(where: { $0.id == id }) {
                            conditions = q.conditions
                        }
                    }
                    .disabled(selectedSavedQueryID == nil)

                    Button("Save as…") {
                        saveNameDraft = ""
                        showSaveSheet = true
                    }
                    .disabled(conditions.isEmpty)

                    Button("Delete", role: .destructive) {
                        if let id = selectedSavedQueryID {
                            appModel.savedQueryStore.delete(id: id)
                            selectedSavedQueryID = nil
                        }
                    }
                    .disabled(selectedSavedQueryID == nil)
                }

                switch searchStatus {
                case .idle:
                    EmptyView()
                case .loading:
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.7)
                        Text("Searching…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                case .failed(let msg):
                    Text("Search failed: \(msg)")
                        .font(.caption)
                        .foregroundStyle(.red)
                case .results(let arcids):
                    Divider()
                    HStack {
                        Text("Results: \(arcids.count) archives")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Add \(selectedResultIDs.count) to Selection") {
                            appModel.selection.add(selectedResultIDs)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(selectedResultIDs.isEmpty)
                    }
                    HStack(spacing: 12) {
                        Button("Select all") { selectedResultIDs = Set(arcids) }
                            .buttonStyle(.bordered)
                            .font(.caption)
                        Button("Select none") { selectedResultIDs.removeAll() }
                            .buttonStyle(.bordered)
                            .font(.caption)
                        Spacer()
                    }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(arcids, id: \.self) { arcid in
                                QueryResultRowView(
                                    profile: profile,
                                    arcid: arcid,
                                    isSelected: Binding(
                                        get: { selectedResultIDs.contains(arcid) },
                                        set: { checked in
                                            if checked {
                                                selectedResultIDs.insert(arcid)
                                            } else {
                                                selectedResultIDs.remove(arcid)
                                            }
                                        }
                                    )
                                )
                            }
                        }
                    }
                    .frame(maxHeight: 260)
                }
            }
            .padding(.top, 8)
        } label: {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Text("Find Archives")
                        .font(.headline)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .task(id: profile.id) {
            await loadCategories()
        }
        .sheet(isPresented: $showSaveSheet) {
            VStack(spacing: 14) {
                Text("Save Query")
                    .font(.headline)
                TextField("Query name", text: $saveNameDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 260)
                HStack {
                    Button("Cancel") { showSaveSheet = false }
                    Spacer()
                    Button("Save") {
                        let q = SavedBatchQuery(
                            name: saveNameDraft.trimmingCharacters(in: .whitespacesAndNewlines),
                            profileID: profile.id,
                            conditions: conditions
                        )
                        appModel.savedQueryStore.save(q)
                        selectedSavedQueryID = q.id
                        showSaveSheet = false
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(saveNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(20)
        }
        .onDisappear {
            searchTask?.cancel()
        }
    }

    private func applyMainPageSearch(_ kind: MainPageCarouselKind) {
        let target = kind.batchConditionType
        let hasTarget = conditions.contains { $0.type == target }
        conditions.removeAll { $0.type == .newOnly || $0.type == .untaggedOnly }
        if !hasTarget {
            conditions.append(BatchQueryCondition(type: target))
        }
    }

    @ViewBuilder
    private func mainPageSearchPresetButton(kind: MainPageCarouselKind) -> some View {
        let isActive = conditions.contains { $0.type == kind.batchConditionType }
        Button {
            applyMainPageSearch(kind)
        } label: {
            Text(kind.title)
                .font(.caption)
                .foregroundStyle(.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(isActive ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06))
                .clipShape(Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(
                            isActive ? Color.accentColor.opacity(0.45) : Color(nsColor: .separatorColor).opacity(0.45),
                            lineWidth: 1
                        )
                }
        }
        .buttonStyle(.plain)
    }

    private func loadCategories() async {
        let account = "apiKey.\(profile.id.uuidString)"
        let apiKeyString = (try? KeychainService.getString(account: account)) ?? nil
        let apiKey = apiKeyString.map { LANraragiAPIKey($0) }

        let client = LANraragiClient(configuration: .init(
            baseURL: profile.baseURL,
            apiKey: apiKey,
            acceptLanguage: profile.language,
            maxConnectionsPerHost: AppSettings.maxConnectionsPerHost(defaultValue: 8)
        ))

        do {
            let resp = try await client.listCategories()
            if Task.isCancelled { return }
            let cleaned = resp
                .map { LanraragiKit.Category(id: $0.id.trimmingCharacters(in: .whitespacesAndNewlines),
                                              name: $0.name.trimmingCharacters(in: .whitespacesAndNewlines),
                                              pinned: $0.pinned) }
                .filter { !$0.id.isEmpty && !$0.name.isEmpty }
            categories = cleaned.sorted { a, b in
                if a.pinned != b.pinned { return a.pinned && !b.pinned }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        } catch {
            if Task.isCancelled { return }
            categories = []
        }
    }

    private func runSearch() async {
        let compiled = BatchQueryCompiler.compile(conditions)

        let account = "apiKey.\(profile.id.uuidString)"
        let apiKeyString = (try? KeychainService.getString(account: account)) ?? nil
        let apiKey = apiKeyString.map { LANraragiAPIKey($0) }

        let client = LANraragiClient(configuration: .init(
            baseURL: profile.baseURL,
            apiKey: apiKey,
            acceptLanguage: profile.language,
            maxConnectionsPerHost: AppSettings.maxConnectionsPerHost(defaultValue: 8)
        ))

        var allIDs: [String] = []
        var start = 0

        do {
            while true {
                if Task.isCancelled { return }
                let resp = try await client.search(
                    start: start,
                    filter: compiled.filter,
                    category: compiled.categoryID,
                    newOnly: compiled.newOnly,
                    untaggedOnly: compiled.untaggedOnly,
                    sortBy: "title",
                    order: "asc"
                )
                let ids = resp.data.map(\.arcid)
                allIDs.append(contentsOf: ids)
                start += ids.count
                if allIDs.count >= resp.recordsFiltered || ids.isEmpty { break }
            }
            if Task.isCancelled { return }
            searchStatus = .results(allIDs)
            selectedResultIDs = Set(allIDs)
        } catch {
            if Task.isCancelled { return }
            searchStatus = .failed(ErrorPresenter.short(error))
        }
    }
}

private struct ConditionRowView: View {
    @Binding var condition: BatchQueryCondition
    let categories: [LanraragiKit.Category]
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Picker("Type", selection: $condition.type) {
                ForEach(BatchQueryCondition.ConditionType.allCases, id: \.self) { type in
                    Text(type.label).tag(type)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()

            if condition.type.needsNamespace {
                TextField("namespace", text: $condition.namespace)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
            }

            if condition.type.needsValue {
                Text("=")
                    .foregroundStyle(.secondary)
                TextField("value", text: $condition.value)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
            }

            if condition.type.needsCategory {
                Picker("Category", selection: $condition.categoryID) {
                    Text("Select category").tag("")
                    ForEach(categories, id: \.id) { cat in
                        Text(cat.name).tag(cat.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .onChange(of: condition.categoryID) { _, newID in
                    if let cat = categories.first(where: { $0.id == newID }) {
                        condition.categoryName = cat.name
                    }
                }
            }

            Spacer()

            Button(role: .destructive) {
                onRemove()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
    }
}

private struct QueryResultRowView: View {
    @EnvironmentObject private var appModel: AppModel
    let profile: Profile
    let arcid: String
    @Binding var isSelected: Bool
    @State private var title: String = ""

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: $isSelected).labelsHidden()
            CoverThumb(
                profile: profile,
                arcid: arcid,
                thumbnails: appModel.thumbnails,
                size: .init(width: 36, height: 46),
                contentInset: 0,
                showsBorder: false
            )
            Text(title.isEmpty ? arcid : title)
                .font(.callout)
                .lineLimit(1)
            Spacer()
        }
        .task(id: arcid) {
            if let meta = try? await appModel.archives.metadata(profile: profile, arcid: arcid) {
                title = meta.title ?? arcid
            }
        }
    }
}
