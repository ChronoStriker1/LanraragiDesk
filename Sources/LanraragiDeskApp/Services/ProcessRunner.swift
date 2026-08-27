import Foundation

struct ProcessRunner {
    final class CompletionBox: @unchecked Sendable {
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

        @discardableResult
        func resume(returning status: Int32) -> Bool {
            let continuation: CheckedContinuation<Int32, Error>?
            lock.lock()
            if isCompleted {
                lock.unlock()
                return false
            }
            isCompleted = true
            continuation = self.continuation
            self.continuation = nil
            if continuation == nil {
                self.pendingResult = .status(status)
            }
            lock.unlock()
            continuation?.resume(returning: status)
            return true
        }

        @discardableResult
        func resume(throwing error: Error) -> Bool {
            let continuation: CheckedContinuation<Int32, Error>?
            lock.lock()
            if isCompleted {
                lock.unlock()
                return false
            }
            isCompleted = true
            continuation = self.continuation
            self.continuation = nil
            if continuation == nil {
                self.pendingResult = .error(error)
            }
            lock.unlock()
            continuation?.resume(throwing: error)
            return true
        }
    }

    struct Result: Sendable {
        let terminationStatus: Int32
        let stdout: String
        let stderr: String
    }

    enum RunnerError: LocalizedError {
        case launchFailed(String)
        case inputWriteFailed(String)
        case timedOut(String)

        var errorDescription: String? {
            switch self {
            case .launchFailed(let description):
                "Failed to launch process: \(description)"
            case .inputWriteFailed(let description):
                "Failed to write process input: \(description)"
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
        let stdinPipe = stdin == nil ? nil : Pipe()
        let completionBox = CompletionBox()

        process.executableURL = executableURL
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        if let stdinPipe {
            process.standardInput = stdinPipe
        }
        if let currentDirectoryURL {
            process.currentDirectoryURL = currentDirectoryURL
        }
        process.terminationHandler = { process in
            completionBox.resume(returning: process.terminationStatus)
        }

        do {
            try process.run()
        } catch {
            closeAfterLaunchFailure(
                stdoutPipe: stdoutPipe,
                stderrPipe: stderrPipe,
                stdinPipe: stdinPipe
            )
            throw RunnerError.launchFailed(error.localizedDescription)
        }

        // The child owns duplicated descriptors after launch. Closing the parent's
        // unused ends is what lets readers and a blocked stdin writer observe EOF.
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()
        try? stdinPipe?.fileHandleForReading.close()

        let stdoutTask = Task {
            try await readToEndOffCooperativeExecutor(stdoutPipe.fileHandleForReading)
        }
        let stderrTask = Task {
            try await readToEndOffCooperativeExecutor(stderrPipe.fileHandleForReading)
        }
        let stdinTask: Task<Void, Error>? = if
            let stdinPipe,
            let stdin
        {
            let inputData = Data(stdin.utf8)
            Task {
                do {
                    try await writeOffCooperativeExecutor(
                        inputData,
                        to: stdinPipe.fileHandleForWriting
                    )
                } catch {
                    throw RunnerError.inputWriteFailed(error.localizedDescription)
                }
            }
        } else {
            nil
        }
        let terminationTask = Task<Int32, Error> {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                completionBox.store(continuation)
            }
        }

        do {
            let status = try await withThrowingTaskGroup(of: Int32.self) { group in
                group.addTask {
                    try await terminationTask.value
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    let error = RunnerError.timedOut(executableURL.lastPathComponent)
                    guard completionBox.resume(throwing: error) else {
                        return try await terminationTask.value
                    }
                    await terminateIfNeeded(process)
                    throw error
                }
                if let stdinTask {
                    group.addTask {
                        do {
                            try await stdinTask.value
                        } catch {
                            // A fast successful child can close its read end before
                            // Foundation publishes termination. Give that callback a
                            // brief chance to claim the result before treating EPIPE
                            // as an independent failure from a still-running child.
                            if process.isRunning {
                                try? await Task.sleep(nanoseconds: 50_000_000)
                            }
                            guard process.isRunning else {
                                return try await terminationTask.value
                            }
                            guard completionBox.resume(throwing: error) else {
                                return try await terminationTask.value
                            }
                            await terminateIfNeeded(process)
                            throw error
                        }

                        // A successful write is not process completion. Keep waiting
                        // on the same single-assignment process result.
                        return try await terminationTask.value
                    }
                }
                let result = try await group.next()
                group.cancelAll()
                terminationTask.cancel()
                return result ?? process.terminationStatus
            }

            // Process termination won the race. A simultaneous broken pipe is a
            // consequence of that exit rather than a replacement result.
            _ = try? await stdinTask?.value
            let stdout = String(decoding: try await stdoutTask.value, as: UTF8.self)
            let stderr = String(decoding: try await stderrTask.value, as: UTF8.self)
            return .init(terminationStatus: status, stdout: stdout, stderr: stderr)
        } catch {
            _ = try? await stdinTask?.value
            _ = try? await stdoutTask.value
            _ = try? await stderrTask.value
            throw error
        }
    }

    private static func closeAfterLaunchFailure(
        stdoutPipe: Pipe,
        stderrPipe: Pipe,
        stdinPipe: Pipe?
    ) {
        try? stdoutPipe.fileHandleForWriting.close()
        try? stdoutPipe.fileHandleForReading.close()
        try? stderrPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForReading.close()
        try? stdinPipe?.fileHandleForWriting.close()
        try? stdinPipe?.fileHandleForReading.close()
    }

    private static func readToEndOffCooperativeExecutor(_ handle: FileHandle) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let data = try handle.readToEnd() ?? Data()
                    try? handle.close()
                    continuation.resume(returning: data)
                } catch {
                    try? handle.close()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func writeOffCooperativeExecutor(_ data: Data, to handle: FileHandle) async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let descriptor = handle.fileDescriptor
                    guard Darwin.fcntl(descriptor, F_SETNOSIGPIPE, 1) != -1 else {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    try handle.write(contentsOf: data)
                    try? handle.close()
                    continuation.resume()
                } catch {
                    try? handle.close()
                    continuation.resume(throwing: error)
                }
            }
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
