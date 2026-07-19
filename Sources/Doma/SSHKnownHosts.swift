import Darwin
import Foundation

struct SSHKnownHostsPlan: Equatable, Sendable {
    let target: String
    let files: [String]
}

private struct SSHKnownHostsTransactionManifest: Codable, Sendable {
    enum Phase: String, Codable, Sendable {
        case prepared
        case committed
    }

    let id: UUID
    let phase: Phase
    let backups: [String: String]
    let workingCopies: [String: String]?
    let backupSequence: UInt64?
}

struct SSHKnownHostsRecoveryStore: Sendable {
    let directory: URL

    static var standard: SSHKnownHostsRecoveryStore {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return SSHKnownHostsRecoveryStore(
            directory: applicationSupport.appendingPathComponent(
                "Doma/known-hosts-transactions",
                isDirectory: true
            )
        )
    }

    func begin(
        backups: [String: String],
        workingCopies: [String: String] = [:],
        backupSequence: UInt64? = nil
    ) throws -> UUID {
        let id = UUID()
        try write(SSHKnownHostsTransactionManifest(
            id: id,
            phase: .prepared,
            backups: backups,
            workingCopies: workingCopies,
            backupSequence: backupSequence
        ))
        return id
    }

    func markCommitted(
        id: UUID,
        backups: [String: String],
        workingCopies: [String: String] = [:],
        backupSequence: UInt64? = nil
    ) throws {
        try write(SSHKnownHostsTransactionManifest(
            id: id,
            phase: .committed,
            backups: backups,
            workingCopies: workingCopies,
            backupSequence: backupSequence
        ))
    }

    func nextBackupSequence() throws -> UInt64 {
        try prepareDirectory()
        let lockURL = directory.appendingPathComponent(".backup-sequence.lock")
        let descriptor = Darwin.open(lockURL.path, O_RDWR | O_CREAT | O_EXLOCK, 0o600)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        try cleanupSequenceTemps()

        let sequenceURL = directory.appendingPathComponent(".backup-sequence")
        let current: UInt64
        if FileManager.default.fileExists(atPath: sequenceURL.path) {
            let text = try String(contentsOf: sequenceURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let parsed = UInt64(text) else { throw CocoaError(.fileReadCorruptFile) }
            current = parsed
        } else {
            current = 0
        }
        let (next, overflow) = current.addingReportingOverflow(1)
        guard !overflow else { throw CocoaError(.fileWriteOutOfSpace) }

        let temporary = directory.appendingPathComponent(".backup-sequence.pending")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Data("\(next)\n".utf8).write(to: temporary, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        try SSHKnownHostsManager.syncFile(atPath: temporary.path)
        guard Darwin.rename(temporary.path, sequenceURL.path) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        try syncDirectory()
        return next
    }

    private func cleanupSequenceTemps() throws {
        let manager = FileManager.default
        let fixedName = ".backup-sequence.pending"
        let legacyPrefix = ".backup-sequence-"
        let names = try manager.contentsOfDirectory(atPath: directory.path)
        let ownedNames = names.filter { name in
            if name == fixedName { return true }
            guard name.hasPrefix(legacyPrefix) else { return false }
            return UUID(uuidString: String(name.dropFirst(legacyPrefix.count))) != nil
        }
        guard !ownedNames.isEmpty else { return }
        for name in ownedNames {
            try manager.removeItem(at: directory.appendingPathComponent(name))
        }
        try syncDirectory()
    }

    func finish(id: UUID) throws {
        let manifest = manifestURL(id: id)
        if FileManager.default.fileExists(atPath: manifest.path) {
            try FileManager.default.removeItem(at: manifest)
            try syncDirectory()
        }
    }

    func recover() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let manifests = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }

        for url in manifests {
            let manifest = try JSONDecoder().decode(
                SSHKnownHostsTransactionManifest.self,
                from: Data(contentsOf: url)
            )
            switch manifest.phase {
            case .prepared:
                let available = manifest.backups.filter {
                    FileManager.default.fileExists(atPath: $0.value)
                }
                let failures = SSHKnownHostsManager.restore(backups: available)
                guard failures.isEmpty else {
                    throw CocoaError(.fileWriteUnknown)
                }
                try SSHKnownHostsManager.cleanupBackups(manifest.backups)
            case .committed:
                for original in manifest.backups.keys {
                    SSHKnownHostsManager.pruneBackups(for: original, keeping: 3)
                }
            }
            try SSHKnownHostsManager.cleanupWorkingCopies(manifest.workingCopies ?? [:])
            try finish(id: manifest.id)
        }
    }

    private func write(_ manifest: SSHKnownHostsTransactionManifest) throws {
        try prepareDirectory()
        let manager = FileManager.default
        let url = manifestURL(id: manifest.id)
        try JSONEncoder().encode(manifest).write(to: url, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try SSHKnownHostsManager.syncFile(atPath: url.path)
        try syncDirectory()
    }

    private func prepareDirectory() throws {
        let manager = FileManager.default
        try manager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private func manifestURL(id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString + ".json", isDirectory: false)
    }

    private func syncDirectory() throws {
        let descriptor = Darwin.open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }
}

enum SSHKnownHostsManager {
    private static let ssh = "/usr/bin/ssh"
    private static let sshKeygen = "/usr/bin/ssh-keygen"
    private static let recoveryQueue = DispatchQueue(label: "com.mrflashaccount.doma.known-hosts-recovery")
    private static let retainedBackupCount = 3

    static func recoverInterruptedTransactions(
        store: SSHKnownHostsRecoveryStore = .standard
    ) -> String? {
        do {
            try store.recover()
            return nil
        } catch {
            return "Не удалось восстановить незавершённую операцию known_hosts. Резервные копии сохранены.\n\n\(error.localizedDescription)"
        }
    }

    static func removeStaleKeyAndRequireConfirmationAsync(host: String) async -> String? {
        await performRecoveryTransaction {
            guard let plan = resolvePlan(host: host) else {
                return "Не удалось определить effective known_hosts target для \(host); known_hosts не изменён."
            }
            do {
                try SSHHostTrustState.requireExplicitConfirmation(for: plan.target)
            } catch {
                return "Не удалось надёжно сохранить обязательное подтверждение нового fingerprint. known_hosts не изменён.\n\n\(error.localizedDescription)"
            }
            return removeStaleKey(using: plan)
        }
    }

    static func performRecoveryTransaction(
        _ transaction: @escaping @Sendable () -> String?
    ) async -> String? {
        await withCheckedContinuation { continuation in
            recoveryQueue.async {
                continuation.resume(returning: transaction())
            }
        }
    }

    static func removeStaleKey(host: String) -> String? {
        guard let plan = resolvePlan(host: host) else {
            return "Не удалось определить known_hosts для \(host)."
        }
        return removeStaleKey(using: plan)
    }

    static func resolvePlan(host: String) -> SSHKnownHostsPlan? {
        let configuration = CommandRunner.run(
            ssh,
            arguments: ["-G", host],
            timeout: 5
        )
        guard configuration.status == 0,
              let plan = plan(from: configuration.stdout, homeDirectory: NSHomeDirectory())
        else {
            return nil
        }
        return plan
    }

    static func resolvePlanAsync(host: String) async -> SSHKnownHostsPlan? {
        let configuration = await CommandRunner.runAsync(
            ssh,
            arguments: ["-G", host],
            timeout: 5
        )
        guard configuration.status == 0 else { return nil }
        return plan(from: configuration.stdout, homeDirectory: NSHomeDirectory())
    }

    static func removeStaleKey(
        using plan: SSHKnownHostsPlan,
        recoveryStore: SSHKnownHostsRecoveryStore = .standard
    ) -> String? {
        removeStaleKey(using: plan, recoveryStore: recoveryStore) { executable, arguments in
            CommandRunner.run(executable, arguments: arguments, timeout: 5)
        }
    }

    static func removeStaleKey(
        using plan: SSHKnownHostsPlan,
        recoveryStore: SSHKnownHostsRecoveryStore = .standard,
        commandRunner: (_ executable: String, _ arguments: [String]) -> CommandResult
    ) -> String? {
        let manager = FileManager.default
        if let recoveryError = recoverInterruptedTransactions(store: recoveryStore) {
            return recoveryError
        }
        var matchedFiles: [String] = []
        for file in plan.files where FileManager.default.fileExists(atPath: file) {
            let lookup = commandRunner(sshKeygen, ["-F", plan.target, "-f", file])
            if lookup.status == 1,
               (lookup.stdout + lookup.stderr).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                continue
            }
            guard lookup.status == 0 else {
                let diagnostic = lastMeaningfulLine(lookup.stderr.isEmpty ? lookup.stdout : lookup.stderr)
                return diagnostic.isEmpty
                    ? "Не удалось проверить \(plan.target) в \(file); known_hosts не изменён."
                    : "Не удалось проверить \(file); known_hosts не изменён.\n\n\(diagnostic)"
            }
            guard !(lookup.stdout + lookup.stderr).isEmpty else { continue }
            if !matchedFiles.contains(file) {
                matchedFiles.append(file)
            }
        }

        guard !matchedFiles.isEmpty else {
            return "Старая запись для \(plan.target) не найдена в пользовательских known_hosts."
        }

        let backupSequence: UInt64
        do {
            backupSequence = try recoveryStore.nextBackupSequence()
        } catch {
            return "Не удалось надёжно выделить порядковый номер резервной копии known_hosts; файлы не изменены.\n\n\(error.localizedDescription)"
        }
        let backupSuffix = String(
            format: ".doma-backup-v3-%020llu-%@",
            backupSequence,
            UUID().uuidString
        )
        let workingSuffix = ".doma-work-\(UUID().uuidString)"
        let backups = Dictionary(uniqueKeysWithValues: matchedFiles.map { file in
            (file, file + backupSuffix)
        })
        let workingCopies = Dictionary(uniqueKeysWithValues: matchedFiles.map { file in
            (file, file + workingSuffix)
        })
        var transactionID: UUID?
        do {
            for file in Set(matchedFiles) {
                pruneBackups(for: file, keeping: retainedBackupCount)
            }
            transactionID = try recoveryStore.begin(
                backups: backups,
                workingCopies: workingCopies,
                backupSequence: backupSequence
            )
            for (file, backup) in backups {
                try createAtomicBackup(from: file, to: backup)
            }
            for (file, workingCopy) in workingCopies {
                try createAtomicCopy(from: file, to: workingCopy, permissions: nil)
            }
        } catch {
            let backupsClean = (try? cleanupBackups(backups)) != nil
            let workingCopiesClean = (try? cleanupWorkingCopies(workingCopies)) != nil
            if let id = transactionID, backupsClean, workingCopiesClean {
                try? recoveryStore.finish(id: id)
            }
            return "Не удалось создать уникальную резервную копию known_hosts; файлы не изменены.\n\n\(error.localizedDescription)"
        }
        guard let transactionID else {
            return "Не удалось начать защищённую операцию known_hosts; файлы не изменены."
        }

        for file in matchedFiles {
            guard let workingCopy = workingCopies[file] else { continue }
            let removal = commandRunner(sshKeygen, ["-R", plan.target, "-f", workingCopy])
            let mutationFailure: String?
            if removal.status == 0 {
                do {
                    try syncFile(atPath: workingCopy)
                    try replaceOriginal(file, withWorkingCopy: workingCopy)
                    try? manager.removeItem(atPath: workingCopy + ".old")
                    mutationFailure = nil
                } catch {
                    mutationFailure = "Не удалось атомарно заменить \(file): \(error.localizedDescription)"
                }
            } else {
                let rollbackFailures = restore(backups: backups)
                let diagnostic = lastMeaningfulLine(removal.stderr.isEmpty ? removal.stdout : removal.stderr)
                let base = diagnostic.isEmpty
                    ? "Не удалось удалить старый ключ \(plan.target) из \(file)."
                    : diagnostic
                let workingCopiesClean = (try? cleanupWorkingCopies(workingCopies)) != nil
                if rollbackFailures.isEmpty {
                    let backupsClean = (try? cleanupBackups(backups)) != nil
                    if backupsClean, workingCopiesClean {
                        try? recoveryStore.finish(id: transactionID)
                    }
                    return base + " Все уже изменённые known_hosts восстановлены из уникальных резервных копий."
                }
                return base + " Не удалось автоматически восстановить: \(rollbackFailures.joined(separator: ", ")). Уникальные резервные копии сохранены рядом с файлами."
            }
            if let mutationFailure {
                let rollbackFailures = restore(backups: backups)
                let workingCopiesClean = (try? cleanupWorkingCopies(workingCopies)) != nil
                if rollbackFailures.isEmpty {
                    let backupsClean = (try? cleanupBackups(backups)) != nil
                    if backupsClean, workingCopiesClean {
                        try? recoveryStore.finish(id: transactionID)
                    }
                    return mutationFailure + " Все уже изменённые known_hosts восстановлены из уникальных резервных копий."
                }
                return mutationFailure + " Не удалось автоматически восстановить: \(rollbackFailures.joined(separator: ", ")). Уникальные резервные копии сохранены рядом с файлами."
            }
        }
        do {
            try recoveryStore.markCommitted(
                id: transactionID,
                backups: backups,
                workingCopies: workingCopies,
                backupSequence: backupSequence
            )
        } catch {
            return "known_hosts изменён, но Doma не смогла надёжно зафиксировать завершение операции. При следующем запуске файлы будут восстановлены из резервных копий.\n\n\(error.localizedDescription)"
        }
        do {
            try cleanupWorkingCopies(workingCopies)
        } catch {
            return "known_hosts изменён, но Doma не смогла удалить временные файлы операции. Они будут удалены при следующем запуске.\n\n\(error.localizedDescription)"
        }
        for file in Set(matchedFiles) {
            pruneBackups(for: file, keeping: retainedBackupCount)
        }
        try? recoveryStore.finish(id: transactionID)
        return nil
    }

    static func plan(from sshConfiguration: String, homeDirectory: String) -> SSHKnownHostsPlan? {
        var hostname: String?
        var port = 22
        var hostKeyAlias: String?
        var files: [String] = []

        for line in sshConfiguration.split(whereSeparator: \.isNewline) {
            let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard fields.count == 2 else { continue }

            let key = String(fields[0])
            let value = String(fields[1])
            switch key {
            case "hostname":
                hostname = value
            case "port":
                port = Int(value) ?? 22
            case "hostkeyalias" where value != "none":
                hostKeyAlias = value
            case "userknownhostsfile":
                files = value.split(whereSeparator: \.isWhitespace)
                    .map(String.init)
                    .filter { $0 != "none" }
                    .map { expand(path: $0, homeDirectory: homeDirectory) }
            default:
                continue
            }
        }

        guard let hostname else { return nil }
        let target = hostKeyAlias ?? (port == 22 ? hostname : "[\(hostname)]:\(port)")
        return SSHKnownHostsPlan(target: target, files: files)
    }

    private static func expand(path: String, homeDirectory: String) -> String {
        var expanded = path.replacingOccurrences(of: "%d", with: homeDirectory)
        if expanded == "~" {
            expanded = homeDirectory
        } else if expanded.hasPrefix("~/") {
            expanded = homeDirectory + expanded.dropFirst()
        }
        return expanded
    }

    private static func createAtomicBackup(
        from original: String,
        to backup: String
    ) throws {
        try createAtomicCopy(
            from: original,
            to: backup,
            permissions: 0o600
        )
    }

    private static func createAtomicCopy(
        from original: String,
        to copy: String,
        permissions: Int?
    ) throws {
        let manager = FileManager.default
        let partial = copy + ".partial"
        try? manager.removeItem(atPath: partial)
        do {
            try manager.copyItem(atPath: original, toPath: partial)
            if let permissions {
                try manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: partial)
            }
            try syncFile(atPath: partial)
            guard Darwin.rename(partial, copy) == 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            try syncDirectory(at: URL(fileURLWithPath: copy).deletingLastPathComponent())
        } catch {
            try? manager.removeItem(atPath: partial)
            throw error
        }
    }

    private static func replaceOriginal(_ original: String, withWorkingCopy workingCopy: String) throws {
        guard Darwin.rename(workingCopy, original) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        try syncDirectory(at: URL(fileURLWithPath: original).deletingLastPathComponent())
    }

    fileprivate static func cleanupWorkingCopies(_ workingCopies: [String: String]) throws {
        try removeTrackedPaths(workingCopies.values.flatMap { workingCopy in
            [workingCopy, workingCopy + ".partial", workingCopy + ".old"]
        })
    }

    fileprivate static func cleanupBackups(_ backups: [String: String]) throws {
        try removeTrackedPaths(backups.values.flatMap { backup in
            [backup, backup + ".partial"]
        })
    }

    private static func removeTrackedPaths(_ paths: [String]) throws {
        let manager = FileManager.default
        var directories = Set<URL>()
        for path in paths where manager.fileExists(atPath: path) {
            try manager.removeItem(atPath: path)
            directories.insert(URL(fileURLWithPath: path).deletingLastPathComponent())
        }
        for directory in directories {
            try syncDirectory(at: directory)
        }
    }

    fileprivate static func restore(backups: [String: String]) -> [String] {
        let manager = FileManager.default
        var failures: [String] = []
        for (original, backup) in backups {
            let rollback = original + ".doma-rollback-" + UUID().uuidString
            do {
                try manager.copyItem(atPath: backup, toPath: rollback)
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: rollback)
                try syncFile(atPath: rollback)
                guard Darwin.rename(rollback, original) == 0 else {
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }
                try syncDirectory(at: URL(fileURLWithPath: original).deletingLastPathComponent())
            } catch {
                try? manager.removeItem(atPath: rollback)
                failures.append(original)
            }
        }
        return failures.sorted()
    }

    fileprivate static func pruneBackups(for file: String, keeping limit: Int) {
        let manager = FileManager.default
        let original = URL(fileURLWithPath: file)
        let directory = original.deletingLastPathComponent()
        let prefix = original.lastPathComponent + ".doma-backup-"
        let candidates = ((try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
            .sorted { left, right in
                let leftSequence = backupSequence(for: left.lastPathComponent, prefix: prefix)
                let rightSequence = backupSequence(for: right.lastPathComponent, prefix: prefix)
                switch (leftSequence, rightSequence) {
                case let (left?, right?) where left != right:
                    return left > right
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    return left.lastPathComponent > right.lastPathComponent
                }
            }
        for stale in candidates.dropFirst(limit) {
            try? manager.removeItem(at: stale)
        }
    }

    private static func backupSequence(for name: String, prefix: String) -> UInt64? {
        let marker = prefix + "v3-"
        guard name.hasPrefix(marker) else { return nil }
        let remainder = name.dropFirst(marker.count)
        let sequence = remainder.prefix(20)
        guard sequence.count == 20, sequence.allSatisfy(\.isNumber) else { return nil }
        return UInt64(sequence)
    }

    fileprivate static func syncFile(atPath path: String) throws {
        let descriptor = Darwin.open(path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }

    private static func syncDirectory(at directory: URL) throws {
        let descriptor = Darwin.open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }

    private static func lastMeaningfulLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last(where: { !$0.isEmpty }) ?? ""
    }
}
