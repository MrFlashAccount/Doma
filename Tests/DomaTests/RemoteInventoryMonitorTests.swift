@testable import Doma
import XCTest

final class RemoteInventoryMonitorTests: XCTestCase {
    func testParserRecognizesMarkersAcrossArbitraryChunks() {
        var parser = RemoteMonitorOutputParser()

        XCTAssertEqual(
            parser.consume(Data("ignored\n__DOMA_INVEN".utf8)),
            RemoteMonitorParseResult(changeDetected: false, protocolError: nil)
        )
        XCTAssertEqual(
            parser.consume(Data("TORY_CHANGED__ 42 7\n".utf8)),
            RemoteMonitorParseResult(changeDetected: true, protocolError: nil)
        )
        XCTAssertEqual(
            parser.consume(Data("__DOMA_INVENTORY_CHANGED__\nnoise\n__DOMA_INVENTORY_CHANGED__ 43 8\n".utf8)),
            RemoteMonitorParseResult(changeDetected: true, protocolError: nil)
        )
    }

    func testParserRejectsSimilarButInvalidLines() {
        XCTAssertFalse(RemoteMonitorOutputParser.isChangeLine("DOMA_INVENTORY_CHANGED"))
        XCTAssertFalse(RemoteMonitorOutputParser.isChangeLine("x__DOMA_INVENTORY_CHANGED__ 42"))
        XCTAssertTrue(RemoteMonitorOutputParser.isChangeLine("__DOMA_INVENTORY_CHANGED__ 42 7"))
    }

    func testParserBoundsHostileNoNewlineOutput() {
        var parser = RemoteMonitorOutputParser()
        let result = parser.consume(Data(repeating: 0x41, count: 20_000))

        XCTAssertFalse(result.changeDetected)
        XCTAssertNotNil(result.protocolError)
    }

    func testParserCoalescesMarkerFloodAndFailsSafely() {
        var parser = RemoteMonitorOutputParser()
        let flood = String(repeating: "__DOMA_INVENTORY_CHANGED__\n", count: 600)
        let result = parser.consume(Data(flood.utf8))

        XCTAssertNotNil(result.protocolError)
    }

    func testWatcherHotPathHashesListenersAndZrokProcessMetadata() {
        let script = RemoteInventoryMonitor.watcherScript

        XCTAssertTrue(script.contains("/proc/net/tcp"))
        XCTAssertTrue(script.contains("/proc/net/tcp6"))
        XCTAssertTrue(script.contains(#"$4 == "0A""#))
        XCTAssertTrue(script.contains(#"port >= "x0400""#))
        XCTAssertTrue(script.contains(#"port <= "xFFFF""#))
        XCTAssertTrue(script.contains("candidate_count"))
        XCTAssertTrue(script.contains(#"[ "$candidate_count" -ge 5 ]"#))
        XCTAssertTrue(script.contains("print FILENAME, $2"))
        XCTAssertFalse(script.contains("print FILENAME, $2, $10"))
        XCTAssertTrue(script.contains("cksum"))
        XCTAssertTrue(script.contains("sleep 1"))
        XCTAssertTrue(script.contains("ps -C zrok -o pid=,args="))
        XCTAssertFalse(script.contains("ss -H"))
        XCTAssertFalse(script.contains("docker ps"))
        XCTAssertFalse(script.contains("ps -eo"))
        XCTAssertFalse(script.contains("/proc/[0-9]"))
    }

    func testWatcherDetectsZrokProcessChangesWithoutListenerChanges() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DomaWatcherZrokTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let tcp = directory.appendingPathComponent("tcp")
        let missingTCP6 = directory.appendingPathComponent("tcp6")
        try "header\n".write(to: tcp, atomically: true, encoding: .utf8)
        let script = """
        sample=0
        ps() {
          if [ "$sample" -ge 1 ]; then
            printf '%s\\n' '321 zrok zrok share public http://127.0.0.1:8765'
            return 0
          fi
          return 1
        }
        sleep() {
          sample=$((sample + 1))
          if [ "$sample" -ge 6 ]; then
            exit 0
          fi
        }
        \(RemoteInventoryMonitor.watcherScript
            .replacingOccurrences(of: "/proc/net/tcp6", with: missingTCP6.path)
            .replacingOccurrences(of: "/proc/net/tcp", with: tcp.path))
        """

        let result = CommandRunner.run("/bin/sh", arguments: ["-s"], stdin: script, timeout: 2)
        let markers = result.stdout.split(separator: "\n").filter {
            RemoteMonitorOutputParser.isChangeLine(String($0))
        }

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(markers.count, 2, result.stdout)
    }

    func testWatcherReportsPermanentPermissionAndDependencyFailures() {
        let script = RemoteInventoryMonitor.watcherScript

        XCTAssertTrue(script.contains(RemoteAccessErrorFormatter.permissionMarker))
        XCTAssertTrue(script.contains(RemoteAccessErrorFormatter.dependencyMarker))
        XCTAssertTrue(script.contains(RemoteAccessErrorFormatter.watcherReadMarker))
        XCTAssertTrue(script.contains("exit 77"))
        XCTAssertTrue(script.contains("exit 127"))
    }

    func testWatcherIgnoresTransientListenerFlaps() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DomaWatcherDebounceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let tcp = directory.appendingPathComponent("tcp")
        let missingTCP6 = directory.appendingPathComponent("tcp6")
        try "header\n".write(to: tcp, atomically: true, encoding: .utf8)
        let tcpPath = tcp.path.replacingOccurrences(of: "'", with: "'\\''")
        let listener = "0: 0100007F:4AF6 00000000:0000 0A 00000000:00000000 "
            + "00:00000000 00000000 1000 0 12345 1 0000000000000000 100 0 0 10 0"
        let escapedListener = listener.replacingOccurrences(of: "'", with: "'\\''")
        let script = """
        step=0
        sleep() {
          step=$((step + 1))
          case "$step" in
            1|3) printf '%s\\n' '\(escapedListener)' > '\(tcpPath)' ;;
            2|4) printf 'header\\n' > '\(tcpPath)' ;;
            5) exit 0 ;;
          esac
        }
        \(RemoteInventoryMonitor.watcherScript
            .replacingOccurrences(of: "/proc/net/tcp6", with: missingTCP6.path)
            .replacingOccurrences(of: "/proc/net/tcp", with: tcp.path))
        """

        let result = CommandRunner.run("/bin/sh", arguments: ["-s"], stdin: script, timeout: 2)
        let markers = result.stdout.split(separator: "\n").filter {
            RemoteMonitorOutputParser.isChangeLine(String($0))
        }

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(markers.count, 1, result.stdout)
    }

    func testWatcherRejectsUnreadableTCP6InsteadOfMaskingIt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DomaWatcherTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let tcp = directory.appendingPathComponent("tcp")
        let tcp6 = directory.appendingPathComponent("tcp6")
        try "header\n".write(to: tcp, atomically: true, encoding: .utf8)
        try "header\n".write(to: tcp6, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: tcp6.path)
        let script = RemoteInventoryMonitor.watcherScript
            .replacingOccurrences(of: "/proc/net/tcp6", with: tcp6.path)
            .replacingOccurrences(of: "/proc/net/tcp", with: tcp.path)

        let result = CommandRunner.run("/bin/sh", arguments: ["-s"], stdin: script, timeout: 2)

        XCTAssertEqual(result.status, 77, result.stderr)
        XCTAssertTrue(result.stderr.contains(RemoteAccessErrorFormatter.permissionMarker))
        XCTAssertTrue(result.stderr.contains(tcp6.path))
    }

    func testWatcherReadFailureRetriesAndPermissionFailureDoesNot() {
        let transient = RemoteAccessErrorFormatter.monitorTermination(
            host: "devbox",
            status: 75,
            stderr: "__DOMA_WATCHER_READ_FAILED__ /proc/net/tcp6 vanished"
        )
        let permanent = RemoteAccessErrorFormatter.monitorTermination(
            host: "devbox",
            status: 77,
            stderr: "__DOMA_PERMISSION_DENIED__ cannot read /proc/net/tcp6"
        )

        XCTAssertTrue(transient.shouldRetryAutomatically)
        XCTAssertTrue(transient.message?.contains("Временная ошибка") == true)
        XCTAssertFalse(permanent.shouldRetryAutomatically)
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

    func testPartialSocketAndProcessMetadataProduceNonfatalWarning() {
        let output = """
        __SS__
        LISTEN 0 128 127.0.0.1:4321 0.0.0.0:*
        LISTEN 0 128 127.0.0.1:4322 0.0.0.0:* users:(("demo",pid=42,fd=3))
        __DOCKER__
        __PS__
        __CWD__
        """

        let warning = TunnelEngine.inventoryWarning(in: output)

        XCTAssertTrue(warning?.contains("без PID") == true)
        XCTAssertTrue(warning?.contains("не сопоставилась") == true)
        XCTAssertTrue(warning?.contains("продолжают работать") == true)
    }

    func testUniformlyUnavailableSocketProcessMetadataIsNotANoisyWarning() {
        let output = """
        __SS__
        LISTEN 0 128 127.0.0.1:4321 0.0.0.0:*
        LISTEN 0 128 127.0.0.1:4322 0.0.0.0:*
        __DOCKER__
        __PS__
        __CWD__
        """

        XCTAssertNil(TunnelEngine.inventoryWarning(in: output))
    }

    func testCompletenessWarningsIgnoreHiddenAndForeignOwnedSockets() {
        let output = """
        __USER__
        518636
        __SS__
        LISTEN 0 5 127.0.0.1:4188 0.0.0.0:* users:(("python3",pid=1033060,fd=3)) uid:518636 ino:1
        LISTEN 0 128 *:6881 *:* uid:1044 ino:2
        LISTEN 0 128 127.0.0.1:6882 0.0.0.0:* uid:1044 ino:3
        LISTEN 0 1 127.0.0.1:10005 0.0.0.0:* ino:4
        LISTEN 0 4096 127.0.0.1:32788 0.0.0.0:* ino:5
        LISTEN 0 4096 [::1]:38323 [::]:* uid:518636 ino:6
        __DOCKER__
        transformator-poc|gcr.io/k8s-minikube/kicbase:v0.0.50|127.0.0.1:32788->22/tcp|||
        __PS__
        1033060 1 518636 sergeigarin python3 python3 -m http.server 4188
        __CWD__
        """

        XCTAssertNil(TunnelEngine.inventoryWarning(in: output))
        XCTAssertEqual(
            Set(TunnelEngine.services(fromInventoryOutput: output).map(\.port)),
            [4188, 6881, 6882, 10005, 32788]
        )
    }

    func testMissingMandatorySocketSectionIsRejected() {
        let output = """
        __DOCKER__
        __PS__
        __CWD__
        """

        XCTAssertFalse(TunnelEngine.hasMandatorySocketSection(in: output))
    }

    func testEveryOwnedSSHSessionDisablesAmbientForwardingAndLocalCommands() {
        let authentication = SSHAuthenticationConfiguration(batchMode: "no", environment: nil)
        let argumentSets = [
            TunnelEngine.masterArguments(
                host: "devbox",
                socket: "/tmp/doma-test.sock",
                authentication: authentication,
                requiresExplicitConfirmation: true
            ),
            TunnelEngine.inventoryArguments(host: "devbox", socket: "/tmp/doma-test.sock"),
            RemoteInventoryMonitor.sshArguments(host: "devbox", socketPath: "/tmp/doma-test.sock"),
        ]

        for arguments in argumentSets {
            XCTAssertTrue(arguments.containsConsecutive("-o", "ForwardAgent=no"))
            XCTAssertTrue(arguments.containsConsecutive("-o", "ForwardX11=no"))
            XCTAssertTrue(arguments.containsConsecutive("-o", "PermitLocalCommand=no"))
            XCTAssertFalse(arguments.contains("ClearAllForwardings=yes"))
        }
    }

    func testSSHAuthenticationFailureIsNotMistakenForRemotePermissionFailure() {
        let termination = RemoteAccessErrorFormatter.monitorTermination(
            host: "devbox",
            status: 255,
            stderr: "Permission denied, please try again."
        )

        XCTAssertFalse(termination.message?.contains("/proc/net/tcp") == true)
    }

    func testControlMasterLossIsConnectionFailureNotPortConflict() {
        let result = TunnelEngine.connectionLostResult(
            input: CycleInput(
                host: "devbox",
                previousMasterPID: 42,
                activeForwards: [4321],
                missingSince: [:]
            ),
            result: CommandResult(
                status: 255,
                stdout: "",
                stderr: "Control socket connect: Connection refused"
            )
        )

        XCTAssertEqual(result.state, .failed)
        XCTAssertTrue(result.conflicts.isEmpty)
        XCTAssertNil(result.masterPID)
        XCTAssertTrue(result.error?.contains("потеряно") == true)
        XCTAssertTrue(result.shouldRetryAutomatically)
    }
}

private extension Array where Element == String {
    func containsConsecutive(_ first: String, _ second: String) -> Bool {
        zip(self, dropFirst()).contains { $0 == first && $1 == second }
    }
}
