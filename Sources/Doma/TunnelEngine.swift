import Foundation

enum TunnelEngine {
    private static let ssh = "/usr/bin/ssh"
    private static let bindAddress = "127.0.0.1"
    private static let forwardLimit = 128
    static let disappearGrace: TimeInterval = 10
    static let inventoryScript = #"""
    printf '__SS__\n'
    ss_output=$(ss -H -ltnp 2>&1)
    ss_status=$?
    if [ "$ss_status" -ne 0 ]; then
      printf '__DOMA_SOCKET_SCAN_FAILED__ %s\n' "$ss_output" >&2
      exit "$ss_status"
    fi
    printf '%s\n' "$ss_output"
    printf '__DOCKER__\n'
    if command -v docker >/dev/null 2>&1; then
      docker_output=$(docker ps --format '{{.Names}}|{{.Ports}}|{{.Label "com.docker.compose.project"}}|{{.Label "com.docker.compose.service"}}' 2>&1)
      if [ "$?" -eq 0 ]; then
        printf '%s\n' "$docker_output"
      else
        printf '__DOMA_WARNING_DOCKER__\n'
      fi
    fi
    printf '__PS__\n'
    ps_output=$(ps -eo pid=,comm=,args= 2>&1)
    if [ "$?" -eq 0 ]; then
      printf '%s\n' "$ps_output"
    else
      printf '__DOMA_WARNING_PROCESSES__\n'
    fi
    printf '__CWD__\n'
    for link in /proc/[0-9]*/cwd; do
      pid=${link#/proc/}
      pid=${pid%/cwd}
      cwd=$(readlink "$link" 2>/dev/null) || continue
      printf '%s|%s\n' "$pid" "$cwd"
    done
    """#

    private struct RawListener {
        let port: Int
        let pid: Int?
        let command: String?
    }

    private struct DockerInfo {
        let container: String
        let project: String
        let service: String
    }

    private struct ProcessInfo {
        let command: String
        let arguments: String
    }

    static func socketPath(for host: String) -> String {
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Doma/cm", isDirectory: true)
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        return cache.appendingPathComponent(String(format: "%016llx", fnv1a(host))).path
    }

    static func stopMaster(host: String) {
        shutdown(host: host, activeForwards: [])
    }

    static func prepareMaster(host: String) -> SSHMasterPreparation {
        ensureMaster(host: host, socket: socketPath(for: host))
    }

    static func shutdown(host: String, activeForwards: Set<Int>) {
        let socket = socketPath(for: host)
        for port in activeForwards.sorted() {
            _ = control(host: host, socket: socket, operation: "cancel", port: port)
        }

        for _ in 0..<3 {
            _ = CommandRunner.run(
                ssh,
                arguments: ["-S", socket, "-o", "ControlMaster=no", "-O", "exit", host],
                timeout: 5
            )
            DomaSSHMasterRegistry.terminateMasters(socketPath: socket, keeping: nil)

            for _ in 0..<10 {
                let hasManagedMaster = DomaSSHMasterRegistry.masters().contains { $0.socketPath == socket }
                if checkMaster(host: host, socket: socket) == nil, !hasManagedMaster {
                    cleanupSocket(socket)
                    return
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
    }

    static func cycle(_ input: CycleInput) -> CycleResult {
        let socket = socketPath(for: input.host)
        let preparation = ensureMaster(host: input.host, socket: socket)
        guard let masterPID = preparation.pid else {
            return CycleResult(
                state: .failed,
                masterPID: nil,
                activeForwards: [],
                conflicts: [],
                missingSince: [:],
                services: [],
                remoteCount: 0,
                error: preparation.error ?? "Не удалось установить SSH-соединение",
                warning: nil,
                shouldRetryAutomatically: preparation.shouldRetryAutomatically,
                hostKeyChanged: preparation.hostKeyChanged
            )
        }

        let inventoryResult = queryInventory(host: input.host, socket: socket)
        guard inventoryResult.status == 0 else {
            let details = RemoteAccessErrorFormatter.inventoryDetails(
                host: input.host,
                result: inventoryResult
            )
            return CycleResult(
                state: .failed,
                masterPID: masterPID,
                activeForwards: input.activeForwards,
                conflicts: [],
                missingSince: input.missingSince,
                services: [],
                remoteCount: 0,
                error: details.message,
                warning: nil,
                shouldRetryAutomatically: details.shouldRetryAutomatically,
                hostKeyChanged: false
            )
        }

        let inventory = parseInventory(inventoryResult.stdout)
        let remotePorts = Set(inventory.listeners.map(\.port).filter { 1024...32767 ~= $0 })
        let local = LocalProcessController.listeners()

        var active = input.previousMasterPID == masterPID ? input.activeForwards : []
        var conflicts = Set<Int>()
        var missingSince = input.previousMasterPID == masterPID ? input.missingSince : [:]

        for port in Array(active) where !ownsForward(port: port, masterPID: masterPID, listeners: local) {
            active.remove(port)
            missingSince.removeValue(forKey: port)
        }

        let now = Date()
        for port in Array(active.subtracting(remotePorts)) {
            let missingAt = missingSince[port] ?? now
            missingSince[port] = missingAt
            guard now.timeIntervalSince(missingAt) >= disappearGrace else { continue }

            let result = control(host: input.host, socket: socket, operation: "cancel", port: port)
            if result.status == 0 {
                active.remove(port)
                missingSince.removeValue(forKey: port)
            }
        }

        for port in active.intersection(remotePorts) {
            missingSince.removeValue(forKey: port)
        }

        for port in remotePorts.sorted() where !active.contains(port) {
            guard active.count < forwardLimit else { break }

            if ownsForward(port: port, masterPID: masterPID, listeners: local) {
                active.insert(port)
                continue
            }

            if !(local[port]?.pids.isEmpty ?? true) {
                conflicts.insert(port)
                continue
            }

            let result = control(host: input.host, socket: socket, operation: "forward", port: port)
            if result.status == 0 {
                active.insert(port)
            } else {
                conflicts.insert(port)
            }
        }

        let services = makeServices(
            inventory: inventory,
            remotePorts: remotePorts,
            active: active,
            conflicts: conflicts,
            localListeners: local
        )

        return CycleResult(
            state: .connected,
            masterPID: masterPID,
            activeForwards: active,
            conflicts: conflicts,
            missingSince: missingSince,
            services: services,
            remoteCount: remotePorts.count,
            error: nil,
            warning: inventory.warningMessage,
            shouldRetryAutomatically: true,
            hostKeyChanged: false
        )
    }

    private static func fnv1a(_ value: String) -> UInt64 {
        value.utf8.reduce(14695981039346656037) { hash, byte in
            (hash ^ UInt64(byte)) &* 1099511628211
        }
    }

    private static func ensureMaster(host: String, socket: String) -> SSHMasterPreparation {
        if let pid = checkMaster(host: host, socket: socket) {
            DomaSSHMasterRegistry.terminateMasters(socketPath: socket, keeping: Int32(pid))
            return SSHMasterPreparation(
                pid: pid,
                error: nil,
                shouldRetryAutomatically: true,
                hostKeyChanged: false
            )
        }

        guard DomaSSHMasterRegistry.terminateMasters(socketPath: socket, keeping: nil) else {
            return SSHMasterPreparation(
                pid: nil,
                error: "Не удалось завершить прежнее SSH-соединение для \(host).",
                shouldRetryAutomatically: true,
                hostKeyChanged: false
            )
        }
        cleanupSocket(socket)
        let authentication = SSHAuthentication.configuration()
        let result = CommandRunner.run(
            ssh,
            arguments: [
                "-fMN",
                "-S", socket,
                "-o", "ControlMaster=yes",
                "-o", "ControlPersist=yes",
                "-o", "ServerAliveInterval=15",
                "-o", "ServerAliveCountMax=3",
                "-o", "TCPKeepAlive=yes",
                "-o", "BatchMode=\(authentication.batchMode)",
                "-o", "NumberOfPasswordPrompts=1",
                host,
            ],
            environment: authentication.environment,
            timeout: 300
        )
        guard result.status == 0 else {
            let details = SSHConnectionErrorFormatter.details(host: host, result: result)
            return SSHMasterPreparation(
                pid: nil,
                error: details.message,
                shouldRetryAutomatically: details.shouldRetryAutomatically,
                hostKeyChanged: details.hostKeyChanged
            )
        }

        for _ in 0..<20 {
            if let pid = checkMaster(host: host, socket: socket) {
                DomaSSHMasterRegistry.terminateMasters(socketPath: socket, keeping: Int32(pid))
                return SSHMasterPreparation(
                    pid: pid,
                    error: nil,
                    shouldRetryAutomatically: true,
                    hostKeyChanged: false
                )
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return SSHMasterPreparation(
            pid: nil,
            error: "SSH подключился к \(host), но Doma не получила control socket.",
            shouldRetryAutomatically: true,
            hostKeyChanged: false
        )
    }

    private static func checkMaster(host: String, socket: String) -> Int? {
        let result = CommandRunner.run(
            ssh,
            arguments: ["-S", socket, "-o", "ControlMaster=no", "-O", "check", host],
            timeout: 5
        )
        guard result.status == 0 else { return nil }
        return firstCapture(in: result.stdout + result.stderr, pattern: #"pid=(\d+)"#).flatMap(Int.init)
    }

    private static func cleanupSocket(_ socket: String) {
        let manager = FileManager.default
        try? manager.removeItem(atPath: socket)
        let directory = URL(fileURLWithPath: socket).deletingLastPathComponent()
        let prefix = URL(fileURLWithPath: socket).lastPathComponent + "."
        for candidate in (try? manager.contentsOfDirectory(atPath: directory.path)) ?? []
        where candidate.hasPrefix(prefix) {
            try? manager.removeItem(at: directory.appendingPathComponent(candidate))
        }
    }

    private static func control(host: String, socket: String, operation: String, port: Int) -> CommandResult {
        CommandRunner.run(
            ssh,
            arguments: [
                "-S", socket,
                "-o", "ControlMaster=no",
                "-O", operation,
                "-L", "\(bindAddress):\(port):localhost:\(port)",
                host,
            ],
            timeout: 5
        )
    }

    private static func queryInventory(host: String, socket: String) -> CommandResult {
        return CommandRunner.run(
            ssh,
            arguments: [
                "-S", socket,
                "-o", "ControlMaster=no",
                "-o", "ConnectTimeout=5",
                host,
                "--", "sh", "-s",
            ],
            stdin: inventoryScript,
            timeout: 10
        )
    }

    private static func ownsForward(port: Int, masterPID: Int, listeners: [Int: LocalListenerInfo]) -> Bool {
        guard let info = listeners[port], info.ownersByPID[Int32(masterPID)] != nil else { return false }
        return info.endpointsByPID[Int32(masterPID), default: []].contains {
            $0 == "\(bindAddress):\(port)" || $0.hasSuffix("\(bindAddress):\(port)")
        }
    }

    private struct Inventory {
        var listeners: [RawListener] = []
        var dockerByPort: [Int: DockerInfo] = [:]
        var processes: [Int: ProcessInfo] = [:]
        var cwdByPID: [Int: String] = [:]
        var warnings = Set<InventoryWarning>()

        var warningMessage: String? {
            let messages = warnings.sorted { $0.rawValue < $1.rawValue }.map(\.message)
            return messages.isEmpty ? nil : messages.joined(separator: " ")
        }
    }

    private enum InventoryWarning: String {
        case docker
        case processes

        var message: String {
            switch self {
            case .docker:
                "Метаданные Docker недоступны; порты продолжают пробрасываться как TCP."
            case .processes:
                "Метаданные процессов недоступны; порты продолжают пробрасываться как TCP."
            }
        }
    }

    private static func parseInventory(_ output: String) -> Inventory {
        enum Section { case none, ss, docker, ps, cwd }
        var section = Section.none
        var inventory = Inventory()

        for line in output.split(whereSeparator: \.isNewline).map(String.init) {
            if line == "__DOMA_WARNING_DOCKER__" {
                inventory.warnings.insert(.docker)
                continue
            }
            if line == "__DOMA_WARNING_PROCESSES__" {
                inventory.warnings.insert(.processes)
                continue
            }

            switch line {
            case "__SS__": section = .ss
            case "__DOCKER__": section = .docker
            case "__PS__": section = .ps
            case "__CWD__": section = .cwd
            default:
                switch section {
                case .ss:
                    let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
                    guard fields.count >= 4,
                          let port = firstCapture(in: fields[3], pattern: #":(\d+)$"#).flatMap(Int.init)
                    else { continue }
                    let pid = firstCapture(in: line, pattern: #"pid=(\d+)"#).flatMap(Int.init)
                    let command = firstCapture(in: line, pattern: #"\(\(\"([^\"]+)\""#)
                    inventory.listeners.append(RawListener(port: port, pid: pid, command: command))
                case .docker:
                    let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                    guard fields.count >= 4 else { continue }
                    let info = DockerInfo(container: fields[0], project: fields[2], service: fields[3])
                    for port in captures(in: fields[1], pattern: #"(?:^|,\s)(?:[^,]*:)?(\d+)->\d+/tcp"#).compactMap(Int.init) {
                        inventory.dockerByPort[port] = info
                    }
                case .ps:
                    guard let groups = captureGroups(in: line, pattern: #"^\s*(\d+)\s+(\S+)\s+(.*)$"#),
                          let pid = Int(groups[0])
                    else { continue }
                    inventory.processes[pid] = ProcessInfo(command: groups[1], arguments: groups[2])
                case .cwd:
                    let fields = line.split(separator: "|", maxSplits: 1).map(String.init)
                    if fields.count == 2, let pid = Int(fields[0]) {
                        inventory.cwdByPID[pid] = fields[1]
                    }
                case .none:
                    break
                }
            }
        }
        return inventory
    }

    static func inventoryWarning(in output: String) -> String? {
        parseInventory(output).warningMessage
    }

    private static func makeServices(
        inventory: Inventory,
        remotePorts: Set<Int>,
        active: Set<Int>,
        conflicts: Set<Int>,
        localListeners: [Int: LocalListenerInfo]
    ) -> [RemoteService] {
        let listenerByPort = Dictionary(inventory.listeners.map { ($0.port, $0) }, uniquingKeysWith: { first, _ in first })

        return remotePorts.sorted().map { port in
            let listener = listenerByPort[port]
            let process = listener?.pid.flatMap { inventory.processes[$0] }
            let cwd = listener?.pid.flatMap { inventory.cwdByPID[$0] }

            let kind: ServiceKind
            let group: String
            let name: String
            let details: String

            if let docker = inventory.dockerByPort[port] {
                kind = .docker
                group = docker.project.isEmpty ? "Docker" : docker.project
                name = docker.service.isEmpty ? docker.container : docker.service
                details = docker.container
            } else {
                let arguments = process?.arguments ?? ""
                let executable = (process?.command ?? listener?.command ?? "TCP").lowercased()
                if arguments.lowercased().contains("vite") {
                    kind = .vite
                    group = cwd ?? "Vite"
                    name = "Vite"
                } else if executable.contains("node") {
                    kind = .node
                    group = cwd ?? "Node"
                    name = "Node"
                } else if executable.contains("python") {
                    kind = .python
                    group = cwd ?? "Python"
                    name = "Python"
                } else {
                    kind = .system
                    group = "Другие сервисы"
                    name = process?.command ?? listener?.command ?? "TCP"
                }
                details = arguments.isEmpty ? (cwd ?? "") : arguments
            }

            return RemoteService(
                port: port,
                name: name,
                group: group,
                kind: kind,
                details: details,
                isForwarded: active.contains(port),
                hasConflict: conflicts.contains(port),
                conflictOwners: conflicts.contains(port) ? (localListeners[port]?.owners ?? []) : []
            )
        }
    }

    private static func firstCapture(in text: String, pattern: String) -> String? {
        captureGroups(in: text, pattern: pattern)?.first
    }

    private static func captures(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1, let capture = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[capture])
        }
    }

    private static func captureGroups(in text: String, pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
        else { return nil }

        return (1..<match.numberOfRanges).compactMap { index in
            guard let range = Range(match.range(at: index), in: text) else { return nil }
            return String(text[range])
        }
    }

}
