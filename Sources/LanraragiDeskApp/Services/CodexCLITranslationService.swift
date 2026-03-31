import Foundation

struct CodexCLITranslationService: TitleTranslationProviderClient {
    enum ServiceError: LocalizedError {
        case codexNotFound
        case notLoggedIn
        case invocationFailed(String)
        case timedOut
        case invalidJSON
        case missingContent
        case schemaWriteFailed(String)

        var errorDescription: String? {
            switch self {
            case .codexNotFound:
                "Codex CLI not found in PATH."
            case .notLoggedIn:
                "Codex is installed but not logged in. Run `codex login` first."
            case .invocationFailed(let message):
                "Codex translation failed: \(message)"
            case .timedOut:
                "Codex translation timed out."
            case .invalidJSON:
                "Codex returned invalid JSON."
            case .missingContent:
                "Codex did not return a translation payload."
            case .schemaWriteFailed(let message):
                "Failed to prepare Codex schema: \(message)"
            }
        }
    }

    private struct OutputEnvelope: Decodable {
        let items: [OpenAITranslationService.BatchResult]
    }

    private let runnerTimeout: TimeInterval
    private let workingDirectoryURL: URL

    init(
        runnerTimeout: TimeInterval = 300,
        workingDirectoryURL: URL = FileManager.default.temporaryDirectory
    ) {
        self.runnerTimeout = runnerTimeout
        self.workingDirectoryURL = workingDirectoryURL
    }

    func validateEnvironment() async throws {
        let codexURL = try resolveCodexExecutableURL()

        do {
            let login = try await runCodex(
                executableURL: codexURL,
                arguments: ["login", "status"],
                stdin: nil,
                timeout: 30
            )
            let combined = [login.stdout, login.stderr].joined(separator: "\n").lowercased()
            if login.terminationStatus != 0 {
                if combined.contains("not logged in") {
                    throw ServiceError.notLoggedIn
                }
                throw ServiceError.invocationFailed(Self.bestErrorMessage(stdout: login.stdout, stderr: login.stderr))
            }
            guard combined.contains("logged in") else {
                throw ServiceError.notLoggedIn
            }
        } catch let error as ServiceError {
            throw error
        } catch let error as ProcessRunner.RunnerError {
            if case .timedOut = error {
                throw ServiceError.timedOut
            }
            throw ServiceError.invocationFailed(error.localizedDescription)
        } catch {
            throw ServiceError.invocationFailed(error.localizedDescription)
        }
    }

    func translateBatch(
        model: String,
        items: [OpenAITranslationService.BatchItem]
    ) async throws -> [OpenAITranslationService.BatchResult] {
        let payloadJSON = try String(
            data: JSONSerialization.data(withJSONObject: items.map { ["arcid": $0.arcid, "title": $0.title] }, options: [.sortedKeys]),
            encoding: .utf8
        ) ?? "[]"
        let prompt = """
        Detect title language and translate non-English titles to concise natural English.
        Return strict JSON only matching the provided schema.
        Language enum must be one of: english, japanese, korean, chinese, spanish, romanji, other.
        Treat romaji/romanji text as romanji.
        For each item, return arcid, detected_language, english_title, should_translate.
        Keep english_title the same as the input title when should_translate is false.
        Input items: \(payloadJSON)
        """
        let schemaURL = try makeSchemaFileURL()
        defer { try? FileManager.default.removeItem(at: schemaURL) }
        let codexURL = try resolveCodexExecutableURL()

        let result: ProcessRunner.Result
        do {
            result = try await runCodex(
                executableURL: codexURL,
                arguments: [
                    "exec",
                    "--json",
                    "--ephemeral",
                    "--skip-git-repo-check",
                    "--sandbox", "read-only",
                    "-c", "suppress_unstable_features_warning=true",
                    "--model", model,
                    "--output-schema", schemaURL.path,
                    "-"
                ],
                stdin: prompt,
                timeout: runnerTimeout
            )
        } catch let error as ProcessRunner.RunnerError {
            if case .timedOut = error {
                throw ServiceError.timedOut
            }
            throw ServiceError.invocationFailed(error.localizedDescription)
        } catch {
            throw ServiceError.invocationFailed(error.localizedDescription)
        }

        guard result.terminationStatus == 0 else {
            let message = Self.bestErrorMessage(stdout: result.stdout, stderr: result.stderr)
            throw ServiceError.invocationFailed(message)
        }

        guard let content = Self.extractAgentMessage(from: result.stdout), !content.isEmpty else {
            throw ServiceError.missingContent
        }

        guard let data = content.data(using: .utf8) else {
            throw ServiceError.invalidJSON
        }

        do {
            let envelope = try JSONDecoder().decode(OutputEnvelope.self, from: data)
            return envelope.items
        } catch {
            throw ServiceError.invalidJSON
        }
    }

    private func runCodex(
        executableURL: URL,
        arguments: [String],
        stdin: String?,
        timeout: TimeInterval
    ) async throws -> ProcessRunner.Result {
        try await ProcessRunner.run(
            executableURL: executableURL,
            arguments: arguments,
            currentDirectoryURL: workingDirectoryURL,
            environment: processEnvironment(),
            stdin: stdin,
            timeout: timeout
        )
    }

    private func resolveCodexExecutableURL() throws -> URL {
        let fileManager = FileManager.default
        let envPaths = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        let candidatePaths = envPaths.map { URL(fileURLWithPath: $0).appendingPathComponent("codex").path } + [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(NSHomeDirectory())/.local/bin/codex"
        ]

        for path in candidatePaths {
            if fileManager.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }

        throw ServiceError.codexNotFound
    }

    private func processEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let preferredPaths = [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        let existingPaths = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        let mergedPaths = Array(NSOrderedSet(array: preferredPaths + existingPaths)).compactMap { $0 as? String }
        environment["PATH"] = mergedPaths.joined(separator: ":")
        return environment
    }

    private func makeSchemaFileURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-title-translation-schema-\(UUID().uuidString)")
            .appendingPathExtension("json")
        let schema = """
        {
          "type": "object",
          "properties": {
            "items": {
              "type": "array",
              "items": {
                "type": "object",
                "properties": {
                  "arcid": { "type": "string" },
                  "detected_language": {
                    "type": "string",
                    "enum": ["english", "japanese", "korean", "chinese", "spanish", "romanji", "other"]
                  },
                  "english_title": { "type": "string" },
                  "should_translate": { "type": "boolean" }
                },
                "required": ["arcid", "detected_language", "english_title", "should_translate"],
                "additionalProperties": false
              }
            }
          },
          "required": ["items"],
          "additionalProperties": false
        }
        """
        do {
            try schema.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            throw ServiceError.schemaWriteFailed(error.localizedDescription)
        }
    }

    private static func extractAgentMessage(from stdout: String) -> String? {
        var lastMessage: String?
        for line in stdout.split(whereSeparator: \.isNewline) {
            guard
                let data = String(line).data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let type = json["type"] as? String,
                type == "item.completed",
                let item = json["item"] as? [String: Any],
                let itemType = item["type"] as? String,
                itemType == "agent_message",
                let text = item["text"] as? String
            else {
                continue
            }
            lastMessage = text
        }
        return lastMessage
    }

    private static func bestErrorMessage(stdout: String, stderr: String) -> String {
        let trimmedStderr = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedStderr.isEmpty {
            return trimmedStderr
        }
        let trimmedStdout = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedStdout.isEmpty {
            return trimmedStdout
        }
        return "Unknown Codex CLI failure."
    }
}
