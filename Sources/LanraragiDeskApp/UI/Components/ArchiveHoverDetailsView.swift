import SwiftUI

/// Hover popover with title, page count, summary, and a tappable tag cloud.
struct ArchiveHoverDetailsView: View {
    let title: String
    let summary: String
    let tags: String
    let pageCount: Int
    let onSelectTag: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Text(title.isEmpty ? "Untitled" : title)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if pageCount > 0 {
                    Text("\(pageCount) pp")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.quaternary)
                        .clipShape(Capsule())
                        .fixedSize()
                }
            }

            let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedSummary.isEmpty {
                Divider()
                Text(trimmedSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            let trimmedTags = tags.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedTags.isEmpty {
                Divider()
                HoverTagCloud(tags: trimmedTags, onSelectTag: onSelectTag)
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}

struct HoverTagCloud: View {
    let tags: String
    let onSelectTag: (String) -> Void

    private struct TagItem {
        var display: String
        var token: String
    }

    private static let humanDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private var groups: [(namespace: String, items: [TagItem])] {
        let parsed: [TagItem] = TagParsing.tokens(tags)
            .map { tok in
                let (ns, v) = TagParsing.splitNamespace(tok)
                let display: String
                if TagParsing.isDateNamespace(ns), let d = TagParsing.parseDateValue(v) {
                    display = "\(ns):\(Self.humanDateFormatter.string(from: d))"
                } else {
                    display = tok
                }
                return TagItem(display: display, token: tok)
            }

        let bucket = Dictionary(grouping: parsed) { item -> String in
            let (ns, _) = TagParsing.splitNamespace(item.token)
            return ns.isEmpty ? "tag" : ns.lowercased()
        }
        let keys = bucket.keys.sorted { a, b in
            if a == "tag", b != "tag" { return true }
            if a != "tag", b == "tag" { return false }
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
        return keys.compactMap { k in
            guard let items = bucket[k] else { return nil }
            let sorted = items.sorted { $0.display.localizedCaseInsensitiveCompare($1.display) == .orderedAscending }
            return (namespace: k, items: sorted)
        }
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(groups, id: \.namespace) { group in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(group.namespace == "tag" ? "Tags" : group.namespace)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        FlowLayout(spacing: 4, lineSpacing: 4) {
                            ForEach(group.items, id: \.token) { tag in
                                Text(tag.display)
                                    .font(.caption2)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(.quaternary.opacity(0.6))
                                    .clipShape(Capsule())
                                    .contentShape(Capsule())
                                    .onTapGesture { onSelectTag(tag.token) }
                                    .help("Search: \(tag.display)")
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 2)
        }
        .scrollIndicators(.visible)
        .frame(maxHeight: 220)
    }
}
