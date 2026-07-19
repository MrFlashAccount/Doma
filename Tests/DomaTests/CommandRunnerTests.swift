@testable import Doma
import Darwin
import XCTest

final class CommandRunnerTests: XCTestCase {
    func testTimeoutRemainsDistinctFromTaskCancellation() {
        let result = CommandRunner.run(
            "/bin/sh",
            arguments: ["-c", "sleep 30 & wait"],
            timeout: 0.1
        )

        XCTAssertEqual(result.status, 124)
    }

    func testTaskCancellationTerminatesCommandAndDescendant() async throws {
        let started = Date()
        let task = Task {
            await CommandRunner.runAsync(
                "/bin/sh",
                arguments: ["-c", "sleep 30 & child=$!; echo $child; wait $child"],
                timeout: 30
            )
        }

        try await Task.sleep(for: .milliseconds(250))
        task.cancel()
        let result = await task.value
        let childPID = result.stdout
            .split(whereSeparator: \.isNewline)
            .first
            .flatMap { Int32($0.trimmingCharacters(in: .whitespaces)) }

        XCTAssertEqual(result.status, 130)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        if let childPID {
            XCTAssertNotEqual(Darwin.kill(childPID, 0), 0, "descendant process survived cancellation")
        } else {
            XCTFail("fixture did not report its child PID")
        }
    }
}
