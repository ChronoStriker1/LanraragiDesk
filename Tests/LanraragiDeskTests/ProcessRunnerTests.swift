import Foundation
import XCTest
@testable import LanraragiDesk

@MainActor
final class ProcessRunnerTests: XCTestCase {
    func testCompletedProcessCannotBeReplacedByLateTimeout() async throws {
        let completionBox = ProcessRunner.CompletionBox()
        let waiter = Task<Int32, Error> {
            try await withCheckedThrowingContinuation { continuation in
                completionBox.store(continuation)
            }
        }

        XCTAssertTrue(completionBox.resume(returning: 17))
        XCTAssertFalse(
            completionBox.resume(
                throwing: ProcessRunner.RunnerError.timedOut("test")
            )
        )
        let status = try await waiter.value
        XCTAssertEqual(status, 17)
    }

    func testInputRoundTripsThroughStandardInput() async throws {
        let input = "first line\nsecond line\n"

        let result = try await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/cat"),
            arguments: [],
            stdin: input,
            timeout: 2
        )

        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertEqual(result.stdout, input)
        XCTAssertEqual(result.stderr, "")
    }

    func testRepeatedLaunchFailuresCompletePromptly() async throws {
        let start = Date()

        for iteration in 0..<20 {
            do {
                _ = try await ProcessRunner.run(
                    executableURL: URL(fileURLWithPath: "/definitely/missing/lanraragidesk-test"),
                    arguments: [],
                    stdin: "input \(iteration)",
                    timeout: 1
                )
                XCTFail("Expected launch to fail")
            } catch let error as ProcessRunner.RunnerError {
                guard case .launchFailed = error else {
                    return XCTFail("Expected launchFailed, received \(error)")
                }
            }
        }

        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testBlockedStandardInputStillRespectsTimeout() async throws {
        let input = String(repeating: "x", count: 4 * 1_024 * 1_024)
        let start = Date()

        do {
            _ = try await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["30"],
                stdin: input,
                timeout: 0.1
            )
            XCTFail("Expected process to time out")
        } catch let error as ProcessRunner.RunnerError {
            guard case .timedOut = error else {
                return XCTFail("Expected timedOut, received \(error)")
            }
        }

        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testImmediateSuccessfulExitWinsOverUnreadInputFailure() async throws {
        let input = String(repeating: "x", count: 4 * 1_024 * 1_024)

        let result = try await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: [],
            stdin: input,
            timeout: 2
        )

        XCTAssertEqual(result.terminationStatus, 0)
    }

    func testInputWriteFailureStopsLongRunningChildPromptly() async throws {
        let input = String(repeating: "x", count: 4 * 1_024 * 1_024)
        let start = Date()

        do {
            _ = try await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "exec 0<&-; exec /bin/sleep 30"],
                stdin: input,
                timeout: 10
            )
            XCTFail("Expected the input write to fail")
        } catch let error as ProcessRunner.RunnerError {
            guard case .inputWriteFailed = error else {
                return XCTFail("Expected inputWriteFailed, received \(error)")
            }
        }

        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }
}
