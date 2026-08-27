import Foundation
import XCTest
@testable import LanraragiDesk

@MainActor
final class ProcessRunnerTests: XCTestCase {
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
}
