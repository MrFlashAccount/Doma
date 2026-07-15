import Darwin
import Foundation

struct DomaSSHMaster: Equatable, Sendable {
    let pid: Int32
    let socketPath: String
}

enum DomaSSHMasterRegistry {
    private static let ps = "/bin/ps"

    static var controlDirectory: String {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Doma/cm", isDirectory: true)
            .path
    }

    static func masters() -> [DomaSSHMaster] {
        let result = CommandRunner.run(
            ps,
            arguments: ["-axww", "-o", "pid=,command="],
            timeout: 5
        )
        guard result.status == 0 else { return [] }
        return parse(result.stdout, controlDirectory: controlDirectory)
    }

    static func managedPIDs() -> Set<Int32> {
        Set(masters().map(\.pid))
    }

    @discardableResult
    static func terminateMasters(socketPath: String, keeping keptPID: Int32?) -> Bool {
        let targets = masters().filter { master in
            master.socketPath == socketPath && master.pid != keptPID
        }
        guard !targets.isEmpty else { return true }

        for target in targets {
            _ = Darwin.kill(pid_t(target.pid), SIGTERM)
        }

        for _ in 0..<20 {
            let remaining = Set(masters().filter { $0.socketPath == socketPath }.map(\.pid))
            if targets.allSatisfy({ !remaining.contains($0.pid) }) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
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
