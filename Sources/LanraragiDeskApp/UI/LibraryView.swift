import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.openWindow) private var openWindow

    let profile: Profile

    @StateObject private var vm = LibraryViewModel()

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
        .onAppear {
            if vm.arcids.isEmpty {
                vm.refresh(profile: profile)
            }
        }
        .onChange(of: vm.sort) { _, _ in
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
                TextField("Search…", text: $vm.query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        vm.refresh(profile: profile)
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
        }
        .padding(18)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
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

        case .list:
            List {
                ForEach(vm.arcids, id: \.self) { arcid in
                    LibraryRow(profile: profile, arcid: arcid)
                        .environmentObject(appModel)
                        .contentShape(Rectangle())
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
        }
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
