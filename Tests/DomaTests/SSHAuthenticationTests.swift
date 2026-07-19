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

    func testChangedHostKeyStopsRetriesAndOffersExplicitRepair() {
        let details = SSHConnectionErrorFormatter.details(
            host: "devbox",
            result: failedCommand(
                """
                @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
                @    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
                @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
                Host key verification failed.
                """
            )
        )

        XCTAssertFalse(details.shouldRetryAutomatically)
        XCTAssertTrue(details.hostKeyChanged)
        XCTAssertTrue(details.message.contains("признаком атаки"))
        XCTAssertTrue(details.message.contains("fingerprint"))
    }

    func testCancelledFirstContactDoesNotOfferStaleKeyRepair() {
        let details = SSHConnectionErrorFormatter.details(
            host: "devbox",
            result: failedCommand("Host key verification failed.")
        )

        XCTAssertFalse(details.shouldRetryAutomatically)
        XCTAssertFalse(details.hostKeyChanged)
    }

    func testKnownHostsPlanUsesEffectiveHostnamePortAndFiles() {
        let plan = SSHKnownHostsManager.plan(
            from: """
            hostname server.example.com
            port 2222
            userknownhostsfile ~/.ssh/known_hosts %d/.ssh/team_hosts
            """,
            homeDirectory: "/Users/demo"
        )

        XCTAssertEqual(
            plan,
            SSHKnownHostsPlan(
                target: "[server.example.com]:2222",
                files: [
                    "/Users/demo/.ssh/known_hosts",
                    "/Users/demo/.ssh/team_hosts",
                ]
            )
        )
    }

    func testKnownHostsPlanHonorsHostKeyAlias() {
        let plan = SSHKnownHostsManager.plan(
            from: """
            hostname server.example.com
            port 22
            hostkeyalias stable-server-key
            userknownhostsfile /Users/demo/.ssh/known_hosts
            """,
            homeDirectory: "/Users/demo"
        )

        XCTAssertEqual(plan?.target, "stable-server-key")
    }

    func testStaleKeyRemovalUsesSSHKeygenAndKeepsBackup() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DomaKnownHostsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let keyPath = directory.appendingPathComponent("test-key").path
        let generation = CommandRunner.run(
            "/usr/bin/ssh-keygen",
            arguments: ["-q", "-t", "ed25519", "-N", "", "-f", keyPath],
            timeout: 5
        )
        XCTAssertEqual(generation.status, 0, generation.stderr)

        let publicKey = try String(contentsOfFile: keyPath + ".pub", encoding: .utf8)
            .split(whereSeparator: \.isWhitespace)
        let knownHosts = directory.appendingPathComponent("known_hosts")
        try "server.example.com \(publicKey[0]) \(publicKey[1])\n".write(
            to: knownHosts,
            atomically: true,
            encoding: .utf8
        )

        let error = SSHKnownHostsManager.removeStaleKey(
            using: SSHKnownHostsPlan(
                target: "server.example.com",
                files: [knownHosts.path]
            )
        )

        XCTAssertNil(error)
        XCTAssertTrue(FileManager.default.fileExists(atPath: knownHosts.path + ".old"))
        XCTAssertFalse(try String(contentsOf: knownHosts, encoding: .utf8).contains("server.example.com"))
    }

    func testAskPassConfirmationWritesAffirmativeResponse() throws {
        let helper = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/DomaAskPass/main.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(helper.contains("Data(\"yes\\n\".utf8)"))
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
