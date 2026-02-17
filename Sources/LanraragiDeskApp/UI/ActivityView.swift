import AppKit
import Foundation
import SwiftUI

struct ActivityView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var searchText: String = ""
    @State private var filter: Filter = .all
    @State private var copiedMessage: String?

    enum Filter: String, CaseIterable, Identifiable {
        case all
        case errors
        case actions

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "All"
            case .errors: return "Errors"
            case .actions: return "Actions"
            }
        }
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Activity")
                    .font(.title2)
                    .bold()
                if let copiedMessage {
                    Text(copiedMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection: $filter) {
                    ForEach(Filter.allCases) { f in
                        Text(f.title).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)

                TextField("Search…", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)

                Button("Clear", role: .destructive) {
                    appModel.activity.clear()
                }
            }

            if filteredEvents.isEmpty {
                ContentUnavailableView("No Activity Yet", systemImage: "list.bullet.rectangle", description: Text("Edits, scans, and server actions will appear here."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            } else {
                List {
                    ForEach(filteredEvents) { e in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(e.title)
                                    .font(.callout)
                                Spacer()
                                Text(Self.formatter.string(from: e.date))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if let d = e.detail, !d.isEmpty {
                                Text(d)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if e.kind == .error {
                                copyEventToClipboard(e)
                            }
                        }
                        .contextMenu {
                            Button("Copy Entry") {
                                copyEventToClipboard(e)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(18)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .debugFrameNumber(1)
    }

    private var filteredEvents: [ActivityEvent] {
        let base: [ActivityEvent] = {
            switch filter {
            case .all:
                return appModel.activity.events
            case .errors:
                return appModel.activity.events.filter { $0.kind == .error || $0.kind == .warning }
            case .actions:
                return appModel.activity.events.filter { $0.kind == .action }
            }
        }()

        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return base }
        let needle = q.lowercased()
        return base.filter { e in
            if e.title.lowercased().contains(needle) { return true }
            if let d = e.detail, d.lowercased().contains(needle) { return true }
            return false
        }
    }

    private func copyEventToClipboard(_ event: ActivityEvent) {
        let parts = [
            event.title,
            event.detail
        ]
        let text = parts.compactMap { $0 }.joined(separator: "\n")
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedMessage = "Copied entry"
    }
}
