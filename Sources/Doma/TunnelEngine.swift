import Darwin
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

    static func stopMaster(host: String) async {
        await shutdown(host: host, activeForwards: [])
    }

    static func prepareMaster(host: String) async -> SSHMasterPreparation {
        await ensureMaster(host: host, socket: socketPath(for: host))
    }

    static func shutdown(host: String, activeForwards _: Set<Int>) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                shutdownSynchronously(host: host)
                continuation.resume()
            }
        }
    }

    private static func shutdownSynchronously(host: String) {
        let socket = socketPath(for: host)
        // Exiting the master closes every owned forward in one bounded operation.
        for attempt in 0..<5 {
            _ = CommandRunner.run(
                ssh,
                arguments: [
                    "-S", socket,
                    "-o", "ControlMaster=no",
                    "-O", "exit",
                    host,
                ],
                timeout: 2
            )
            _ = DomaSSHMasterRegistry.terminateMasters(socketPath: socket, keeping: nil)
            let master = checkMasterSynchronously(host: host, socket: socket)
            if let master {
                _ = Darwin.kill(pid_t(master), attempt < 2 ? SIGTERM : SIGKILL)
            }
            let registry = DomaSSHMasterRegistry.snapshot()
            let hasManagedMaster = registry.masters.contains { $0.socketPath == socket }
            if registry.isAuthoritative, master == nil, !hasManagedMaster {
                cleanupSocket(socket)
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        // Keep an unverifiable socket as a recovery handle. Removing it could orphan a master.
    }

    static func masterArguments(
        host: String,
        socket: String,
        authentication: SSHAuthenticationConfiguration,
        requiresExplicitConfirmation: Bool
    ) -> [String] {
        var arguments = [
            "-fMN",
            "-S", socket,
            "-o", "ControlMaster=yes",
            "-o", "ControlPersist=yes",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "TCPKeepAlive=yes",
            "-o", "BatchMode=\(authentication.batchMode)",
            "-o", "NumberOfPasswordPrompts=1",
        ]
        arguments.append(contentsOf: SSHInvocation.securityOptions)
        if requiresExplicitConfirmation {
            arguments.append(contentsOf: ["-o", "StrictHostKeyChecking=ask", "-o", "UpdateHostKeys=no"])
        }
        arguments.append(host)
        return arguments
    }

    static func inventoryArguments(host: String, socket: String) -> [String] {
        var arguments = [
            "-S", socket,
            "-o", "ControlMaster=no",
            "-o", "ConnectTimeout=5",
        ]
        arguments.append(contentsOf: SSHInvocation.securityOptions)
        arguments.append(contentsOf: [host, "--", "sh", "-s"])
        return arguments
    }

    static func cycle(_ input: CycleInput) async -> CycleResult {
        let socket = socketPath(for: input.host)
        let preparation = await ensureMaster(host: input.host, socket: socket)
        if Task.isCancelled {
            return cancelledCycleResult(input)
        }
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

        let inventoryResult = await queryInventory(host: input.host, socket: socket)
        if Task.isCancelled {
            return cancelledCycleResult(input)
        }
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
        guard inventory.sawSocketSection else {
            return CycleResult(
                state: .failed,
                masterPID: masterPID,
                activeForwards: input.activeForwards,
                conflicts: [],
                missingSince: input.missingSince,
                services: [],
                remoteCount: 0,
                error: "SSH-сервер \(input.host) вернул неполный inventory без обязательной секции listening sockets. Состояние пробросов не изменено.",
                warning: nil,
                shouldRetryAutomatically: true,
                hostKeyChanged: false,
                forwardingStateIsAuthoritative: false
            )
        }
        let remotePorts = Set(inventory.listeners.map(\.port).filter { 1024...32767 ~= $0 })
        let localSnapshot = await LocalProcessController.snapshot()
        if Task.isCancelled {
            return cancelledCycleResult(input)
        }
        guard localSnapshot.isAuthoritative else {
            return CycleResult(
                state: .connected,
                masterPID: masterPID,
                activeForwards: input.activeForwards,
                conflicts: [],
                missingSince: input.missingSince,
                services: makeServices(
                    inventory: inventory,
                    remotePorts: remotePorts,
                    active: [],
                    conflicts: [],
                    localListeners: [:]
                ),
                remoteCount: remotePorts.count,
                error: nil,
                warning: combinedWarning(inventory.warningMessage, localSnapshot.warning),
                shouldRetryAutomatically: true,
                hostKeyChanged: false,
                forwardingStateIsAuthoritative: false
            )
        }
        let local = localSnapshot.listeners

        var active = input.previousMasterPID == masterPID ? input.activeForwards : []
        var conflicts = Set<Int>()
        var missingSince = input.previousMasterPID == masterPID ? input.missingSince : [:]

        for port in Array(active) where !ownsForward(port: port, masterPID: masterPID, listeners: local) {
            if Task.isCancelled { return cancelledCycleResult(input) }
            active.remove(port)
            missingSince.removeValue(forKey: port)
        }

        let now = Date()
        for port in Array(active.subtracting(remotePorts)) {
            let missingAt = missingSince[port] ?? now
            missingSince[port] = missingAt
            guard now.timeIntervalSince(missingAt) >= disappearGrace else { continue }

            if Task.isCancelled { return cancelledCycleResult(input) }
            let result = await control(host: input.host, socket: socket, operation: "cancel", port: port)
            if Task.isCancelled { return cancelledCycleResult(input) }
            if result.status == 0 {
                active.remove(port)
                missingSince.removeValue(forKey: port)
            } else {
                let checkedPID = await checkMaster(host: input.host, socket: socket)
                if Task.isCancelled {
                    cancelDiscoveredMaster(checkedPID, socket: socket)
                    return cancelledCycleResult(input)
                }
                if checkedPID == nil {
                    return connectionLostResult(input: input, result: result)
                }
            }
        }

        for port in active.intersection(remotePorts) {
            missingSince.removeValue(forKey: port)
        }

        for port in remotePorts.sorted() where !active.contains(port) {
            if Task.isCancelled { return cancelledCycleResult(input) }
            guard active.count < forwardLimit else { break }

            if ownsForward(port: port, masterPID: masterPID, listeners: local) {
                active.insert(port)
                continue
            }

            if !(local[port]?.pids.isEmpty ?? true) {
                conflicts.insert(port)
                continue
            }

            let result = await control(host: input.host, socket: socket, operation: "forward", port: port)
            if Task.isCancelled { return cancelledCycleResult(input) }
            if result.status == 0 {
                active.insert(port)
            } else {
                let checkedPID = await checkMaster(host: input.host, socket: socket)
                if Task.isCancelled {
                    cancelDiscoveredMaster(checkedPID, socket: socket)
                    return cancelledCycleResult(input)
                }
                if checkedPID == nil {
                    return connectionLostResult(input: input, result: result)
                }
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
            warning: combinedWarning(inventory.warningMessage, localSnapshot.warning),
            shouldRetryAutomatically: true,
            hostKeyChanged: false
        )
    }

    private static func fnv1a(_ value: String) -> UInt64 {
        value.utf8.reduce(14695981039346656037) { hash, byte in
            (hash ^ UInt64(byte)) &* 1099511628211
        }
    }

    private static func ensureMaster(host: String, socket: String) async -> SSHMasterPreparation {
        guard let knownHostsPlan = await SSHKnownHostsManager.resolvePlanAsync(host: host) else {
            return SSHMasterPreparation(
                pid: nil,
                error: "Не удалось безопасно определить effective known_hosts target для \(host). Подключение остановлено.",
                shouldRetryAutomatically: false,
                hostKeyChanged: false
            )
        }
        let hostKeyTarget = knownHostsPlan.target
        let requiresConfirmation: Bool
        do {
            requiresConfirmation = try SSHHostTrustState.requiresExplicitConfirmation(for: hostKeyTarget)
        } catch {
            return SSHMasterPreparation(
                pid: nil,
                error: "Не удалось безопасно проверить состояние подтверждения SSH-ключа для \(host). Подключение остановлено.\n\n\(error.localizedDescription)",
                shouldRetryAutomatically: false,
                hostKeyChanged: false
            )
        }
        if !requiresConfirmation {
            let existingPID = await checkMaster(host: host, socket: socket)
            if Task.isCancelled {
                cancelDiscoveredMaster(existingPID, socket: socket)
                return cancelledPreparation()
            }
            if let existingPID {
                _ = await DomaSSHMasterRegistry.terminateMastersAsync(
                    socketPath: socket,
                    keeping: Int32(existingPID)
                )
                if Task.isCancelled {
                    cancelDiscoveredMaster(existingPID, socket: socket)
                    return cancelledPreparation()
                }
                return SSHMasterPreparation(
                    pid: existingPID,
                    error: nil,
                    shouldRetryAutomatically: true,
                    hostKeyChanged: false
                )
            }
        }

        guard await DomaSSHMasterRegistry.terminateMastersAsync(socketPath: socket, keeping: nil) else {
            if Task.isCancelled {
                _ = DomaSSHMasterRegistry.terminateMasters(socketPath: socket, keeping: nil)
                cleanupSocket(socket)
                return cancelledPreparation()
            }
            return SSHMasterPreparation(
                pid: nil,
                error: "Не удалось завершить прежнее SSH-соединение для \(host).",
                shouldRetryAutomatically: true,
                hostKeyChanged: false
            )
        }
        cleanupSocket(socket)
        let authentication = SSHAuthentication.configuration()
        let arguments = masterArguments(
            host: host,
            socket: socket,
            authentication: authentication,
            requiresExplicitConfirmation: requiresConfirmation
        )
        let result = await CommandRunner.runAsync(
            ssh,
            arguments: arguments,
            environment: authentication.environment,
            timeout: 300
        )
        if Task.isCancelled {
            _ = DomaSSHMasterRegistry.terminateMasters(socketPath: socket, keeping: nil)
            cleanupSocket(socket)
            return cancelledPreparation()
        }
        guard result.status == 0 else {
            _ = await DomaSSHMasterRegistry.terminateMastersAsync(socketPath: socket, keeping: nil)
            cleanupSocket(socket)
            let details = SSHConnectionErrorFormatter.details(host: host, result: result)
            return SSHMasterPreparation(
                pid: nil,
                error: details.message,
                shouldRetryAutomatically: details.shouldRetryAutomatically,
                hostKeyChanged: details.hostKeyChanged
            )
        }

        for _ in 0..<20 {
            if Task.isCancelled {
                _ = DomaSSHMasterRegistry.terminateMasters(socketPath: socket, keeping: nil)
                cleanupSocket(socket)
                return cancelledPreparation()
            }
            let discoveredPID = await checkMaster(host: host, socket: socket)
            if Task.isCancelled {
                cancelDiscoveredMaster(discoveredPID, socket: socket)
                return cancelledPreparation()
            }
            if let discoveredPID {
                _ = await DomaSSHMasterRegistry.terminateMastersAsync(
                    socketPath: socket,
                    keeping: Int32(discoveredPID)
                )
                if Task.isCancelled {
                    cancelDiscoveredMaster(discoveredPID, socket: socket)
                    return cancelledPreparation()
                }
                if requiresConfirmation {
                    try? SSHHostTrustState.markConfirmed(target: hostKeyTarget)
                }
                return SSHMasterPreparation(
                    pid: discoveredPID,
                    error: nil,
                    shouldRetryAutomatically: true,
                    hostKeyChanged: false
                )
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return SSHMasterPreparation(
            pid: nil,
            error: "SSH подключился к \(host), но Doma не получила control socket.",
            shouldRetryAutomatically: true,
            hostKeyChanged: false
        )
    }

    private static func checkMaster(host: String, socket: String) async -> Int? {
        let result = await CommandRunner.runAsync(
            ssh,
            arguments: ["-S", socket, "-o", "ControlMaster=no", "-O", "check", host],
            timeout: 5
        )
        guard result.status == 0 else { return nil }
        return firstCapture(in: result.stdout + result.stderr, pattern: #"pid=(\d+)"#).flatMap(Int.init)
    }

    private static func checkMasterSynchronously(host: String, socket: String) -> Int? {
        let result = CommandRunner.run(
            ssh,
            arguments: ["-S", socket, "-o", "ControlMaster=no", "-O", "check", host],
            timeout: 2
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

    private static func control(host: String, socket: String, operation: String, port: Int) async -> CommandResult {
        await CommandRunner.runAsync(
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

    private static func queryInventory(host: String, socket: String) async -> CommandResult {
        return await CommandRunner.runAsync(
            ssh,
            arguments: inventoryArguments(host: host, socket: socket),
            stdin: inventoryScript,
            timeout: 10
        )
    }

    private static func cancelledPreparation() -> SSHMasterPreparation {
        SSHMasterPreparation(
            pid: nil,
            error: "SSH-подключение отменено.",
            shouldRetryAutomatically: false,
            hostKeyChanged: false
        )
    }

    private static func cancelDiscoveredMaster(_ pid: Int?, socket: String) {
        if let pid {
            _ = Darwin.kill(pid_t(pid), SIGTERM)
        }
        _ = DomaSSHMasterRegistry.terminateMasters(socketPath: socket, keeping: nil)
        cleanupSocket(socket)
    }

    private static func ownsForward(port: Int, masterPID: Int, listeners: [Int: LocalListenerInfo]) -> Bool {
        guard let info = listeners[port], info.ownersByPID[Int32(masterPID)] != nil else { return false }
        return info.endpointsByPID[Int32(masterPID), default: []].contains {
            $0 == "\(bindAddress):\(port)" || $0.hasSuffix("\(bindAddress):\(port)")
        }
    }

    static func connectionLostResult(input: CycleInput, result: CommandResult) -> CycleResult {
        let details = SSHConnectionErrorFormatter.details(host: input.host, result: result)
        return CycleResult(
            state: .failed,
            masterPID: nil,
            activeForwards: input.activeForwards,
            conflicts: [],
            missingSince: input.missingSince,
            services: [],
            remoteCount: 0,
            error: "SSH-соединение с \(input.host) потеряно во время изменения проброса.\n\n\(details.message)",
            warning: nil,
            shouldRetryAutomatically: true,
            hostKeyChanged: false
        )
    }

    private static func cancelledCycleResult(_ input: CycleInput) -> CycleResult {
        CycleResult(
            state: .disconnected,
            masterPID: nil,
            activeForwards: input.activeForwards,
            conflicts: [],
            missingSince: input.missingSince,
            services: [],
            remoteCount: 0,
            error: nil,
            warning: nil,
            shouldRetryAutomatically: false,
            hostKeyChanged: false,
            forwardingStateIsAuthoritative: false
        )
    }

    private static func combinedWarning(_ first: String?, _ second: String?) -> String? {
        let warning = [first, second].compactMap { $0 }.joined(separator: " ")
        return warning.isEmpty ? nil : warning
    }

    private struct Inventory {
        var listeners: [RawListener] = []
        var dockerByPort: [Int: DockerInfo] = [:]
        var processes: [Int: ProcessInfo] = [:]
        var cwdByPID: [Int: String] = [:]
        var warnings = Set<InventoryWarning>()
        var sawSocketSection = false
        var sawProcessSection = false

        var warningMessage: String? {
            let messages = warnings.sorted { $0.rawValue < $1.rawValue }.map(\.message)
            return messages.isEmpty ? nil : messages.joined(separator: " ")
        }
    }

    private enum InventoryWarning: String {
        case docker
        case partialProcesses
        case partialSockets
        case processes
        case protocolSections

        var message: String {
            switch self {
            case .docker:
                "Метаданные Docker недоступны; порты продолжают пробрасываться как TCP."
            case .processes:
                "Метаданные процессов недоступны; порты продолжают пробрасываться как TCP."
            case .partialSockets:
                "Часть listening sockets пришла без PID/имени процесса; TCP-пробросы продолжают работать."
            case .partialProcesses:
                "Часть процессов не сопоставилась с listening sockets; TCP-пробросы продолжают работать."
            case .protocolSections:
                "Удалённый inventory вернул неполный набор секций; доступные TCP-порты продолжают пробрасываться."
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
            case "__SS__":
                inventory.sawSocketSection = true
                section = .ss
            case "__DOCKER__": section = .docker
            case "__PS__":
                inventory.sawProcessSection = true
                section = .ps
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
        if !inventory.sawProcessSection {
            inventory.warnings.insert(.protocolSections)
        }
        if inventory.listeners.contains(where: { $0.pid == nil || $0.command == nil }) {
            inventory.warnings.insert(.partialSockets)
        }
        let listenerPIDs = Set(inventory.listeners.compactMap(\.pid))
        let missingProcessCount = listenerPIDs.subtracting(inventory.processes.keys).count
        if missingProcessCount >= max(1, listenerPIDs.count / 2), !listenerPIDs.isEmpty {
            inventory.warnings.insert(.partialProcesses)
        }
        return inventory
    }

    static func inventoryWarning(in output: String) -> String? {
        parseInventory(output).warningMessage
    }

    static func hasMandatorySocketSection(in output: String) -> Bool {
        parseInventory(output).sawSocketSection
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
