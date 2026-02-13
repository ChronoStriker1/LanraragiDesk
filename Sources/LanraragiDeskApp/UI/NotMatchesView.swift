import AppKit
import SwiftUI
import LanraragiKit

struct NotMatchesView: View {
    let profile: Profile

    @EnvironmentObject private var appModel: AppModel

    @State private var query: String = ""
    @State private var confirmRemove: IndexStore.NotDuplicatePair?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if filteredPairs.isEmpty {
                ContentUnavailableView(
                    "No “Not a match” pairs",
                    systemImage: "nosign",
                    description: Text("Pairs you mark as “Not a match” appear here. Removing one allows it to show up in future scans again.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .center, spacing: 8) {
                        ForEach(filteredPairs, id: \.self) { p in
                            NotMatchRow(
                                profile: profile,
                                pair: p,
                                thumbnails: appModel.duplicates.thumbnails,
                                onRemove: { confirmRemove = p }
                            )
                        }
                    }
                    .padding(12)
                }
                .scrollIndicators(.visible)
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
        .task(id: profile.id) {
            await appModel.duplicates.loadNotDuplicatePairs(profile: profile)
        }
        .confirmationDialog(
            "Remove “Not a match”?",
            isPresented: Binding(
                get: { confirmRemove != nil },
                set: { if !$0 { confirmRemove = nil } }
            )
        ) {
            if let pair = confirmRemove {
                Button("Remove", role: .destructive) {
                    appModel.duplicates.removeNotDuplicatePair(profile: profile, pair: pair)
                    confirmRemove = nil
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This pair can appear in future scans again.")
        }
    }

    private var filteredPairs: [IndexStore.NotDuplicatePair] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return appModel.duplicates.notMatches }
        return appModel.duplicates.notMatches.filter { p in
            p.arcidA.localizedCaseInsensitiveContains(q) || p.arcidB.localizedCaseInsensitiveContains(q)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Not a match")
                    .font(.title2)
                    .bold()
                Text("\(appModel.duplicates.notMatches.count) pairs")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            TextField("Search ID…", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)

            Button("Refresh") {
                Task { await appModel.duplicates.loadNotDuplicatePairs(profile: profile) }
            }

            Button("Clear All", role: .destructive) {
                appModel.duplicates.clearNotDuplicateDecisions(profile: profile)
            }
        }
        .padding(14)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct NotMatchRow: View {
    let profile: Profile
    let pair: IndexStore.NotDuplicatePair
    let thumbnails: ThumbnailLoader
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            CoverThumb(profile: profile, arcid: pair.arcidA, thumbnails: thumbnails, size: .init(width: 96, height: 124))
            CoverThumb(profile: profile, arcid: pair.arcidB, thumbnails: thumbnails, size: .init(width: 96, height: 124))

            Spacer(minLength: 0)

            Button(role: .destructive) { onRemove() } label: {
                Label("Remove", systemImage: "xmark.circle.fill")
            }
            .buttonStyle(.bordered)
        }
        .padding(10)
        .background(.quaternary.opacity(0.28))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { onRemove() }
        .contextMenu {
            Button("Remove “Not a match”…", role: .destructive) { onRemove() }
            Divider()
            Button("Copy Left ID") { NSPasteboard.general.setString(pair.arcidA, forType: .string) }
            Button("Copy Right ID") { NSPasteboard.general.setString(pair.arcidB, forType: .string) }
        }
    }
}
