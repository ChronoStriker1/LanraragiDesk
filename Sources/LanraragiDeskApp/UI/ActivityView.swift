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

    private struct RenderedEvent {
        let title: String
        let subtitle: String?
        let lines: [String]
    }

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
                        let rendered = renderEvent(e)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(rendered.title)
                                    .font(.callout)
                                Spacer()
                                Text(Self.formatter.string(from: e.date))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if let subtitle = rendered.subtitle, !subtitle.isEmpty {
                                Text(subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            if !rendered.lines.isEmpty {
                                VStack(alignment: .leading, spacing: 2) {
                                    ForEach(Array(rendered.lines.enumerated()), id: \.offset) { _, line in
                                        Text("• \(line)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                    }
                                }
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

    private func renderEvent(_ event: ActivityEvent) -> RenderedEvent {
        let rawDetail = (event.detail ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if rawDetail.isEmpty {
            return .init(title: event.title, subtitle: nil, lines: [])
        }

        switch event.title {
        case "Plugin job queued", "Plugin output applied":
            let parts = rawDetail.split(separator: "•").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if parts.count >= 2 {
                var lines: [String] = [
                    "Plugin: \(parts[0])",
                    "Archive: \(parts[1])"
                ]
                if parts.count >= 3 {
                    lines.append("Status: \(parts[2])")
                }
                return .init(title: event.title, subtitle: nil, lines: lines)
            }

        case "Plugin batch queued", "Plugin batch preview generated":
            let parts = rawDetail.split(separator: " on ").map(String.init)
            if parts.count == 2 {
                return .init(
                    title: event.title,
                    subtitle: nil,
                    lines: [
                        "Plugin: \(parts[0].trimmingCharacters(in: .whitespacesAndNewlines))",
                        "Target: \(parts[1].trimmingCharacters(in: .whitespacesAndNewlines))"
                    ]
                )
            }

        case "Plugin queue failed", "Plugin output apply failed":
            let lines = rawDetail
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let first = lines.first {
                let parts = first.split(separator: "•").map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                var out: [String] = []
                if parts.count >= 2 {
                    out.append("Plugin: \(parts[0])")
                    out.append("Archive: \(parts[1])")
                }
                if lines.count > 1 {
                    out.append(cleanErrorText(lines.dropFirst().joined(separator: " ")))
                }
                if !out.isEmpty {
                    return .init(title: event.title, subtitle: nil, lines: out)
                }
            }
        default:
            break
        }

        return .init(
            title: event.title,
            subtitle: nil,
            lines: rawDetail
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { cleanErrorText(String($0).trimmingCharacters(in: .whitespacesAndNewlines)) }
        )
    }

    private func cleanErrorText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("decoding(") {
            return "Decode error: \(trimmed)"
        }
        if trimmed.hasPrefix("transport(") {
            return "Network error: \(trimmed)"
        }
        if trimmed.hasPrefix("httpStatus(") {
            return "HTTP error: \(trimmed)"
        }
        return trimmed
    }
}
