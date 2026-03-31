import Foundation

struct ProcessRunner {
    private final class CompletionBox: @unchecked Sendable {
        private enum PendingResult {
            case status(Int32)
            case error(any Error)
        }

        private let lock = NSLock()
        private var isCompleted = false
        private var continuation: CheckedContinuation<Int32, Error>?
        private var pendingResult: PendingResult?

        func store(_ continuation: CheckedContinuation<Int32, Error>) {
            let pendingResult: PendingResult?
            lock.lock()
            if isCompleted {
                pendingResult = self.pendingResult
                self.pendingResult = nil
                lock.unlock()
                switch pendingResult {
                case .status(let status):
                    continuation.resume(returning: status)
                case .error(let error):
                    continuation.resume(throwing: error)
                case nil:
                    continuation.resume(throwing: RunnerError.launchFailed("Process completed before continuation was stored."))
                }
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        func resume(returning status: Int32) {
            let continuation: CheckedContinuation<Int32, Error>?
            lock.lock()
            if isCompleted {
                lock.unlock()
                return
            }
            isCompleted = true
            continuation = self.continuation
            self.continuation = nil
            if continuation == nil {
                self.pendingResult = .status(status)
            }
            lock.unlock()
            continuation?.resume(returning: status)
        }

        func resume(throwing error: Error) {
            let continuation: CheckedContinuation<Int32, Error>?
            lock.lock()
            if isCompleted {
                lock.unlock()
                return
            }
            isCompleted = true
            continuation = self.continuation
            self.continuation = nil
            if continuation == nil {
                self.pendingResult = .error(error)
            }
            lock.unlock()
            continuation?.resume(throwing: error)
        }
    }

    struct Result: Sendable {
        let terminationStatus: Int32
        let stdout: String
        let stderr: String
    }

    enum RunnerError: LocalizedError {
        case launchFailed(String)
        case timedOut(String)

        var errorDescription: String? {
            switch self {
            case .launchFailed(let description):
                "Failed to launch process: \(description)"
            case .timedOut(let description):
                "\(description) timed out."
            }
        }
    }

    static func run(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL? = nil,
        environment: [String: String]? = nil,
        stdin: String? = nil,
        timeout: TimeInterval
    ) async throws -> Result {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        let completionBox = CompletionBox()

        process.executableURL = executableURL
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        if stdin != nil {
            process.standardInput = stdinPipe
        }
        if let currentDirectoryURL {
            process.currentDirectoryURL = currentDirectoryURL
        }
        process.terminationHandler = { process in
            completionBox.resume(returning: process.terminationStatus)
        }

        let stdoutTask = Task.detached(priority: nil) {
            stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        }
        let stderrTask = Task.detached(priority: nil) {
            stderrPipe.fileHandleForReading.readDataToEndOfFile()
        }
        let terminationTask = Task<Int32, Error> {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                completionBox.store(continuation)
            }
        }

        do {
            try process.run()
        } catch {
            completionBox.resume(throwing: error)
            throw RunnerError.launchFailed(error.localizedDescription)
        }

        if let stdin {
            if let data = stdin.data(using: .utf8) {
                stdinPipe.fileHandleForWriting.write(data)
            }
            try? stdinPipe.fileHandleForWriting.close()
        }

        do {
            let status = try await withThrowingTaskGroup(of: Int32.self) { group in
                group.addTask {
                    try await terminationTask.value
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    await terminateIfNeeded(process)
                    let error = RunnerError.timedOut(executableURL.lastPathComponent)
                    completionBox.resume(throwing: error)
                    throw error
                }
                let result = try await group.next()
                group.cancelAll()
                terminationTask.cancel()
                return result ?? process.terminationStatus
            }

            let stdout = String(decoding: await stdoutTask.value, as: UTF8.self)
            let stderr = String(decoding: await stderrTask.value, as: UTF8.self)
            return .init(terminationStatus: status, stdout: stdout, stderr: stderr)
        } catch {
            let _ = await stdoutTask.value
            let _ = await stderrTask.value
            throw error
        }
    }

    private static func terminateIfNeeded(_ process: Process) async {
        guard process.isRunning else { return }
        process.terminate()
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        guard process.isRunning else { return }
        process.interrupt()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        guard process.isRunning else { return }
        Darwin.kill(process.processIdentifier, SIGKILL)
    }
}
