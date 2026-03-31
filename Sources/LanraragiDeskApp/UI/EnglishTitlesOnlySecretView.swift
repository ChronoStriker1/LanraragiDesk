import SwiftUI

@MainActor
final class EnglishTitlesOnlyViewModel: ObservableObject {
    enum ApplyMode {
        case all
        case failedOnly
    }

    @Published var openAIKey: String = ""
    @Published var selectedProvider: TitleTranslationProvider
    @Published var selectedModel: String
    @Published var availableModels: [String]
    @Published var isBusy: Bool = false
    @Published var statusText: String?
    @Published var modelStatusText: String?
    @Published var providerStatusText: String?
    @Published var progress = TitleNormalizationProgress(stage: .finished, scanned: 0, candidates: 0, translated: 0, applied: 0, failed: 0, message: "Idle")
    @Published var plan: TitleNormalizationPlan?
    @Published var failures: [TitleNormalizationApplyResult.Failure] = []
    @Published var eventLog: [String] = []

    private let runService = TitleNormalizationRunService()
    private let translationService = OpenAITranslationService()
    private let codexService = CodexCLITranslationService()
    private var activeTask: Task<Void, Never>?
    private static let openAIKeyAccount = "openai.apiKey"
    private static let providerDefaultsKey = "secret.englishTitlesOnly.provider"
    private static let modelDefaultsKey = "secret.englishTitlesOnly.model"
    private static let openAIBuiltInModels: [String] = [
        "gpt-5.4-mini",
        "gpt-5.4-nano"
    ]
    private static let codexBuiltInModels: [String] = [
        "gpt-5.4",
        "gpt-5.4-mini",
        "gpt-5-codex",
        "gpt-5.2-codex"
    ]

    init() {
        let persistedProvider = TitleTranslationProvider(rawValue: UserDefaults.standard.string(forKey: Self.providerDefaultsKey) ?? "") ?? .openAIAPI
        let persistedModel = UserDefaults.standard.string(forKey: Self.modelDefaultsKey) ?? Self.defaultModel(for: persistedProvider)
        let initialModel = Self.sanitizedModel(persistedModel, for: persistedProvider)
        self.selectedProvider = persistedProvider
        self.selectedModel = initialModel
        self.availableModels = Self.normalizedModels(Self.builtInModels(for: persistedProvider), including: initialModel)
    }

    var requiresOpenAIKey: Bool {
        selectedProvider == .openAIAPI
    }

    func loadPersistedState() {
        if let key = try? KeychainService.getString(account: Self.openAIKeyAccount) {
            openAIKey = key
        }
        selectedModel = Self.sanitizedModel(selectedModel, for: selectedProvider)
        UserDefaults.standard.set(selectedModel, forKey: Self.modelDefaultsKey)
        availableModels = Self.normalizedModels(Self.builtInModels(for: selectedProvider), including: selectedModel)
    }

    func updateModel(_ value: String) {
        selectedModel = value
        UserDefaults.standard.set(value, forKey: Self.modelDefaultsKey)
        availableModels = Self.normalizedModels(availableModels, including: value)
    }

    func updateProvider(_ value: TitleTranslationProvider) {
        selectedProvider = value
        UserDefaults.standard.set(value.rawValue, forKey: Self.providerDefaultsKey)
        modelStatusText = nil
        providerStatusText = nil
        selectedModel = Self.sanitizedModel(selectedModel, for: value)
        UserDefaults.standard.set(selectedModel, forKey: Self.modelDefaultsKey)
        availableModels = Self.normalizedModels(Self.builtInModels(for: value), including: selectedModel)
    }

    func refreshModels() async {
        guard selectedProvider == .openAIAPI else {
            modelStatusText = "Model refresh is only available in OpenAI API mode."
            return
        }

        let key = openAIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            availableModels = Self.normalizedModels(Self.builtInModels(for: .openAIAPI), including: selectedModel)
            modelStatusText = "Enter an OpenAI API key to load account models. Showing the built-in catalog."
            return
        }

        modelStatusText = "Loading models from OpenAI…"
        do {
            let models = try await translationService.availableModelIDs(apiKey: key)
            availableModels = Self.normalizedModels(Self.builtInModels(for: .openAIAPI) + models, including: selectedModel)
            modelStatusText = "Loaded \(availableModels.count) models from the built-in catalog and OpenAI."
        } catch {
            availableModels = Self.normalizedModels(Self.builtInModels(for: .openAIAPI), including: selectedModel)
            modelStatusText = "Failed to load models from OpenAI. Showing the built-in catalog. \(ErrorPresenter.short(error))"
        }
    }

    func checkCodex() async {
        providerStatusText = "Checking Codex…"
        do {
            try await codexService.validateEnvironment()
            providerStatusText = "Codex is installed and logged in."
        } catch {
            providerStatusText = ErrorPresenter.short(error)
        }
    }

    func cancel() {
        activeTask?.cancel()
        activeTask = nil
        isBusy = false
        statusText = "Cancelled."
        appendLog("Cancelled by user.")
    }

    func startDryRun(profile: Profile) {
        guard !isBusy else { return }

        let translationConfig: TitleTranslationConfig
        switch selectedProvider {
        case .openAIAPI:
            let key = openAIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                statusText = "OpenAI API key is required."
                return
            }
            do {
                try KeychainService.setString(key, account: Self.openAIKeyAccount)
            } catch {
                statusText = "Failed to save OpenAI key: \(ErrorPresenter.short(error))"
                return
            }
            translationConfig = .init(provider: .openAIAPI, model: selectedModel, openAIKey: key)
        case .codexCLI:
            translationConfig = .init(provider: .codexCLI, model: selectedModel, openAIKey: nil)
        }

        isBusy = true
        statusText = "Starting dry run…"
        plan = nil
        failures = []
        eventLog = []
        appendLog("Dry run started with \(selectedProvider.displayName) using model \(selectedModel).")
        progress = .init(stage: .scanning, scanned: 0, candidates: 0, translated: 0, applied: 0, failed: 0, message: "Preparing…")

        activeTask = Task { [weak self] in
            guard let self else { return }
            defer {
                Task { @MainActor in
                    self.isBusy = false
                    self.activeTask = nil
                }
            }

            do {
                let plan = try await self.runService.buildPlan(
                    profile: profile,
                    translationConfig: translationConfig,
                    report: { update in
                        Task { @MainActor [weak self] in
                            self?.progress = update
                            self?.statusText = update.message
                            self?.appendLog(update.message)
                        }
                    }
                )

                await MainActor.run {
                    self.plan = plan
                    self.statusText = "Dry run complete. \(plan.itemCount) archives would be updated."
                    self.appendLog("Dry run complete. Planned updates: \(plan.itemCount).")
                }
            } catch {
                if ErrorPresenter.isCancellationLike(error) {
                    await MainActor.run {
                        self.statusText = "Cancelled."
                        self.appendLog("Dry run cancelled.")
                    }
                } else {
                    await MainActor.run {
                        self.statusText = "Dry run failed: \(ErrorPresenter.short(error))"
                        self.appendLog("Dry run failed: \(String(describing: error))")
                    }
                }
            }
        }
    }

    func startApply(profile: Profile, archives: ArchiveLoader, mode: ApplyMode) {
        guard !isBusy else { return }
        guard let plan else {
            statusText = "Run dry-run first."
            return
        }

        let subset: Set<String>?
        switch mode {
        case .all:
            subset = nil
        case .failedOnly:
            let ids = Set(failures.map(\.arcid))
            if ids.isEmpty {
                statusText = "No failed archives to retry."
                return
            }
            subset = ids
        }

        isBusy = true
        statusText = mode == .all ? "Applying updates…" : "Retrying failed updates…"
        appendLog(mode == .all ? "Apply started." : "Retry failed started.")
        progress = .init(stage: .applying, scanned: 0, candidates: plan.itemCount, translated: plan.itemCount, applied: 0, failed: 0, message: "Starting apply…")
        if mode == .all {
            failures = []
        }

        activeTask = Task { [weak self] in
            guard let self else { return }
            defer {
                Task { @MainActor in
                    self.isBusy = false
                    self.activeTask = nil
                }
            }

            let result = await self.runService.applyPlan(
                profile: profile,
                archives: archives,
                plan: plan,
                onlyArcids: subset,
                report: { update in
                    Task { @MainActor [weak self] in
                        self?.progress = update
                        self?.statusText = update.message
                        self?.appendLog(update.message)
                    }
                }
            )

            await MainActor.run {
                self.failures = result.failures
                if result.failures.isEmpty {
                    self.statusText = "Apply complete. Updated \(result.successCount) archives."
                    self.appendLog("Apply complete. Updated \(result.successCount) archives.")
                } else {
                    self.statusText = "Apply complete. Updated \(result.successCount), failed \(result.failures.count)."
                    self.appendLog("Apply complete with \(result.failures.count) failures.")
                }
            }
        }
    }

    private func appendLog(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if eventLog.last?.hasSuffix(trimmed) == true {
            return
        }
        let stamp = Self.logTimeFormatter.string(from: Date())
        eventLog.append("[\(stamp)] \(trimmed)")
        if eventLog.count > 200 {
            eventLog.removeFirst(eventLog.count - 200)
        }
    }

    private static let logTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static func builtInModels(for provider: TitleTranslationProvider) -> [String] {
        switch provider {
        case .openAIAPI:
            openAIBuiltInModels
        case .codexCLI:
            codexBuiltInModels
        }
    }

    private static func defaultModel(for provider: TitleTranslationProvider) -> String {
        switch provider {
        case .openAIAPI:
            "gpt-5.4-nano"
        case .codexCLI:
            "gpt-5.4-mini"
        }
    }

    private static func sanitizedModel(_ model: String, for provider: TitleTranslationProvider) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return defaultModel(for: provider)
        }
        if provider == .codexCLI && trimmed == "gpt-5.4-nano" {
            return defaultModel(for: provider)
        }
        return trimmed
    }

    private static func normalizedModels(_ models: [String], including selectedModel: String) -> [String] {
        var seen = Set<String>()
        return (models + [selectedModel])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
            .sorted { lhs, rhs in
                lhs.localizedStandardCompare(rhs) == .orderedAscending
            }
    }
}

struct EnglishTitlesOnlySecretView: View {
    @EnvironmentObject private var appModel: AppModel
    @StateObject private var vm = EnglishTitlesOnlyViewModel()
    @State private var showApplyConfirm: Bool = false
    @State private var applyMode: EnglishTitlesOnlyViewModel.ApplyMode = .all

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Translate non-English archive titles to English, preserve original titles as tags, and add missing language tags.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Text("Provider")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Provider", selection: Binding(get: {
                    vm.selectedProvider
                }, set: { newValue in
                    vm.updateProvider(newValue)
                })) {
                    ForEach(TitleTranslationProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 180)

                Spacer()
            }

            if vm.requiresOpenAIKey {
                SecureField("OpenAI API Key (stored in Keychain)", text: $vm.openAIKey)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 10) {
                Text("Model")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Model", selection: Binding(get: {
                    vm.selectedModel
                }, set: { newValue in
                    vm.updateModel(newValue)
                })) {
                    ForEach(vm.availableModels, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 260)

                if vm.selectedProvider == .openAIAPI {
                    Button("Refresh Models") {
                        Task { await vm.refreshModels() }
                    }
                    .disabled(vm.isBusy)
                } else {
                    Button("Check Codex") {
                        Task { await vm.checkCodex() }
                    }
                    .disabled(vm.isBusy)
                }

                Spacer()
            }

            TextField("Or enter a model ID directly", text: Binding(get: {
                vm.selectedModel
            }, set: { newValue in
                vm.updateModel(newValue)
            }))
            .textFieldStyle(.roundedBorder)

            if vm.selectedProvider == .openAIAPI {
                if let modelStatus = vm.modelStatusText {
                    Text(modelStatus)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Text("OpenAI API mode uses your stored API key and can refresh account-visible models from OpenAI.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                if let providerStatus = vm.providerStatusText {
                    Text(providerStatus)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Text("Codex mode uses the local Codex CLI authenticated through your ChatGPT login. No API key is used in this mode.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 10) {
                Button("Dry Run") {
                    guard let profile = appModel.selectedProfile else { return }
                    vm.startDryRun(profile: profile)
                }
                .disabled(vm.isBusy || appModel.selectedProfile == nil)

                Button("Apply Planned Changes") {
                    applyMode = .all
                    showApplyConfirm = true
                }
                .disabled(vm.isBusy || vm.plan == nil)

                Button("Retry Failed") {
                    applyMode = .failedOnly
                    showApplyConfirm = true
                }
                .disabled(vm.isBusy || vm.failures.isEmpty || vm.plan == nil)

                if vm.isBusy {
                    Button("Cancel") {
                        vm.cancel()
                    }
                }

                Spacer()
            }

            progressSummary

            if let status = vm.statusText {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if !vm.eventLog.isEmpty {
                logView
            }

            if let plan = vm.plan {
                Divider()
                planPreview(plan)
            }

            if !vm.failures.isEmpty {
                Divider()
                failurePreview
            }
        }
        .onAppear {
            vm.loadPersistedState()
            if vm.selectedProvider == .openAIAPI {
                Task { await vm.refreshModels() }
            }
        }
        .alert("Apply title updates?", isPresented: $showApplyConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Apply", role: .destructive) {
                guard let profile = appModel.selectedProfile else { return }
                vm.startApply(profile: profile, archives: appModel.archives, mode: applyMode)
            }
        } message: {
            if applyMode == .all {
                Text("This will update all archives from the current dry-run plan.")
            } else {
                Text("This will retry only archives that failed in the previous apply run.")
            }
        }
    }

    private var progressSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Scanned: \(vm.progress.scanned)  Candidates: \(vm.progress.candidates)  Translated: \(vm.progress.translated)  Applied: \(vm.progress.applied)  Failed: \(vm.progress.failed)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            if let plan = vm.plan {
                let noOpCount = max(0, plan.candidateCount - plan.itemCount)
                Text("Dry-run note: translated candidates include no-op results. \(noOpCount) required no title/tag change, so \(plan.itemCount) were planned for apply.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var logView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Live Activity")
                .font(.callout.weight(.semibold))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(vm.eventLog.suffix(80).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxHeight: 140)
        }
    }

    @ViewBuilder
    private func planPreview(_ plan: TitleNormalizationPlan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Dry Run Preview")
                .font(.callout.weight(.semibold))
            Text("Snapshot: \(plan.snapshotCount) archives. Candidates: \(plan.candidateCount). Planned updates: \(plan.itemCount).")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Candidates are titles sent for language check/translation. Planned updates are only archives with actual title/tag changes.")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            if plan.itemCount == 0 {
                Text("No updates required.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Showing first \(min(50, plan.previewItems.count)) items")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(plan.previewItems) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("[\(item.detectedLanguage)] \(item.originalTitle)")
                                    .font(.caption)
                                Text("-> \(item.englishTitle)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if item.beforeTags != item.afterTags {
                                    Text("tags: \(item.afterTags)")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(2)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 3)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
    }

    private var failurePreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Failed Updates")
                .font(.callout.weight(.semibold))

            Text("\(vm.failures.count) archives failed. Retry uses only these arcids.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(vm.failures.prefix(50))) { failure in
                        Text("\(failure.arcid): \(failure.reason)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxHeight: 120)
        }
    }
}
