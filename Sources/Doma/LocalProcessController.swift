import Darwin
import Foundation

struct LocalListenerInfo: Sendable {
    var ownersByPID: [Int32: LocalPortOwner] = [:]
    var endpointsByPID: [Int32: Set<String>] = [:]

    var pids: Set<Int32> {
        Set(ownersByPID.keys)
    }

    var owners: [LocalPortOwner] {
        ownersByPID.values.sorted { $0.pid < $1.pid }
    }
}

struct LocalListenerSnapshot: Sendable {
    let listeners: [Int: LocalListenerInfo]
    let warning: String?
    let isAuthoritative: Bool
}

enum LocalProcessController {
    private static let lsof = "/usr/sbin/lsof"
    private static let processPathBufferSize = 4_096
    private static let protectedProcessNames: Set<String> = [
        "controlcenter",
        "doma",
        "dock",
        "finder",
        "launchd",
        "loginwindow",
        "ssh",
        "systemuiserver",
        "windowserver",
    ]

    static func snapshot() -> LocalListenerSnapshot {
        let result = CommandRunner.run(
            lsof,
            arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcutn"],
            timeout: 5
        )
        return snapshot(from: result, masterSnapshot: DomaSSHMasterRegistry.snapshot())
    }

    static func snapshot() async -> LocalListenerSnapshot {
        async let result = CommandRunner.runAsync(
            lsof,
            arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcutn"],
            timeout: 5
        )
        async let masters = DomaSSHMasterRegistry.snapshotAsync()
        let (commandResult, masterSnapshot) = await (result, masters)
        return snapshot(from: commandResult, masterSnapshot: masterSnapshot)
    }

    static func listeners() -> [Int: LocalListenerInfo] {
        snapshot().listeners
    }

    static func snapshot(
        from result: CommandResult,
        managedDomaMasterPIDs: Set<Int32> = []
    ) -> LocalListenerSnapshot {
        // lsof documents status 1 for a valid query with no matching files.
        if result.status == 1,
           result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return LocalListenerSnapshot(listeners: [:], warning: nil, isAuthoritative: true)
        }

        guard result.status == 0 else {
            let diagnostic = [result.stdout, result.stderr]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
                .split(whereSeparator: \.isNewline)
                .last
                .map(String.init)
            let reason: String
            if result.status == 124 {
                reason = "локальная команда lsof не ответила вовремя"
            } else if result.status == 127 {
                reason = "локальная команда /usr/sbin/lsof недоступна"
            } else if diagnostic?.lowercased().contains("permission denied") == true {
                reason = "macOS запретила Doma читать локальные listening sockets"
            } else {
                reason = diagnostic ?? "lsof завершилась со статусом \(result.status)"
            }
            return LocalListenerSnapshot(
                listeners: [:],
                warning: "Не удалось проверить локальные порты: \(reason). Состояние пробросов не изменено.",
                isAuthoritative: false
            )
        }

        let listeners = parseListeners(result.stdout, managedDomaMasterPIDs: managedDomaMasterPIDs)
        let hasPartialMetadata = listeners.values.contains { info in
            info.ownersByPID.values.contains { owner in
                owner.userID == UInt32.max || owner.name.hasPrefix("PID ")
            }
        }
        return LocalListenerSnapshot(
            listeners: listeners,
            warning: hasPartialMetadata
                ? "lsof вернула неполные данные о локальных процессах; TCP-пробросы продолжают работать, но завершение конфликтующих процессов недоступно."
                : nil,
            isAuthoritative: true
        )
    }

    static func snapshot(
        from result: CommandResult,
        masterSnapshot: DomaSSHMasterSnapshot
    ) -> LocalListenerSnapshot {
        let local = snapshot(
            from: result,
            managedDomaMasterPIDs: Set(masterSnapshot.masters.map(\.pid))
        )
        guard masterSnapshot.isAuthoritative else {
            let warning = [local.warning, masterSnapshot.warning]
                .compactMap { $0 }
                .joined(separator: " ")
            return LocalListenerSnapshot(
                listeners: local.listeners,
                warning: warning,
                isAuthoritative: false
            )
        }
        return local
    }

    static func terminate(_ requestedOwners: [LocalPortOwner], on port: Int) -> String? {
        guard !requestedOwners.isEmpty else {
            return "Не удалось определить локальный процесс на порту \(port)"
        }

        let currentSnapshot = snapshot()
        guard currentSnapshot.isAuthoritative else {
            return currentSnapshot.warning
        }
        let currentOwners = currentSnapshot.listeners[port]?.ownersByPID ?? [:]
        for requested in requestedOwners {
            guard let current = currentOwners[requested.pid],
                  current.userID == requested.userID,
                  current.name == requested.name
            else {
                return "Процесс \(requested.pid) больше не занимает порт \(port)"
            }
            if let reason = current.terminationBlockReason {
                return "Нельзя завершить \(current.name) (PID \(current.pid)): \(reason)"
            }
        }

        for owner in requestedOwners {
            if Darwin.kill(pid_t(owner.pid), SIGTERM) != 0 {
                let reason = String(cString: strerror(errno))
                return "Не удалось завершить \(owner.name) (PID \(owner.pid)): \(reason)"
            }
        }

        let requestedPIDs = Set(requestedOwners.map(\.pid))
        for _ in 0..<12 {
            Thread.sleep(forTimeInterval: 0.25)
            let currentSnapshot = snapshot()
            guard currentSnapshot.isAuthoritative else {
                return currentSnapshot.warning
            }
            let remaining = Set(currentSnapshot.listeners[port]?.ownersByPID.keys.map { $0 } ?? [])
            if requestedPIDs.isDisjoint(with: remaining) {
                return nil
            }
        }

        let processes = requestedOwners.map { "\($0.name) (PID \($0.pid))" }.joined(separator: ", ")
        return "\(processes) не завершился после SIGTERM"
    }

    static func parseListeners(
        _ output: String,
        currentUserID: UInt32 = getuid(),
        currentProcessID: Int32 = getpid(),
        managedDomaMasterPIDs: Set<Int32> = []
    ) -> [Int: LocalListenerInfo] {
        var currentPID: Int32?
        var commands: [Int32: String] = [:]
        var userIDs: [Int32: UInt32] = [:]
        var endpointsByPortAndPID: [Int: [Int32: Set<String>]] = [:]

        for line in output.split(whereSeparator: \.isNewline).map(String.init) {
            switch line.first {
            case "p":
                currentPID = Int32(line.dropFirst())
            case "c":
                if let currentPID {
                    commands[currentPID] = String(line.dropFirst())
                }
            case "u":
                if let currentPID, let userID = UInt32(line.dropFirst()) {
                    userIDs[currentPID] = userID
                }
            case "n":
                guard let currentPID,
                      let port = capturePort(from: line) else { continue }
                endpointsByPortAndPID[port, default: [:]][currentPID, default: []]
                    .insert(String(line.dropFirst()))
            default:
                continue
            }
        }

        return endpointsByPortAndPID.mapValues { endpointsByPID in
            var info = LocalListenerInfo()
            info.endpointsByPID = endpointsByPID
            for pid in endpointsByPID.keys {
                let isDomaTunnel = managedDomaMasterPIDs.contains(pid)
                let name = isDomaTunnel ? "Doma tunnel" : (commands[pid] ?? "PID \(pid)")
                let userID = userIDs[pid] ?? UInt32.max
                info.ownersByPID[pid] = LocalPortOwner(
                    pid: pid,
                    name: name,
                    userID: userID,
                    terminationBlockReason: terminationBlockReason(
                        pid: pid,
                        name: name,
                        userID: userID,
                        currentUserID: currentUserID,
                        currentProcessID: currentProcessID,
                        isDomaTunnel: isDomaTunnel
                    )
                )
            }
            return info
        }
    }

    private static func capturePort(from line: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: #":(\d+)$"#),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else { return nil }
        return Int(line[range])
    }

    private static func terminationBlockReason(
        pid: Int32,
        name: String,
        userID: UInt32,
        currentUserID: UInt32,
        currentProcessID: Int32,
        isDomaTunnel: Bool
    ) -> String? {
        if userID == UInt32.max || name.hasPrefix("PID ") {
            return "lsof вернула неполные данные о процессе"
        }
        if userID != currentUserID {
            return "процесс принадлежит другому пользователю"
        }
        if pid == currentProcessID {
            return "это процесс Doma"
        }
        if isDomaTunnel {
            return nil
        }
        if protectedProcessNames.contains(name.lowercased()) {
            return "это системный или инфраструктурный процесс"
        }
        if let path = executablePath(pid: pid),
           path.hasPrefix("/System/")
            || path.hasPrefix("/usr/libexec/")
            || path.hasPrefix("/usr/sbin/")
            || path.hasPrefix("/Library/Apple/")
        {
            return "это системный процесс macOS"
        }
        return nil
    }

    private static func executablePath(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: processPathBufferSize)
        let length = proc_pidpath(pid_t(pid), &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }
}
