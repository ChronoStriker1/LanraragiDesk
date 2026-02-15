import Foundation
import AppKit
import SwiftUI
import LanraragiKit

struct LibraryView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.openWindow) private var openWindow

    let profile: Profile

    @StateObject private var vm = LibraryViewModel()
    @State private var tagSuggestions: [TagSuggestionStore.Suggestion] = []
    @State private var suggestionTask: Task<Void, Never>?
    @State private var editingMeta: EditorRoute?

    struct EditorRoute: Identifiable, Hashable {
        let arcid: String
        var id: String { arcid }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if let banner = vm.bannerText {
                Text(banner)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            if let err = vm.errorText {
                Text("Error: \(err)")
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            results
        }
        .sheet(item: $editingMeta) { route in
            ArchiveMetadataEditorView(
                profile: profile,
                arcid: route.arcid,
                initialMeta: nil,
                archives: appModel.archives,
                onSaved: { _ in }
            )
            .environmentObject(appModel)
        }
        .onAppear {
            if vm.arcids.isEmpty {
                vm.refresh(profile: profile)
            }
        }
        .onChange(of: vm.sort) { _, _ in
            vm.refresh(profile: profile)
        }
        .onChange(of: vm.newOnly) { _, _ in
            vm.refresh(profile: profile)
        }
        .onChange(of: vm.untaggedOnly) { _, _ in
            vm.refresh(profile: profile)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Text("Library")
                    .font(.title2)
                    .bold()

                Spacer()

                Picker("", selection: $vm.layout) {
                    Text("Grid").tag(LibraryViewModel.Layout.grid)
                    Text("List").tag(LibraryViewModel.Layout.list)
                }
                .pickerStyle(.segmented)
                .frame(width: 140)

                Picker("Sort", selection: $vm.sort) {
                    ForEach(LibraryViewModel.Sort.allCases) { s in
                        Text(s.title).tag(s)
                    }
                }
                .frame(width: 170)
            }

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Search…", text: $vm.query)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { vm.refresh(profile: profile) }
                        .onChange(of: vm.query) { _, _ in
                            queueSuggestionRefresh()
                        }

                    if !tagSuggestions.isEmpty {
                        ScrollView(.vertical) {
                            LazyVStack(alignment: .leading, spacing: 6) {
                                ForEach(tagSuggestions.prefix(12), id: \.value) { s in
                                    Button {
                                        applySuggestion(s.value)
                                    } label: {
                                        HStack(spacing: 10) {
                                            Text(s.value)
                                                .font(.callout)
                                            Spacer()
                                            Text("\(s.weight)")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.vertical, 6)
                                        .padding(.horizontal, 10)
                                        .background(.quaternary.opacity(0.35))
                                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 6)
                        }
                        .frame(maxHeight: 160)
                    }
                }

                Button("Search") {
                    vm.refresh(profile: profile)
                }

                Button("Clear") {
                    vm.query = ""
                    vm.refresh(profile: profile)
                }
                .disabled(vm.query.isEmpty)

                Spacer()
            }

            DisclosureGroup("Filters") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 16) {
                        Toggle("New only", isOn: $vm.newOnly)
                        Toggle("Untagged only", isOn: $vm.untaggedOnly)
                        Spacer()
                    }

                    HStack(spacing: 10) {
                        TextField("Category (optional)", text: $vm.category)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 280)
                            .onSubmit { vm.refresh(profile: profile) }
                        Spacer()
                    }
                }
                .padding(.top, 6)
            }
        }
        .padding(18)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .debugFrameNumber(1)
    }

    @ViewBuilder
    private var results: some View {
        switch vm.layout {
        case .grid:
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 170), spacing: 12, alignment: .top)],
                    alignment: .leading,
                    spacing: 12
                ) {
                    ForEach(vm.arcids, id: \.self) { arcid in
                        LibraryCard(profile: profile, arcid: arcid)
                            .environmentObject(appModel)
                            .contextMenu {
                                Button("Open Reader") {
                                    openWindow(value: ReaderRoute(profileID: profile.id, arcid: arcid))
                                }
                                Button("Edit Metadata…") {
                                    editingMeta = EditorRoute(arcid: arcid)
                                }
                                Divider()
                                Button("Copy Archive ID") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(arcid, forType: .string)
                                }
                            }
                            .onTapGesture {
                                openWindow(value: ReaderRoute(profileID: profile.id, arcid: arcid))
                            }
                            .onAppear {
                                if arcid == vm.arcids.last {
                                    Task { await vm.loadMore(profile: profile) }
                                }
                            }
                    }

                    if vm.isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(20)
                            .gridCellColumns(2)
                    }
                }
                .padding(.vertical, 6)
            }
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .debugFrameNumber(2)

        case .list:
            List {
                ForEach(vm.arcids, id: \.self) { arcid in
                    LibraryRow(profile: profile, arcid: arcid)
                        .environmentObject(appModel)
                        .contentShape(Rectangle())
                        .contextMenu {
                            Button("Open Reader") {
                                openWindow(value: ReaderRoute(profileID: profile.id, arcid: arcid))
                            }
                            Button("Edit Metadata…") {
                                editingMeta = EditorRoute(arcid: arcid)
                            }
                            Divider()
                            Button("Copy Archive ID") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(arcid, forType: .string)
                            }
                        }
                        .onTapGesture {
                            openWindow(value: ReaderRoute(profileID: profile.id, arcid: arcid))
                        }
                        .onAppear {
                            if arcid == vm.arcids.last {
                                Task { await vm.loadMore(profile: profile) }
                            }
                        }
                }

                if vm.isLoading {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
            }
            .listStyle(.inset)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .debugFrameNumber(2)
        }
    }

    private func queueSuggestionRefresh() {
        suggestionTask?.cancel()
        suggestionTask = Task {
            // Light debounce so fast typing doesn't spam filtering.
            try? await Task.sleep(nanoseconds: 150_000_000)
            if Task.isCancelled { return }
            await refreshSuggestions()
        }
    }

    private func refreshSuggestions() async {
        let (prefix, _) = currentToken()
        let q = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else {
            await MainActor.run { tagSuggestions = [] }
            return
        }

        let minWeight = UserDefaults.standard.integer(forKey: "tags.minWeight")
        let ttlHours = max(1, UserDefaults.standard.integer(forKey: "tags.ttlHours"))
        let settings = TagSuggestionStore.Settings(minWeight: minWeight, ttlSeconds: ttlHours * 60 * 60)

        let sugg = await appModel.tagSuggestions.suggestions(profile: profile, settings: settings, prefix: q, limit: 20)
        await MainActor.run { tagSuggestions = sugg }
    }

    private func applySuggestion(_ value: String) {
        let (prefix, range) = currentToken()
        let trimmedPrefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrefix.isEmpty else {
            vm.query = value + " "
            tagSuggestions = []
            return
        }

        let isNegated = trimmedPrefix.hasPrefix("-")
        let token = (isNegated ? "-" : "") + value

        if let range {
            let head = String(vm.query[..<range.lowerBound])
            vm.query = head + token + " "
        } else {
            vm.query = token + " "
        }
        tagSuggestions = []
    }

    private func currentToken() -> (String, Range<String.Index>?) {
        let q = vm.query
        if q.isEmpty { return ("", nil) }

        let separators = CharacterSet.whitespacesAndNewlines.union(.init(charactersIn: ","))
        if let r = q.rangeOfCharacter(from: separators, options: .backwards) {
            let token = String(q[r.upperBound...])
            return (token, r.upperBound..<q.endIndex)
        }
        return (q, nil)
    }
}

private struct LibraryCard: View {
    @EnvironmentObject private var appModel: AppModel

    let profile: Profile
    let arcid: String

    @State private var title: String = "Loading…"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                CoverThumb(profile: profile, arcid: arcid, thumbnails: appModel.thumbnails, size: .init(width: 160, height: 210))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                Button {
                    appModel.selection.toggle(arcid)
                } label: {
                    Image(systemName: appModel.selection.contains(arcid) ? "checkmark.circle.fill" : "circle")
                        .imageScale(.large)
                        .foregroundStyle(appModel.selection.contains(arcid) ? .green : .secondary)
                        .padding(8)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Select for batch operations")
                .padding(8)
            }

            Text(title)
                .font(.callout)
                .lineLimit(2)
        }
        .padding(10)
        .background(.quaternary.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
        }
        .task(id: arcid) {
            do {
                let meta = try await appModel.archives.metadata(profile: profile, arcid: arcid)
                let t = meta.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                title = t.isEmpty ? "Untitled" : t
            } catch {
                title = "Untitled"
            }
        }
    }
}

private struct LibraryRow: View {
    @EnvironmentObject private var appModel: AppModel

    let profile: Profile
    let arcid: String

    @State private var title: String = "Loading…"
    @State private var subtitle: String = ""

    var body: some View {
        HStack(spacing: 12) {
            Button {
                appModel.selection.toggle(arcid)
            } label: {
                Image(systemName: appModel.selection.contains(arcid) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(appModel.selection.contains(arcid) ? .green : .secondary)
            }
            .buttonStyle(.plain)
            .help("Select for batch operations")

            CoverThumb(profile: profile, arcid: arcid, thumbnails: appModel.thumbnails, size: .init(width: 54, height: 72))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.callout)
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()
        }
        .task(id: arcid) {
            do {
                let meta = try await appModel.archives.metadata(profile: profile, arcid: arcid)
                let t = meta.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                title = t.isEmpty ? "Untitled" : t
                let ext = meta.fileExtension?.uppercased() ?? ""
                let pages = meta.pagecount ?? 0
                subtitle = [pages > 0 ? "\(pages) pages" : nil, ext.isEmpty ? nil : ext].compactMap { $0 }.joined(separator: " • ")
            } catch {
                title = "Untitled"
                subtitle = ""
            }
        }
    }
}
