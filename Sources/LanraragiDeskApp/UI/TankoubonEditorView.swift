import AppKit
import SwiftUI
import LanraragiKit

/// Sheet that loads a Tankoubon by ID and hosts the editor.
/// Opened from the Library by clicking (or right-clicking) a Tankoubon entry.
struct TankoubonEditorSheet: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss

    let profile: Profile
    let tankID: String
    /// Called whenever the tank was mutated (metadata, contents, or deleted)
    /// so the library can refresh.
    let onChanged: () -> Void

    @State private var tank: Tankoubon?
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let tank {
                TankoubonDetailView(
                    profile: profile,
                    tank: tank,
                    onChanged: {
                        onChanged()
                        Task { await reload() }
                    },
                    onDeleted: {
                        onChanged()
                        dismiss()
                    }
                )
                .environmentObject(appModel)
            } else if let errorText {
                VStack(spacing: 12) {
                    Text("Couldn’t load Tankoubon")
                        .font(.title3.weight(.semibold))
                    Text(errorText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(40)
            }

            Divider()

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(minWidth: 700, minHeight: 520)
        .task(id: tankID) {
            await reload()
        }
    }

    private func reload() async {
        do {
            tank = try await appModel.archives.tankoubonWithArchiveMetadata(
                profile: profile,
                tankID: tankID
            )
            errorText = nil
        } catch {
            if tank == nil {
                errorText = ErrorPresenter.short(error)
            }
        }
    }
}

/// Editor for one Tankoubon: metadata, ordered archive list, membership.
private struct TankoubonDetailView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.openWindow) private var openWindow

    let profile: Profile
    let tank: Tankoubon
    let onChanged: () -> Void
    let onDeleted: () -> Void

    @State private var name: String = ""
    @State private var summary: String = ""
    @State private var tags: String = ""
    @State private var archives: [String] = []
    @State private var isSaving: Bool = false
    @State private var isMutatingArchives: Bool = false
    @State private var statusText: String?
    @State private var confirmDelete: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            metadataEditor

            Divider()

            archivesSection
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { syncFromTank() }
        .onChange(of: tank.id) { _, _ in syncFromTank() }
        .confirmationDialog(
            "Delete “\(tank.name)”?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Tankoubon", role: .destructive) { deleteTank() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The archives inside are not deleted from the server.")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            CoverThumb(profile: profile, arcid: tank.id, thumbnails: appModel.thumbnails, size: .init(width: 54, height: 72), showsBorder: false)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(tank.name.isEmpty ? tank.id : tank.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                HStack(spacing: 10) {
                    Text("\(archives.count) archives")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let progress = tank.progress, progress > 0 {
                        Text("Progress: page \(progress)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(tank.id)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            }

            Spacer()

            Button {
                if let first = archives.first {
                    openReader(first)
                }
            } label: {
                Label("Read", systemImage: "book")
            }
            .disabled(archives.isEmpty)
            .help("Read the Tankoubon from the first archive")

            Button("Open in Browser") { openInBrowser() }

            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Image(systemName: "trash")
            }
            .help("Delete this Tankoubon (archives are kept)")
        }
    }

    private var metadataEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)

                TextField("Tags (comma-separated)", text: $tags)
                    .textFieldStyle(.roundedBorder)

                Button(isSaving ? "Saving…" : "Save Metadata") { saveMetadata() }
                    .disabled(isSaving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            TextField("Summary", text: $summary, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)

            if let statusText {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var archivesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Archives (reading order — drag to reorder)")
                    .font(.callout.weight(.semibold))

                Spacer()

                let selectedCount = appModel.selection.arcids.filter { !LANraragiID.isTankoubon($0) }.count
                Button("Add \(selectedCount) Selected From Library") {
                    addSelectedFromLibrary()
                }
                .disabled(selectedCount == 0 || isMutatingArchives)
                .help("Adds the archives currently selected in the Library view")
            }

            if archives.isEmpty {
                Text("Empty. Select archives in the Library and use “Add to Tankoubon…”, or use the button above.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            } else {
                List {
                    ForEach(Array(archives.enumerated()), id: \.element) { idx, arcid in
                        TankArchiveRow(
                            profile: profile,
                            arcid: arcid,
                            position: idx + 1,
                            onOpen: { openReader(arcid) },
                            onRemove: { removeArchive(arcid) },
                            disabled: isMutatingArchives
                        )
                        .environmentObject(appModel)
                    }
                    .onMove { from, to in
                        var reordered = archives
                        reordered.move(fromOffsets: from, toOffset: to)
                        pushOrder(reordered)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func syncFromTank() {
        name = tank.name
        summary = tank.summary ?? ""
        tags = tank.tags ?? ""
        var seen = Set<String>()
        archives = tank.archives.filter { seen.insert($0).inserted }
        statusText = nil
    }

    private func saveMetadata() {
        guard !isSaving else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await appModel.archives.updateTankoubon(
                    profile: profile,
                    tankID: tank.id,
                    name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                    summary: summary,
                    tags: tags
                )
                statusText = "Saved."
                appModel.activity.add(.init(kind: .action, title: "Updated Tankoubon metadata", detail: tank.id, component: "Tankoubons"))
                onChanged()
            } catch {
                statusText = "Save failed: \(ErrorPresenter.short(error))"
                appModel.activity.add(.init(kind: .error, title: "Tankoubon metadata update failed", detail: "\(tank.id)\n\(error)", component: "Tankoubons"))
            }
        }
    }

    private func pushOrder(_ newOrder: [String]) {
        guard !isMutatingArchives else { return }
        let previous = archives
        archives = newOrder
        isMutatingArchives = true
        Task {
            defer { isMutatingArchives = false }
            do {
                try await appModel.archives.updateTankoubon(profile: profile, tankID: tank.id, archives: newOrder)
                appModel.activity.add(.init(kind: .action, title: "Reordered Tankoubon", detail: tank.id, component: "Tankoubons"))
                onChanged()
            } catch {
                archives = previous
                statusText = "Reorder failed: \(ErrorPresenter.short(error))"
                appModel.activity.add(.init(kind: .error, title: "Tankoubon reorder failed", detail: "\(tank.id)\n\(error)", component: "Tankoubons"))
            }
        }
    }

    private func addSelectedFromLibrary() {
        let ids = appModel.selection.arcids.filter { !LANraragiID.isTankoubon($0) }.sorted()
        guard !ids.isEmpty, !isMutatingArchives else { return }
        isMutatingArchives = true
        Task {
            defer { isMutatingArchives = false }
            var added = 0
            var lastError: Error?
            for arcid in ids where !archives.contains(arcid) {
                do {
                    try await appModel.archives.addArchiveToTankoubon(profile: profile, tankID: tank.id, arcid: arcid)
                    archives.append(arcid)
                    added += 1
                } catch {
                    lastError = error
                }
            }
            if let lastError {
                statusText = "Added \(added); some failed: \(ErrorPresenter.short(lastError))"
            } else {
                statusText = added == 0 ? "Nothing to add (already in this Tankoubon)." : "Added \(added) archives."
            }
            appModel.activity.add(.init(kind: .action, title: "Added archives to Tankoubon", detail: "\(added) → \(tank.id)", component: "Tankoubons"))
            onChanged()
        }
    }

    private func removeArchive(_ arcid: String) {
        guard !isMutatingArchives else { return }
        isMutatingArchives = true
        Task {
            defer { isMutatingArchives = false }
            do {
                try await appModel.archives.removeArchiveFromTankoubon(profile: profile, tankID: tank.id, arcid: arcid)
                archives.removeAll { $0 == arcid }
                appModel.activity.add(.init(kind: .action, title: "Removed archive from Tankoubon", detail: "\(arcid) ← \(tank.id)", component: "Tankoubons"))
                onChanged()
            } catch {
                statusText = "Remove failed: \(ErrorPresenter.short(error))"
                appModel.activity.add(.init(kind: .error, title: "Tankoubon remove failed", detail: "\(arcid)\n\(error)", component: "Tankoubons"))
            }
        }
    }

    private func deleteTank() {
        Task {
            do {
                try await appModel.archives.deleteTankoubon(profile: profile, tankID: tank.id)
                appModel.activity.add(.init(kind: .action, title: "Deleted Tankoubon", detail: tank.id, component: "Tankoubons"))
                onDeleted()
            } catch {
                statusText = "Delete failed: \(ErrorPresenter.short(error))"
                appModel.activity.add(.init(kind: .error, title: "Tankoubon delete failed", detail: "\(tank.id)\n\(error)", component: "Tankoubons"))
            }
        }
    }

    private func openReader(_ arcid: String) {
        let context = TankoubonReaderContext(
            tankID: tank.id,
            name: name,
            archives: archives,
            archiveTitles: TankoubonReaderContext(tankoubon: tank).archiveTitles
        )
        guard let route = context.readerRoute(
            profileID: profile.id,
            startingAt: arcid
        ) else { return }
        appModel.setActiveReader(route)
        openWindow(id: "reader")
    }

    private func openInBrowser() {
        guard var comps = URLComponents(url: profile.baseURL, resolvingAgainstBaseURL: false) else { return }
        comps.path = "/reader"
        comps.queryItems = [URLQueryItem(name: "id", value: tank.id)]
        guard let url = comps.url else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct TankArchiveRow: View {
    @EnvironmentObject private var appModel: AppModel

    let profile: Profile
    let arcid: String
    let position: Int
    let onOpen: () -> Void
    let onRemove: () -> Void
    let disabled: Bool

    @State private var title: String = "Loading…"
    @State private var pages: Int = 0

    var body: some View {
        HStack(spacing: 10) {
            Text("\(position)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .trailing)

            CoverThumb(profile: profile, arcid: arcid, thumbnails: appModel.thumbnails, size: .init(width: 34, height: 46), showsBorder: false)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout)
                    .lineLimit(1)
                if pages > 0 {
                    Text("\(pages) pages")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button("Read") { onOpen() }
                .buttonStyle(.borderless)

            Button {
                onRemove()
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
            .disabled(disabled)
            .help("Remove from Tankoubon (archive is kept on the server)")
        }
        .padding(.vertical, 2)
        .task(id: arcid) {
            do {
                let meta = try await appModel.archives.metadata(profile: profile, arcid: arcid)
                let t = meta.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                title = t.isEmpty ? arcid : t
                pages = meta.pagecount ?? 0
            } catch {
                title = arcid
            }
        }
    }
}

/// Small sheet to pick (or create) a Tankoubon and add the given archives to it.
struct TankoubonPickerView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss

    let profile: Profile
    let arcids: [String]
    /// Called after archives were successfully added, with the target tank ID.
    var onAdded: ((String) -> Void)? = nil

    @State private var tanks: [Tankoubon] = []
    @State private var isLoading: Bool = true
    @State private var isWorking: Bool = false
    @State private var errorText: String?
    @State private var newTankName: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(arcids.count == 1 ? "Add archive to Tankoubon" : "Add \(arcids.count) archives to Tankoubon")
                .font(.title3.weight(.semibold))

            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            if isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading Tankoubons…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 24)
            } else if tanks.isEmpty {
                Text("No Tankoubons yet — create one below.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(tanks) { tank in
                            Button {
                                add(to: tank.id)
                            } label: {
                                HStack {
                                    Text(tank.name.isEmpty ? tank.id : tank.name)
                                        .lineLimit(1)
                                    Spacer()
                                    Text("\(tank.archives.count)")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(.quaternary.opacity(0.3))
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .disabled(isWorking)
                        }
                    }
                }
                .frame(maxHeight: 260)
            }

            Divider()

            HStack(spacing: 8) {
                TextField("New Tankoubon name…", text: $newTankName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { createAndAdd() }
                Button("Create & Add") { createAndAdd() }
                    .disabled(newTankName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(minWidth: 420)
        .task {
            do {
                tanks = try await appModel.archives.listTankoubons(profile: profile)
                errorText = nil
            } catch let LANraragiError.httpStatus(code, _) where code == 404 {
                errorText = "This server doesn’t support Tankoubons. Update LANraragi to use this feature."
            } catch {
                errorText = ErrorPresenter.short(error)
            }
            isLoading = false
        }
    }

    private func createAndAdd() {
        let name = newTankName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !isWorking else { return }
        isWorking = true
        Task {
            do {
                let id = try await appModel.archives.createTankoubon(profile: profile, name: name)
                appModel.activity.add(.init(kind: .action, title: "Created Tankoubon", detail: "\(name) (\(id))", component: "Tankoubons"))
                await addArchives(tankID: id)
            } catch {
                errorText = ErrorPresenter.short(error)
                isWorking = false
            }
        }
    }

    private func add(to tankID: String) {
        guard !isWorking else { return }
        isWorking = true
        Task { await addArchives(tankID: tankID) }
    }

    private func addArchives(tankID: String) async {
        var added = 0
        var lastError: Error?
        for arcid in arcids {
            do {
                try await appModel.archives.addArchiveToTankoubon(profile: profile, tankID: tankID, arcid: arcid)
                added += 1
            } catch {
                lastError = error
            }
        }

        if let lastError {
            errorText = "Added \(added) of \(arcids.count): \(ErrorPresenter.short(lastError))"
            isWorking = false
            appModel.activity.add(.init(kind: .error, title: "Add to Tankoubon partially failed", detail: "\(added)/\(arcids.count) → \(tankID)", component: "Tankoubons"))
            return
        }

        appModel.activity.add(.init(kind: .action, title: "Added to Tankoubon", detail: "\(added) archives → \(tankID)", component: "Tankoubons"))
        onAdded?(tankID)
        dismiss()
    }
}
