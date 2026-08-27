import AppKit
import SwiftUI
import LanraragiKit

struct NotMatchesView: View {
    let profile: Profile
    let embedded: Bool

    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var query: String = ""
    @State private var sortColumn: NotMatchSortColumn = .created
    @State private var sortAscending: Bool = false
    @State private var confirmRemove: IndexStore.NotDuplicatePair?
    @State private var showClearAllConfirmation: Bool = false

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

            refreshStatus

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
                            description: Text("Try a different archive ID or created time, or clear the search terms.")
                        )
                    }
                }
                .frame(maxWidth: .infinity, minHeight: embedded ? 120 : 240)
            } else {
                ScrollView(.horizontal) {
                    VStack(spacing: 0) {
                        columnHeaders
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)

                        Divider()

                        ScrollView(.vertical) {
                            LazyVStack(alignment: .center, spacing: 8) {
                                ForEach(filteredPairs, id: \.self) { p in
                                    NotMatchRow(
                                        profile: profile,
                                        pair: p,
                                        createdText: NotMatchListPresentation.createdText(for: p),
                                        thumbnails: appModel.duplicates.thumbnails,
                                        onRemove: { confirmRemove = p }
                                    )
                                }
                            }
                            .padding(12)
                        }
                        .scrollIndicators(.visible)
                    }
                    .frame(minWidth: NotMatchColumnLayout.minimumTableWidth)
                }
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
        .task(id: profile.id) {
            await appModel.duplicates.loadAndPruneNotDuplicatePairs(profile: profile)
        }
    }

    private var filteredPairs: [IndexStore.NotDuplicatePair] {
        NotMatchListPresentation.filterAndSort(
            appModel.duplicates.notMatches,
            query: query,
            sortColumn: sortColumn,
            ascending: sortAscending
        )
    }

    private var columnHeaders: some View {
        HStack(spacing: NotMatchColumnLayout.spacing) {
            sortButton(for: .created, width: NotMatchColumnLayout.createdWidth)
            sortButton(for: .leftArchiveID, width: NotMatchColumnLayout.archiveWidth)
            sortButton(for: .rightArchiveID, width: NotMatchColumnLayout.archiveWidth)
            Text("Actions")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: NotMatchColumnLayout.actionWidth, alignment: .trailing)
        }
    }

    private func sortButton(for column: NotMatchSortColumn, width: CGFloat) -> some View {
        Button {
            if sortColumn == column {
                sortAscending.toggle()
            } else {
                sortColumn = column
                sortAscending = column.defaultAscending
            }
        } label: {
            HStack(spacing: 4) {
                Text(column.title)
                    .lineLimit(1)
                if sortColumn == column {
                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                        .accessibilityHidden(true)
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(sortColumn == column ? .primary : .secondary)
            .frame(width: width, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sort by \(column.title)")
        .accessibilityValue(sortColumn == column ? (sortAscending ? "Ascending" : "Descending") : "Not selected")
        .help(sortColumn == column ? "Toggle \(column.title.lowercased()) sort direction" : "Sort by \(column.title.lowercased())")
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

            TextField("Search ID or created time…", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)

            Button("Undo Last Change") {
                appModel.duplicates.undoLastNotDuplicateChange(profile: profile)
            }
            .disabled(!appModel.duplicates.hasUndoableNotMatchChange)

            Button("Refresh") {
                Task { await appModel.duplicates.loadAndPruneNotDuplicatePairs(profile: profile) }
            }
            .disabled(appModel.duplicates.isRefreshingNotMatches)

            Button("Clear All", role: .destructive) {
                showClearAllConfirmation = true
            }

            Button("Close") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(14)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .confirmationDialog(
            "Clear all “Not a match” decisions?",
            isPresented: $showClearAllConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear All", role: .destructive) {
                appModel.duplicates.clearNotDuplicateDecisions(profile: profile)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes all saved exclusions. Those pairs can appear in future duplicate scans again.")
        }
    }

    private var embeddedHeader: some View {
        HStack(spacing: 10) {
            Text("\(appModel.duplicates.notMatches.count) excluded pairs")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            TextField("Search ID or time…", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)

            Button("Undo") {
                appModel.duplicates.undoLastNotDuplicateChange(profile: profile)
            }
            .disabled(!appModel.duplicates.hasUndoableNotMatchChange)

            Button("Refresh") {
                Task { await appModel.duplicates.loadAndPruneNotDuplicatePairs(profile: profile) }
            }
            .disabled(appModel.duplicates.isRefreshingNotMatches)
        }
    }

    @ViewBuilder
    private var refreshStatus: some View {
        if let message = appModel.duplicates.notMatchRefreshMessage {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, embedded ? 4 : 14)
        } else if let error = appModel.duplicates.notMatchRefreshError {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .padding(.horizontal, embedded ? 4 : 14)
        }
    }
}

private struct NotMatchRow: View {
    let profile: Profile
    let pair: IndexStore.NotDuplicatePair
    let createdText: String
    let thumbnails: ThumbnailLoader
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: NotMatchColumnLayout.spacing) {
            Text(createdText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: NotMatchColumnLayout.createdWidth, alignment: .leading)

            archiveColumn(arcid: pair.arcidA)
            archiveColumn(arcid: pair.arcidB)

            Button(role: .destructive) { onRemove() } label: {
                Label("Remove", systemImage: "xmark.circle.fill")
            }
            .buttonStyle(.bordered)
            .frame(width: NotMatchColumnLayout.actionWidth, alignment: .trailing)
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

    private func archiveColumn(arcid: String) -> some View {
        HStack(spacing: 8) {
            CoverThumb(
                profile: profile,
                arcid: arcid,
                thumbnails: thumbnails,
                size: .init(width: 56, height: 72)
            )
            Text(arcid)
                .font(.caption.monospaced())
                .lineLimit(2)
                .truncationMode(.middle)
                .help(arcid)
        }
        .frame(width: NotMatchColumnLayout.archiveWidth, alignment: .leading)
    }
}

private enum NotMatchColumnLayout {
    static let spacing: CGFloat = 12
    static let createdWidth: CGFloat = 160
    static let archiveWidth: CGFloat = 190
    static let actionWidth: CGFloat = 96
    static let minimumTableWidth = createdWidth + (archiveWidth * 2) + actionWidth + (spacing * 3)
}
