import Darwin
import Foundation

struct DomaSSHMaster: Equatable, Sendable {
    let pid: Int32
    let socketPath: String
}

struct DomaSSHMasterSnapshot: Sendable {
    let masters: [DomaSSHMaster]
    let warning: String?
    let isAuthoritative: Bool
}

enum DomaSSHMasterRegistry {
    private static let ps = "/bin/ps"

    static var controlDirectory: String {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Doma/cm", isDirectory: true)
            .path
    }

    static func masters() -> [DomaSSHMaster] {
        snapshot().masters
    }

    static func snapshot() -> DomaSSHMasterSnapshot {
        snapshot(from: CommandRunner.run(
            ps,
            arguments: ["-axww", "-o", "pid=,command="],
            timeout: 5
        ), controlDirectory: controlDirectory)
    }

    static func mastersAsync() async -> [DomaSSHMaster] {
        (await snapshotAsync()).masters
    }

    static func snapshotAsync() async -> DomaSSHMasterSnapshot {
        snapshot(from: await CommandRunner.runAsync(
            ps,
            arguments: ["-axww", "-o", "pid=,command="],
            timeout: 5
        ), controlDirectory: controlDirectory)
    }

    static func managedPIDs() -> Set<Int32> {
        Set(masters().map(\.pid))
    }

    static func managedPIDsAsync() async -> Set<Int32> {
        Set((await mastersAsync()).map(\.pid))
    }

    @discardableResult
    static func terminateMasters(socketPath: String, keeping keptPID: Int32?) -> Bool {
        let initial = snapshot()
        guard initial.isAuthoritative else { return false }
        let targets = initial.masters.filter { master in
            master.socketPath == socketPath && master.pid != keptPID
        }
        guard !targets.isEmpty else { return true }

        for target in targets {
            _ = Darwin.kill(pid_t(target.pid), SIGTERM)
        }

        for _ in 0..<20 {
            let current = snapshot()
            guard current.isAuthoritative else { return false }
            let remaining = Set(current.masters.filter { $0.socketPath == socketPath }.map(\.pid))
            if targets.allSatisfy({ !remaining.contains($0.pid) }) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        for target in targets {
            _ = Darwin.kill(pid_t(target.pid), SIGKILL)
        }
        for _ in 0..<10 {
            let current = snapshot()
            guard current.isAuthoritative else { return false }
            let remaining = Set(current.masters.filter { $0.socketPath == socketPath }.map(\.pid))
            if targets.allSatisfy({ !remaining.contains($0.pid) }) { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    @discardableResult
    static func terminateMastersAsync(socketPath: String, keeping keptPID: Int32?) async -> Bool {
        let initial = await snapshotAsync()
        guard initial.isAuthoritative else { return false }
        let targets = initial.masters.filter { master in
            master.socketPath == socketPath && master.pid != keptPID
        }
        guard !targets.isEmpty else { return true }

        for target in targets {
            _ = Darwin.kill(pid_t(target.pid), SIGTERM)
        }

        for _ in 0..<20 {
            if Task.isCancelled { return false }
            let current = await snapshotAsync()
            guard current.isAuthoritative else { return false }
            let remaining = Set(current.masters.filter { $0.socketPath == socketPath }.map(\.pid))
            if targets.allSatisfy({ !remaining.contains($0.pid) }) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    static func snapshot(
        from result: CommandResult,
        controlDirectory: String
    ) -> DomaSSHMasterSnapshot {
        guard result.status == 0 else {
            let diagnostic = [result.stdout, result.stderr]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
                .split(whereSeparator: \.isNewline)
                .last
                .map(String.init)
            let reason = result.status == 124
                ? "локальная команда ps не ответила вовремя"
                : (diagnostic ?? "ps завершилась со статусом \(result.status)")
            return DomaSSHMasterSnapshot(
                masters: [],
                warning: "Не удалось определить процессы SSH ControlMaster: \(reason). Состояние локальных пробросов не считается достоверным.",
                isAuthoritative: false
            )
        }
        return DomaSSHMasterSnapshot(
            masters: parse(result.stdout, controlDirectory: controlDirectory),
            warning: nil,
            isAuthoritative: true
        )
    }

    static func parse(_ output: String, controlDirectory: String) -> [DomaSSHMaster] {
        let socketPrefix = controlDirectory + "/"

        return output.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let separator = line.firstIndex(where: \.isWhitespace),
                  let pid = Int32(line[..<separator]) else { return nil }

            let command = line[separator...].trimmingCharacters(in: .whitespaces)
            guard command.hasPrefix("/usr/bin/ssh "),
                  command.contains(" -fMN "),
                  let socketStartMarker = command.range(of: " -S "),
                  let socketEndMarker = command.range(
                      of: " -o ControlMaster=yes",
                      range: socketStartMarker.upperBound..<command.endIndex
                  )
            else { return nil }

            let socketPath = String(command[socketStartMarker.upperBound..<socketEndMarker.lowerBound])
            guard socketPath.hasPrefix(socketPrefix) else { return nil }
            return DomaSSHMaster(pid: pid, socketPath: socketPath)
        }
    }
}
