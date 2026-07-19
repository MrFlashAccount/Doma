@testable import Doma
import XCTest

final class RemoteInventoryMonitorTests: XCTestCase {
    func testParserRecognizesMarkersAcrossArbitraryChunks() {
        var parser = RemoteMonitorOutputParser()

        XCTAssertEqual(parser.consume(Data("ignored\n__DOMA_INVEN".utf8)), 0)
        XCTAssertEqual(parser.consume(Data("TORY_CHANGED__ 42 7\n".utf8)), 1)
        XCTAssertEqual(
            parser.consume(Data("__DOMA_INVENTORY_CHANGED__\nnoise\n__DOMA_INVENTORY_CHANGED__ 43 8\n".utf8)),
            2
        )
    }

    func testParserRejectsSimilarButInvalidLines() {
        XCTAssertFalse(RemoteMonitorOutputParser.isChangeLine("DOMA_INVENTORY_CHANGED"))
        XCTAssertFalse(RemoteMonitorOutputParser.isChangeLine("x__DOMA_INVENTORY_CHANGED__ 42"))
        XCTAssertTrue(RemoteMonitorOutputParser.isChangeLine("__DOMA_INVENTORY_CHANGED__ 42 7"))
    }

    func testWatcherHotPathOnlyHashesListeningSocketRows() {
        let script = RemoteInventoryMonitor.watcherScript

        XCTAssertTrue(script.contains("/proc/net/tcp"))
        XCTAssertTrue(script.contains(#"$4 == "0A""#))
        XCTAssertTrue(script.contains(#"port >= "x0400""#))
        XCTAssertTrue(script.contains(#"port <= "x7FFF""#))
        XCTAssertTrue(script.contains("cksum"))
        XCTAssertTrue(script.contains("sleep 1"))
        XCTAssertFalse(script.contains("ss -H"))
        XCTAssertFalse(script.contains("docker ps"))
        XCTAssertFalse(script.contains("ps -eo"))
        XCTAssertFalse(script.contains("/proc/[0-9]"))
    }

    func testWatcherReportsPermanentPermissionAndDependencyFailures() {
        let script = RemoteInventoryMonitor.watcherScript

        XCTAssertTrue(script.contains(RemoteAccessErrorFormatter.permissionMarker))
        XCTAssertTrue(script.contains(RemoteAccessErrorFormatter.dependencyMarker))
        XCTAssertTrue(script.contains("exit 77"))
        XCTAssertTrue(script.contains("exit 127"))
    }

    func testMonitorPermissionFailureStopsAutomaticRetries() {
        let termination = RemoteAccessErrorFormatter.monitorTermination(
            host: "devbox",
            status: 77,
            stderr: "__DOMA_PERMISSION_DENIED__ cannot read /proc/net/tcp"
        )

        XCTAssertFalse(termination.shouldRetryAutomatically)
        XCTAssertTrue(termination.message?.contains("Недостаточно прав") == true)
        XCTAssertTrue(termination.message?.contains("devbox") == true)
    }

    func testInventoryPermissionFailureIsFatalAndActionable() {
        let result = CommandRunner.run(
            "/bin/sh",
            arguments: ["-s"],
            stdin: """
            ss() {
              printf 'ss: Permission denied\\n' >&2
              return 1
            }
            \(TunnelEngine.inventoryScript)
            """,
            timeout: 5
        )
        let details = RemoteAccessErrorFormatter.inventoryDetails(host: "devbox", result: result)

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains(RemoteAccessErrorFormatter.socketScanMarker))
        XCTAssertFalse(details.shouldRetryAutomatically)
        XCTAssertTrue(details.message.contains("Недостаточно прав"))
    }

    func testMetadataPermissionFailuresKeepInventoryUsableWithWarning() {
        let result = CommandRunner.run(
            "/bin/sh",
            arguments: ["-s"],
            stdin: """
            ss() {
              printf 'LISTEN 0 128 127.0.0.1:4321 0.0.0.0:* users:(("demo",pid=42,fd=3))\\n'
            }
            docker() {
              printf 'permission denied while connecting to docker socket\\n' >&2
              return 1
            }
            ps() {
              printf 'permission denied while reading processes\\n' >&2
              return 1
            }
            \(TunnelEngine.inventoryScript)
            """,
            timeout: 5
        )
        let warning = TunnelEngine.inventoryWarning(in: result.stdout)

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("127.0.0.1:4321"))
        XCTAssertTrue(warning?.contains("Метаданные Docker") == true)
        XCTAssertTrue(warning?.contains("Метаданные процессов") == true)
        XCTAssertTrue(warning?.contains("продолжают пробрасываться") == true)
    }

    func testSSHAuthenticationFailureIsNotMistakenForRemotePermissionFailure() {
        let termination = RemoteAccessErrorFormatter.monitorTermination(
            host: "devbox",
            status: 255,
            stderr: "Permission denied, please try again."
        )

        XCTAssertFalse(termination.message?.contains("/proc/net/tcp") == true)
    }
}
