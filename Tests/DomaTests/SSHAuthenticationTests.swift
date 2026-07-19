@testable import Doma
import Foundation
import XCTest

final class SSHAuthenticationTests: XCTestCase {
    func testAskPassConfigurationEnablesInteractiveAuthentication() throws {
        let configuration = SSHAuthentication.configuration(
            askPassPath: "/Applications/Doma.app/Contents/Helpers/DomaAskPass",
            environment: ["PATH": "/usr/bin"]
        )

        XCTAssertEqual(configuration.batchMode, "no")
        XCTAssertEqual(configuration.environment?["SSH_ASKPASS_REQUIRE"], "force")
        XCTAssertEqual(
            configuration.environment?["SSH_ASKPASS"],
            "/Applications/Doma.app/Contents/Helpers/DomaAskPass"
        )
        XCTAssertEqual(configuration.environment?["DISPLAY"], "Doma")
        XCTAssertEqual(configuration.environment?["PATH"], "/usr/bin")
    }

    func testMissingAskPassKeepsNonInteractiveFallback() {
        let configuration = SSHAuthentication.configuration(
            askPassPath: nil,
            environment: ["PATH": "/usr/bin"]
        )

        XCTAssertEqual(configuration.batchMode, "yes")
        XCTAssertNil(configuration.environment)
    }

    func testAuthenticationFailureRequiresManualRetry() {
        let details = SSHConnectionErrorFormatter.details(
            host: "devbox",
            result: failedCommand("Permission denied (publickey,password).")
        )

        XCTAssertFalse(details.shouldRetryAutomatically)
        XCTAssertTrue(details.message.contains("учётные данные"))
        XCTAssertTrue(details.message.contains("devbox"))
    }

    func testNetworkTimeoutKeepsAutomaticRetry() {
        let details = SSHConnectionErrorFormatter.details(
            host: "devbox",
            result: failedCommand("ssh: connect to host devbox port 22: Operation timed out")
        )

        XCTAssertTrue(details.shouldRetryAutomatically)
        XCTAssertTrue(details.message.contains("VPN"))
    }

    func testUnknownFailurePreservesDiagnosticLine() {
        let details = SSHConnectionErrorFormatter.details(
            host: "devbox",
            result: failedCommand("first line\nproxy helper exploded")
        )

        XCTAssertTrue(details.shouldRetryAutomatically)
        XCTAssertTrue(details.message.contains("proxy helper exploded"))
    }

    func testReleaseBuildPackagesAskPassHelper() throws {
        let script = try String(
            contentsOf: repositoryRoot.appendingPathComponent("scripts/build-app.sh"),
            encoding: .utf8
        )

        XCTAssertTrue(script.contains("--product DomaAskPass"))
        XCTAssertTrue(script.contains("HELPERS_DIR=\"$CONTENTS_DIR/Helpers\""))
        XCTAssertTrue(script.contains("chmod 755 \"$HELPERS_DIR/DomaAskPass\""))
    }

    private func failedCommand(_ stderr: String) -> CommandResult {
        CommandResult(status: 255, stdout: "", stderr: stderr)
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
