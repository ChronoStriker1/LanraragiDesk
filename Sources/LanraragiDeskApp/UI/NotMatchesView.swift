import AppKit
import SwiftUI
import LanraragiKit

struct NotMatchesView: View {
    let profile: Profile
    let embedded: Bool

    @EnvironmentObject private var appModel: AppModel

    @State private var query: String = ""
    @State private var confirmRemove: IndexStore.NotDuplicatePair?

    init(profile: Profile, embedded: Bool = false) {
        self.profile = profile
        self.embedded = embedded
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !embedded {
                header
            } else {
                embeddedHeader
            }

            if filteredPairs.isEmpty {
                Group {
                    if appModel.duplicates.notMatches.isEmpty {
                        ContentUnavailableView(
                            "No “Not a match” pairs",
                            systemImage: "nosign",
                            description: Text("Pairs you mark as “Not a match” appear here. Removing one allows it to show up in future scans again.")
                        )
                    } else {
                        ContentUnavailableView(
                            "No matches for search",
                            systemImage: "magnifyingglass",
                            description: Text("Try different IDs or clear the search terms.")
                        )
                    }
                }
                .frame(maxWidth: .infinity, minHeight: embedded ? 120 : 240)
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
                .frame(maxHeight: embedded ? 320 : .infinity)
            }
        }
        .padding(embedded ? 10 : 0)
        .background {
            if embedded {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.thinMaterial)
            }
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
        let tokens = q
            .split(whereSeparator: { $0 == " " || $0 == "," })
            .map { String($0).lowercased() }
            .filter { !$0.isEmpty }
        if tokens.isEmpty { return appModel.duplicates.notMatches }
        return appModel.duplicates.notMatches.filter { p in
            let hay = "\(p.arcidA) \(p.arcidB)".lowercased()
            return tokens.allSatisfy { hay.contains($0) }
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

            Button("Undo Last Change") {
                appModel.duplicates.undoLastNotDuplicateChange(profile: profile)
            }
            .disabled(!appModel.duplicates.hasUndoableNotMatchChange)

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

    private var embeddedHeader: some View {
        HStack(spacing: 10) {
            Text("\(appModel.duplicates.notMatches.count) excluded pairs")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            TextField("Search…", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)

            Button("Undo") {
                appModel.duplicates.undoLastNotDuplicateChange(profile: profile)
            }
            .disabled(!appModel.duplicates.hasUndoableNotMatchChange)

            Button("Refresh") {
                Task { await appModel.duplicates.loadNotDuplicatePairs(profile: profile) }
            }
        }
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
