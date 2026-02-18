import AppKit
import SwiftUI
import LanraragiKit
import WebKit

struct StatisticsView: View {
    @EnvironmentObject private var appModel: AppModel
    let profile: Profile

    @State private var minWeight: Int = 2
    @State private var filterText: String = ""
    @State private var isLoading: Bool = false
    @State private var statusText: String?
    @State private var serverInfo: ServerInfo?

    @State private var allWords: [Word] = []
    @State private var detailedWords: [Word] = []
    @State private var renderedDetailCount: Int = 0
    @State private var stageTask: Task<Void, Never>?

    @State private var showDetailedStats: Bool = false

    private let maxRenderableCloudWords: Int = 1000
    private let maxRenderableDetailWords: Int = 8000
    private let firstDetailBatchSize: Int = 320
    private let stageDetailBatchSize: Int = 320

    struct Word: Identifiable, Hashable {
        let id: String
        let namespace: String
        let text: String
        let tag: String
        let weight: Int
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if isLoading && allWords.isEmpty {
                ProgressView("Loading tag statistics…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            } else if allWords.isEmpty {
                ContentUnavailableView(
                    "No Statistics Yet",
                    systemImage: "chart.bar.xaxis",
                    description: Text(statusText ?? "Press Refresh to load tag statistics from your server.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 14) {
                        statsHeaderCard
                        cloudSection
                        detailedSection
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                }
                .scrollIndicators(.visible)
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(18)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .task(id: profile.id) {
            let defaults = UserDefaults.standard
            if defaults.object(forKey: "tags.minWeight") == nil {
                minWeight = 2
                defaults.set(2, forKey: "tags.minWeight")
            } else {
                minWeight = max(0, defaults.integer(forKey: "tags.minWeight"))
            }
            await refresh()
        }
        .onDisappear {
            stageTask?.cancel()
            stageTask = nil
        }
        .onChange(of: showDetailedStats) { _, expanded in
            guard expanded else { return }
            let detailCap = min(detailedWords.count, maxRenderableDetailWords)
            if renderedDetailCount == 0 && detailCap > 0 {
                renderedDetailCount = min(firstDetailBatchSize, detailCap)
            }
            stageRender()
        }
        .debugFrameNumber(1)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Statistics")
                .font(.title2)
                .bold()

            Spacer()

            Stepper("Min weight: \(minWeight)", value: $minWeight, in: 0...999)
                .frame(width: 180, alignment: .trailing)
                .disabled(isLoading)
                .onChange(of: minWeight) { _, v in
                    UserDefaults.standard.set(max(0, v), forKey: "tags.minWeight")
                    Task { await refresh() }
                }

            TextField("Filter tags…", text: $filterText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .disabled(isLoading)

            Button("Refresh") {
                Task { await refresh() }
            }
            .disabled(isLoading)
        }
    }

    private var statsHeaderCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 18) {
                StatPill(systemImage: "books.vertical.fill", title: "Archives", value: serverInfo?.total_archives.map(String.init) ?? "—", iconColor: .blue)
                StatPill(systemImage: "tags.fill", title: "Different tags", value: String(allWords.count), iconColor: .purple)
                StatPill(systemImage: "book.fill", title: "Pages read", value: serverInfo?.total_pages_read.map(String.init) ?? "—", iconColor: .orange)
                Spacer()
            }

            Text("Tag cloud: showing \(cloudVisibleWords.count) tags of \(allWords.count) total.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if allWords.count > maxRenderableCloudWords && filterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Cloud rendering is capped to \(maxRenderableCloudWords) tags for responsiveness.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let statusText, !statusText.isEmpty {
                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var cloudSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tag Cloud")
                .font(.headline)

            if cloudVisibleWords.isEmpty {
                Text("No tags to display.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                StatisticsCloudWebView(
                    words: cloudVisibleWords,
                    baseURL: profile.baseURL
                ) { token in
                    openTagSearchToken(token)
                }
                .frame(height: 500)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(.quaternary.opacity(0.45), lineWidth: 1)
                )
            }
        }
    }

    private var detailedSection: some View {
        Group {
            if !detailedWords.isEmpty {
                DisclosureGroup("Detailed Stats", isExpanded: $showDetailedStats) {
                    VStack(alignment: .leading, spacing: 10) {
                        if detailedVisibleWords.isEmpty {
                            Text("No matching tags.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
                                ForEach(detailedVisibleWords) { word in
                                    Button {
                                        openTagSearch(word)
                                    } label: {
                                        HStack(spacing: 8) {
                                            Text(word.tag)
                                                .lineLimit(nil)
                                                .fixedSize(horizontal: false, vertical: true)
                                                .frame(maxWidth: .infinity, alignment: .leading)

                                            Text("(\(word.weight))")
                                                .font(.caption.monospacedDigit().weight(.bold))
                                                .foregroundStyle(.secondary)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .buttonStyle(.plain)
                                    .help("\(word.tag) (\(word.weight))")
                                }
                            }
                        }

                        Text("(Detailed stats exclude namespaces `source` and `date_added`, matching LANraragi stats.)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)
                }
            }
        }
    }

    private var cloudVisibleWords: [Word] {
        let needle = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if needle.isEmpty {
            let limit = min(allWords.count, maxRenderableCloudWords)
            return Array(allWords.prefix(limit))
        }
        let matched = allWords.lazy.filter { $0.tag.lowercased().contains(needle) }
        return Array(matched.prefix(maxRenderableCloudWords))
    }

    private var detailedVisibleWords: [Word] {
        guard showDetailedStats else { return [] }
        let needle = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if needle.isEmpty {
            let limit = min(renderedDetailCount, min(detailedWords.count, maxRenderableDetailWords))
            return Array(detailedWords.prefix(limit))
        }
        let matched = detailedWords.lazy.filter { $0.tag.lowercased().contains(needle) }
        return Array(matched.prefix(maxRenderableDetailWords))
    }

    private func refresh() async {
        stageTask?.cancel()
        stageTask = nil

        isLoading = true
        statusText = "Loading…"
        defer { isLoading = false }

        do {
            let account = "apiKey.\(profile.id.uuidString)"
            let apiKeyString = try KeychainService.getString(account: account)
            let apiKey = apiKeyString.map { LANraragiAPIKey($0) }

            let client = LANraragiClient(configuration: .init(
                baseURL: profile.baseURL,
                apiKey: apiKey,
                acceptLanguage: profile.language,
                maxConnectionsPerHost: AppSettings.maxConnectionsPerHost(defaultValue: 8)
            ))

            async let statsReq = client.getDatabaseStats(minWeight: minWeight)
            async let infoReq = client.getServerInfo()

            let loaded = try await statsReq
            let info = try? await infoReq

            let mapped = mapWords(from: loaded.tags)
            allWords = mapped
            detailedWords = mapped.filter { $0.namespace != "source" && $0.namespace != "date_added" }
            serverInfo = info

            if showDetailedStats {
                renderedDetailCount = min(firstDetailBatchSize, min(detailedWords.count, maxRenderableDetailWords))
            } else {
                renderedDetailCount = 0
            }

            statusText = "Loaded \(allWords.count) tags."
            appModel.activity.add(.init(kind: .action, title: "Loaded statistics", detail: "tags \(allWords.count)"))

            stageRender()
        } catch {
            allWords = []
            detailedWords = []
            renderedDetailCount = 0
            statusText = "Failed: \(ErrorPresenter.short(error))"
            appModel.activity.add(.init(kind: .error, title: "Statistics load failed", detail: String(describing: error)))
        }
    }

    private func stageRender() {
        stageTask?.cancel()
        let detailCap = min(detailedWords.count, maxRenderableDetailWords)
        let detailPending = showDetailedStats && renderedDetailCount < detailCap
        guard detailPending else { return }

        stageTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 90_000_000)
                if Task.isCancelled { return }
                await MainActor.run {
                    if showDetailedStats && renderedDetailCount < detailCap {
                        renderedDetailCount = min(detailCap, renderedDetailCount + stageDetailBatchSize)
                    }
                }
                if !showDetailedStats || renderedDetailCount >= detailCap {
                    return
                }
            }
        }
    }

    private func mapWords(from tags: [TagStat]) -> [Word] {
        var out: [Word] = []
        out.reserveCapacity(tags.count)

        var seen: Set<String> = []

        for t in tags {
            let ns = (t.namespace ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let tx = (t.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let tag: String = {
                if !ns.isEmpty, !tx.isEmpty { return "\(ns):\(tx)" }
                return tx
            }()
            if tag.isEmpty { continue }
            if !seen.insert(tag).inserted { continue }

            let weight = max(0, t.weight ?? t.count ?? 0)
            out.append(Word(id: tag, namespace: ns, text: tx, tag: tag, weight: weight))
        }

        out.sort { a, b in
            if a.weight != b.weight { return a.weight > b.weight }
            return a.tag.localizedCaseInsensitiveCompare(b.tag) == .orderedAscending
        }

        return out
    }

    private func openTagSearch(_ word: Word) {
        let token = word.namespace.isEmpty ? word.text : "\(word.namespace):\(word.text)"
        openTagSearchToken(token)
    }

    private func openTagSearchToken(_ token: String) {
        let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanToken.isEmpty else { return }
        appModel.requestLibrarySearch(profileID: profile.id, query: cleanToken)
    }
}

private struct StatPill: View {
    let systemImage: String
    let title: String
    let value: String
    var iconColor: Color = .secondary

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(iconColor.opacity(0.15))
                    .frame(width: 38, height: 38)
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(iconColor)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.title2.bold().monospacedDigit())
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct StatisticsCloudWebView: NSViewRepresentable {
    let words: [StatisticsView.Word]
    let baseURL: URL
    let onTagTap: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onTagTap: onTagTap)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.suppressesIncrementalRendering = true
        config.userContentController.add(context.coordinator, name: Coordinator.messageName)

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = false
        webView.loadHTMLString(Coordinator.htmlTemplate, baseURL: baseURL)
        context.coordinator.currentBaseURL = baseURL
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if context.coordinator.currentBaseURL != baseURL {
            context.coordinator.currentBaseURL = baseURL
            context.coordinator.lastWordsSignature = nil
            context.coordinator.ready = false
            webView.loadHTMLString(Coordinator.htmlTemplate, baseURL: baseURL)
        }

        context.coordinator.push(words: words, into: webView)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.messageName)
        nsView.navigationDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        static let messageName = "tagTap"

        static let htmlTemplate = """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width,initial-scale=1">
          <link rel="stylesheet" href="/css/vendor/jqcloud.min.css">
          <style>
            html, body {
              margin: 0;
              width: 100%;
              height: 100%;
              overflow: hidden;
              background: transparent;
            }
            #tagCloud {
              width: 100%;
              height: 500px;
            }
            #tagCloud .jqcloud-word {
              cursor: pointer;
              user-select: none;
              text-shadow: 0 1px 2px rgba(0, 0, 0, 0.55);
            }
            #tagCloud .ns-artist { color: #6ea8ff !important; }
            #tagCloud .ns-group { color: #ffa94d !important; }
            #tagCloud .ns-character { color: #ff75c3 !important; }
            #tagCloud .ns-series { color: #9b8cff !important; }
            #tagCloud .ns-language { color: #6fda8b !important; }
            #tagCloud .ns-source { color: #4fd1c5 !important; }
          </style>
          <script src="/js/vendor/jquery.min.js"></script>
          <script src="/js/vendor/jqcloud.min.js"></script>
          <script>
            window.__cloudReady = false;

            function decodeWords(base64Payload) {
              try {
                return JSON.parse(atob(base64Payload));
              } catch (_) {
                return [];
              }
            }

            function namespaceClass(namespaceValue) {
              const safe = String(namespaceValue || "").replace(/[^a-z0-9_-]/gi, "");
              return safe.length ? "ns-" + safe : "";
            }

            function buildWordItems(words) {
              return words.map((word) => ({
                text: word.text,
                weight: Math.max(1, Number(word.weight || 1)),
                html: {
                  class: ("jqcloud-word " + namespaceClass(word.namespace)).trim(),
                  title: word.text + " (" + word.weight + ")",
                  "data-token": word.token
                }
              }));
            }

            function renderFallback(words) {
              const host = document.getElementById("tagCloud");
              if (!host) return;
              host.innerHTML = words.map((w) => "<span class='jqcloud-word' data-token='" +
                String(w.token).replace(/'/g, "&#39;") + "'>" +
                String(w.text).replace(/</g, "&lt;").replace(/>/g, "&gt;") + "</span>").join(" ");
            }

            window.renderCloudFromBase64 = function(base64Payload) {
              const sourceWords = decodeWords(base64Payload);
              const host = $("#tagCloud");
              if (!host.length) return;

              if (!window.jQuery || !$.fn || !$.fn.jQCloud) {
                renderFallback(sourceWords);
                return;
              }

              const cloudWords = buildWordItems(sourceWords);
              try { host.jQCloud("destroy"); } catch (_) {}
              host.empty();
              host.jQCloud(cloudWords, {
                autoResize: true,
                removeOverflowing: false,
                delay: 18
              });
            };

            $(document).on("click.statsCloud", "#tagCloud .jqcloud-word", function(event) {
              event.preventDefault();
              const token = this.getAttribute("data-token") || this.textContent || "";
              if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.tagTap) {
                window.webkit.messageHandlers.tagTap.postMessage(token);
              }
              return false;
            });

            window.addEventListener("load", function() {
              window.__cloudReady = true;
            });
          </script>
        </head>
        <body>
          <div id="tagCloud"></div>
        </body>
        </html>
        """

        struct CloudWordPayload: Encodable {
            let token: String
            let text: String
            let namespace: String
            let weight: Int
        }

        let onTagTap: (String) -> Void
        var currentBaseURL: URL?
        var lastWordsSignature: Int?
        var ready: Bool = false
        var pendingPayload: String?

        init(onTagTap: @escaping (String) -> Void) {
            self.onTagTap = onTagTap
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            ready = true
            if let pendingPayload {
                runRender(payloadBase64: pendingPayload, in: webView)
                self.pendingPayload = nil
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == Self.messageName else { return }
            guard let token = message.body as? String else { return }
            onTagTap(token)
        }

        func push(words: [StatisticsView.Word], into webView: WKWebView) {
            var hasher = Hasher()
            hasher.combine(words.count)
            for word in words {
                hasher.combine(word.id)
                hasher.combine(word.weight)
            }
            let signature = hasher.finalize()
            guard signature != lastWordsSignature else { return }
            lastWordsSignature = signature

            let payloadWords = words.map {
                CloudWordPayload(token: $0.tag, text: $0.tag, namespace: $0.namespace, weight: max(1, $0.weight))
            }
            guard let payloadData = try? JSONEncoder().encode(payloadWords) else { return }
            let payloadBase64 = payloadData.base64EncodedString()

            if ready {
                runRender(payloadBase64: payloadBase64, in: webView)
            } else {
                pendingPayload = payloadBase64
            }
        }

        private func runRender(payloadBase64: String, in webView: WKWebView) {
            let js = "window.renderCloudFromBase64('\(payloadBase64)');"
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }
}
