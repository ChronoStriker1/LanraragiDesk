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

    private struct DiagnosticBundle: Encodable {
        struct Environment: Encodable {
            var appVersion: String
            var appBuild: String
            var macos: String
        }
        struct ProfileInfo: Encodable {
            var name: String
            var endpoint: String
        }

        var bundleVersion: Int = 1
        var generatedAt: Date
        var environment: Environment
        var profile: ProfileInfo?
        var events: [ActivityEvent]
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

                Button("Export JSON") {
                    exportJSON()
                }
                .disabled(filteredEvents.isEmpty)

                Button("Export CSV") {
                    exportCSV()
                }
                .disabled(filteredEvents.isEmpty)

                Button("Copy Diagnostic Bundle") {
                    copyDiagnosticBundle()
                }
                .disabled(filteredEvents.isEmpty)

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
                                Image(systemName: severitySymbol(for: e.kind))
                                    .foregroundStyle(severityColor(for: e.kind))
                                    .font(.caption.weight(.semibold))
                                Text(rendered.title)
                                    .font(.callout)
                                if let component = e.component, !component.isEmpty {
                                    Text(component)
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.primary.opacity(0.08))
                                        .clipShape(Capsule())
                                }
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
                            if let metadata = e.metadata, !metadata.isEmpty {
                                HStack(spacing: 6) {
                                    ForEach(metadata.sorted(by: { $0.key < $1.key }), id: \.key) { pair in
                                        Text("\(pair.key): \(pair.value)")
                                            .font(.caption2.monospaced())
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.primary.opacity(0.06))
                                            .clipShape(Capsule())
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
            if let c = e.component, c.lowercased().contains(needle) { return true }
            if let metadata = e.metadata {
                for (k, v) in metadata {
                    if k.lowercased().contains(needle) || v.lowercased().contains(needle) {
                        return true
                    }
                }
            }
            return false
        }
    }

    private func copyDiagnosticBundle() {
        let info = Bundle.main.infoDictionary
        let env = DiagnosticBundle.Environment(
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "",
            appBuild: info?["CFBundleVersion"] as? String ?? "",
            macos: ProcessInfo.processInfo.operatingSystemVersionString
        )
        let profileInfo: DiagnosticBundle.ProfileInfo? = appModel.selectedProfile.map {
            DiagnosticBundle.ProfileInfo(name: $0.name, endpoint: $0.baseURL.absoluteString)
        }
        let bundle = DiagnosticBundle(
            generatedAt: Date(),
            environment: env,
            profile: profileInfo,
            events: filteredEvents
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(bundle)
            if let text = String(data: data, encoding: .utf8) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copiedMessage = "Copied diagnostic bundle"
            }
        } catch {
            copiedMessage = "Copy failed"
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

    private func severitySymbol(for kind: ActivityEvent.Kind) -> String {
        switch kind {
        case .error:
            return "xmark.octagon.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .action:
            return "checkmark.circle.fill"
        case .info:
            return "info.circle.fill"
        }
    }

    private func severityColor(for kind: ActivityEvent.Kind) -> Color {
        switch kind {
        case .error:
            return .red
        case .warning:
            return .orange
        case .action:
            return .green
        case .info:
            return .blue
        }
    }

    private func exportJSON() {
        let panel = NSSavePanel()
        panel.title = "Export Activity"
        panel.nameFieldStringValue = "activity-export.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(filteredEvents)
            try data.write(to: url, options: [.atomic])
            copiedMessage = "Exported JSON"
        } catch {
            copiedMessage = "Export failed"
        }
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.title = "Export Activity"
        panel.nameFieldStringValue = "activity-export.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let rows = filteredEvents.map { event in
            [
                iso8601(event.date),
                event.kind.rawValue,
                event.component ?? "",
                event.title,
                event.detail ?? "",
                flattenedMetadata(event.metadata)
            ]
            .map(csvEscape)
            .joined(separator: ",")
        }
        let csv = (["timestamp,kind,component,title,detail,metadata"] + rows).joined(separator: "\n")
        do {
            try csv.data(using: .utf8)?.write(to: url, options: [.atomic])
            copiedMessage = "Exported CSV"
        } catch {
            copiedMessage = "Export failed"
        }
    }

    private func csvEscape(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    private func flattenedMetadata(_ metadata: [String: String]?) -> String {
        guard let metadata, !metadata.isEmpty else { return "" }
        return metadata
            .sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "; ")
    }

    private func iso8601(_ date: Date) -> String {
        Self.isoFormatter.string(from: date)
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
