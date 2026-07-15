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

    static func listeners() -> [Int: LocalListenerInfo] {
        let result = CommandRunner.run(
            lsof,
            arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcutn"],
            timeout: 5
        )
        guard result.status == 0 else { return [:] }
        return parseListeners(
            result.stdout,
            managedDomaMasterPIDs: DomaSSHMasterRegistry.managedPIDs()
        )
    }

    static func terminate(_ requestedOwners: [LocalPortOwner], on port: Int) -> String? {
        guard !requestedOwners.isEmpty else {
            return "Не удалось определить локальный процесс на порту \(port)"
        }

        let currentOwners = listeners()[port]?.ownersByPID ?? [:]
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
            let remaining = Set(listeners()[port]?.ownersByPID.keys.map { $0 } ?? [])
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
