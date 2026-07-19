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

    func testPendingReplacementKeyIsCrashDurableAndRestrictive() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DomaTrustStore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SSHHostTrustStore(directory: directory)

        try store.requireExplicitConfirmation(for: "devbox")
        let reloaded = SSHHostTrustStore(directory: directory)

        XCTAssertTrue(try reloaded.requiresExplicitConfirmation(for: "devbox"))
        XCTAssertEqual(
            try reloaded.strictHostKeyArguments(for: "devbox"),
            ["-o", "StrictHostKeyChecking=ask", "-o", "UpdateHostKeys=no"]
        )
        XCTAssertEqual(try permissions(at: directory), 0o700)
        let marker = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first
        )
        XCTAssertEqual(try permissions(at: marker), 0o600)

        try reloaded.markConfirmed(target: "devbox")
        XCTAssertFalse(try store.requiresExplicitConfirmation(for: "devbox"))
    }

    func testPendingReplacementKeyOverridesUnsafeAliasPolicy() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DomaTrustStore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SSHHostTrustStore(directory: directory)
        XCTAssertNoThrow(try store.requireExplicitConfirmation(for: "devbox"))

        XCTAssertEqual(
            try store.strictHostKeyArguments(for: "devbox"),
            ["-o", "StrictHostKeyChecking=ask", "-o", "UpdateHostKeys=no"]
        )
    }

    func testCorruptPendingMarkerFailsClosed() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DomaTrustStoreCorrupt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SSHHostTrustStore(directory: directory)
        try store.requireExplicitConfirmation(for: "devbox")
        let marker = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first
        )
        try Data("invalid-marker\n".utf8).write(to: marker)

        XCTAssertThrowsError(try store.markerState(for: "devbox")) { error in
            XCTAssertEqual(error as? SSHHostTrustStoreError, .corrupt)
        }
        XCTAssertThrowsError(try store.strictHostKeyArguments(for: "devbox"))
    }

    func testUnreadablePendingMarkerFailsClosed() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DomaTrustStoreUnreadable-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SSHHostTrustStore(directory: directory)
        try store.requireExplicitConfirmation(for: "devbox")
        let marker = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first
        )
        try FileManager.default.removeItem(at: marker)
        try FileManager.default.createDirectory(at: marker, withIntermediateDirectories: false)

        XCTAssertThrowsError(try store.markerState(for: "devbox")) { error in
            guard error as? SSHHostTrustStoreError == .unreadable else {
                return XCTFail("Expected unreadable marker error, got \(error)")
            }
        }
        XCTAssertThrowsError(try store.strictHostKeyArguments(for: "devbox"))
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
            port 2222
            hostkeyalias stable-server-key
            userknownhostsfile /Users/demo/.ssh/known_hosts
            """,
            homeDirectory: "/Users/demo"
        )

        XCTAssertEqual(plan?.target, "stable-server-key")
    }

    func testAliasesSharingHostKeyAliasSharePendingConfirmationLifecycle() throws {
        let first = try XCTUnwrap(SSHKnownHostsManager.plan(
            from: """
            hostname first.example.com
            port 2222
            hostkeyalias stable-server-key
            userknownhostsfile /tmp/known_hosts
            """,
            homeDirectory: "/tmp"
        ))
        let second = try XCTUnwrap(SSHKnownHostsManager.plan(
            from: """
            hostname second.example.com
            port 2200
            hostkeyalias stable-server-key
            userknownhostsfile /tmp/known_hosts
            """,
            homeDirectory: "/tmp"
        ))
        XCTAssertEqual(first.target, second.target)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DomaSharedHostKeyAlias-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SSHHostTrustStore(directory: directory)
        try store.requireExplicitConfirmation(for: first.target)

        XCTAssertTrue(try store.requiresExplicitConfirmation(for: second.target))
        XCTAssertEqual(
            try store.strictHostKeyArguments(for: second.target),
            ["-o", "StrictHostKeyChecking=ask", "-o", "UpdateHostKeys=no"]
        )
        XCTAssertFalse(try store.requiresExplicitConfirmation(for: "second-alias"))

        try store.markConfirmed(target: second.target)
        XCTAssertFalse(try store.requiresExplicitConfirmation(for: first.target))
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
        let userOwnedOld = URL(fileURLWithPath: knownHosts.path + ".old")
        try "server.example.com \(publicKey[0]) \(publicKey[1])\n".write(
            to: knownHosts,
            atomically: true,
            encoding: .utf8
        )
        try "user-owned-old\n".write(to: userOwnedOld, atomically: true, encoding: .utf8)

        let error = SSHKnownHostsManager.removeStaleKey(
            using: SSHKnownHostsPlan(
                target: "server.example.com",
                files: [knownHosts.path]
            ),
            recoveryStore: SSHKnownHostsRecoveryStore(
                directory: directory.appendingPathComponent("transactions", isDirectory: true)
            )
        )

        XCTAssertNil(error)
        XCTAssertEqual(try String(contentsOf: userOwnedOld, encoding: .utf8), "user-owned-old\n")
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .contains { $0.hasPrefix("known_hosts.doma-backup-") }
        )
        let backup = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .first { $0.lastPathComponent.hasPrefix("known_hosts.doma-backup-") }
        )
        XCTAssertEqual(try permissions(at: backup), 0o600)
        XCTAssertFalse(try String(contentsOf: knownHosts, encoding: .utf8).contains("server.example.com"))
    }

    func testMultiFileRemovalRollsBackAllFilesAndKeepsUniqueBackups() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DomaKnownHostsRollback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = directory.appendingPathComponent("known_hosts")
        let second = directory.appendingPathComponent("team_hosts")
        try "first-original\n".write(to: first, atomically: true, encoding: .utf8)
        try "second-original\n".write(to: second, atomically: true, encoding: .utf8)
        var removalCount = 0
        let recoveryStore = SSHKnownHostsRecoveryStore(
            directory: directory.appendingPathComponent("transactions", isDirectory: true)
        )

        let error = SSHKnownHostsManager.removeStaleKey(
            using: SSHKnownHostsPlan(target: "server.example.com", files: [first.path, second.path]),
            recoveryStore: recoveryStore
        ) { _, arguments in
            if arguments.first == "-F" {
                return CommandResult(status: 0, stdout: "matching key\n", stderr: "")
            }
            removalCount += 1
            let file = arguments.last!
            try? "mutated\n".write(toFile: file, atomically: true, encoding: .utf8)
            return removalCount == 1
                ? CommandResult(status: 0, stdout: "", stderr: "")
                : CommandResult(status: 1, stdout: "", stderr: "simulated removal failure")
        }

        XCTAssertTrue(error?.contains("восстановлены") == true)
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "first-original\n")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "second-original\n")
        let backups = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.contains(".doma-backup-") }
        XCTAssertTrue(backups.isEmpty)
    }

    func testPartialBackupCopyFailureCleansTransactionArtifacts() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DomaKnownHostsPartialCopy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let knownHosts = directory.appendingPathComponent("known_hosts")
        let longHosts = directory.appendingPathComponent(String(repeating: "x", count: 200))
        try "original\n".write(to: knownHosts, atomically: true, encoding: .utf8)
        try "long-original\n".write(to: longHosts, atomically: true, encoding: .utf8)
        let recoveryStore = SSHKnownHostsRecoveryStore(
            directory: directory.appendingPathComponent("transactions", isDirectory: true)
        )

        let error = SSHKnownHostsManager.removeStaleKey(
            using: SSHKnownHostsPlan(target: "server.example.com", files: [knownHosts.path, longHosts.path]),
            recoveryStore: recoveryStore
        ) { _, arguments in
            arguments.first == "-F"
                ? CommandResult(status: 0, stdout: "matching key\n", stderr: "")
                : CommandResult(status: 0, stdout: "", stderr: "")
        }

        XCTAssertTrue(error?.contains("резервную копию") == true)
        XCTAssertEqual(try String(contentsOf: knownHosts, encoding: .utf8), "original\n")
        XCTAssertEqual(try String(contentsOf: longHosts, encoding: .utf8), "long-original\n")
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .contains { $0.contains(".doma-backup-") }
        )
    }

    func testBackupRetentionUsesDurableSequenceAcrossClockRegression() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DomaKnownHostsRetention-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let knownHosts = directory.appendingPathComponent("known_hosts")
        let recoveryStore = SSHKnownHostsRecoveryStore(
            directory: directory.appendingPathComponent("transactions", isDirectory: true)
        )

        for index in 0..<5 {
            try "generation-\(index)\n".write(to: knownHosts, atomically: true, encoding: .utf8)
            XCTAssertNil(SSHKnownHostsManager.removeStaleKey(
                using: SSHKnownHostsPlan(target: "server.example.com", files: [knownHosts.path]),
                recoveryStore: recoveryStore
            ) { _, arguments in
                arguments.first == "-F"
                    ? CommandResult(status: 0, stdout: "matching key\n", stderr: "")
                    : CommandResult(status: 0, stdout: "", stderr: "")
            })
            for backup in try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).filter({ $0.lastPathComponent.contains(".doma-backup-") }) {
                let contents = try String(contentsOf: backup, encoding: .utf8)
                let generation = Int(contents.filter(\.isNumber)) ?? 0
                try FileManager.default.setAttributes(
                    [.modificationDate: Date(timeIntervalSince1970: TimeInterval(10_000 - generation * 1_000))],
                    ofItemAtPath: backup.path
                )
            }
        }

        let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains(".doma-backup-") }
        XCTAssertEqual(backups.count, 3)
        let retainedContents = try Set(backups.map {
            try String(contentsOf: $0, encoding: .utf8)
        })
        XCTAssertEqual(retainedContents, ["generation-2\n", "generation-3\n", "generation-4\n"])
        XCTAssertEqual(try SSHKnownHostsRecoveryStore(directory: recoveryStore.directory).nextBackupSequence(), 6)
        for backup in backups {
            XCTAssertEqual(try permissions(at: backup), 0o600)
        }
    }

    func testBackupSequenceCrashTempsAreBoundedAndPreciselyRecovered() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DomaBackupSequenceCrash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SSHKnownHostsRecoveryStore(directory: directory)
        let fixed = directory.appendingPathComponent(".backup-sequence.pending")
        let legacyNames = (0..<3).map { _ in ".backup-sequence-\(UUID().uuidString)" }
        let unrelated = directory.appendingPathComponent(".backup-sequence-not-a-uuid")
        try Data("stale\n".utf8).write(to: fixed)
        for name in legacyNames {
            try Data("stale\n".utf8).write(to: directory.appendingPathComponent(name))
        }
        try Data("private\n".utf8).write(to: unrelated)

        XCTAssertEqual(try store.nextBackupSequence(), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixed.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        for name in legacyNames {
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path))
        }

        for expected in 2...4 {
            try Data("interrupted\n".utf8).write(to: fixed)
            XCTAssertEqual(try store.nextBackupSequence(), UInt64(expected))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixed.path))
        }
        let remainingOwnedTemps = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { name in
                let prefix = ".backup-sequence-"
                guard name.hasPrefix(prefix) else { return false }
                return UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
            }
        XCTAssertTrue(remainingOwnedTemps.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testPreparedCrashTransactionRestoresBackupOnNextRun() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DomaKnownHostsCrashRecovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("known_hosts")
        let backup = directory.appendingPathComponent("known_hosts.doma-backup-crash")
        try "mutated\n".write(to: original, atomically: true, encoding: .utf8)
        try "original\n".write(to: backup, atomically: true, encoding: .utf8)
        let store = SSHKnownHostsRecoveryStore(
            directory: directory.appendingPathComponent("transactions", isDirectory: true)
        )
        _ = try store.begin(backups: [original.path: backup.path])

        try SSHKnownHostsRecoveryStore(directory: store.directory).recover()

        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "original\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: store.directory.path).isEmpty
        )
    }

    func testPreparedCrashCleansOnlyTransactionOwnedWorkingOldFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DomaKnownHostsWorkingCrash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("known_hosts")
        let backup = directory.appendingPathComponent("known_hosts.doma-backup-crash")
        let working = directory.appendingPathComponent("known_hosts.doma-work-crash")
        let workingOld = URL(fileURLWithPath: working.path + ".old")
        let userOwnedOld = URL(fileURLWithPath: original.path + ".old")
        try "mutated\n".write(to: original, atomically: true, encoding: .utf8)
        try "original\n".write(to: backup, atomically: true, encoding: .utf8)
        try "working\n".write(to: working, atomically: true, encoding: .utf8)
        try "transaction-old\n".write(to: workingOld, atomically: true, encoding: .utf8)
        try "user-old\n".write(to: userOwnedOld, atomically: true, encoding: .utf8)
        let store = SSHKnownHostsRecoveryStore(
            directory: directory.appendingPathComponent("transactions", isDirectory: true)
        )
        _ = try store.begin(
            backups: [original.path: backup.path],
            workingCopies: [original.path: working.path]
        )

        try store.recover()

        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "original\n")
        XCTAssertEqual(try String(contentsOf: userOwnedOld, encoding: .utf8), "user-old\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: working.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workingOld.path))
    }

    func testCommittedCrashTransactionKeepsChangeAndBoundsBackups() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DomaKnownHostsCommittedRecovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("known_hosts")
        try "committed\n".write(to: original, atomically: true, encoding: .utf8)
        var backups: [URL] = []
        for index in 0..<5 {
            let backup = directory.appendingPathComponent("known_hosts.doma-backup-\(index)")
            try "backup-\(index)\n".write(to: backup, atomically: true, encoding: .utf8)
            backups.append(backup)
        }
        let store = SSHKnownHostsRecoveryStore(
            directory: directory.appendingPathComponent("transactions", isDirectory: true)
        )
        let id = try store.begin(backups: [original.path: backups.last!.path])
        try store.markCommitted(id: id, backups: [original.path: backups.last!.path])

        try SSHKnownHostsRecoveryStore(directory: store.directory).recover()

        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "committed\n")
        let retained = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("known_hosts.doma-backup-") }
        XCTAssertEqual(retained.count, 3)
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: store.directory.path).isEmpty
        )
    }

    func testRecoveryTransactionFinishesAfterTaskCancellation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DomaRecoveryCancellation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first")
        let second = directory.appendingPathComponent("second")

        let task = Task {
            await SSHKnownHostsManager.performRecoveryTransaction {
                try? Data("first".utf8).write(to: first)
                Thread.sleep(forTimeInterval: 0.2)
                try? Data("second".utf8).write(to: second)
                return nil
            }
        }
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: first.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        _ = await task.value

        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
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

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
