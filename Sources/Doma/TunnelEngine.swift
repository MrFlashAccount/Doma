import Darwin
import Foundation

enum TunnelEngine {
    private static let ssh = "/usr/bin/ssh"
    private static let bindAddress = "127.0.0.1"
    private static let forwardLimit = 128
    static let disappearGrace: TimeInterval = 10
    static let inventoryScript = #"""
    printf '__USER__\n'
    id -u
    printf '__SS__\n'
    ss_output=$(ss -H -ltnpe 2>&1)
    ss_status=$?
    if [ "$ss_status" -ne 0 ]; then
      printf '__DOMA_SOCKET_SCAN_FAILED__ %s\n' "$ss_output" >&2
      exit "$ss_status"
    fi
    printf '%s\n' "$ss_output"
    printf '__DOCKER__\n'
    if command -v docker >/dev/null 2>&1; then
      docker_output=$(docker ps --format '{{.Names}}|{{.Image}}|{{.Ports}}|{{.Label "com.docker.compose.project"}}|{{.Label "com.docker.compose.service"}}' 2>&1)
      if [ "$?" -eq 0 ]; then
        printf '%s\n' "$docker_output"
      else
        printf '__DOMA_WARNING_DOCKER__\n'
      fi
    fi
    printf '__PS__\n'
    ps_output=$(ps -eo pid=,ppid=,uid=,user=,comm=,args= 2>&1)
    if [ "$?" -eq 0 ]; then
      printf '%s\n' "$ps_output"
    else
      printf '__DOMA_WARNING_PROCESSES__\n'
    fi
    printf '__CWD__\n'
    printf '%s\n' "$ss_output" | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' | sort -u | while read -r pid; do
      cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null)
      [ -n "$cwd" ] || continue
      printf '%s|%s\n' "$pid" "$cwd"
    done
    """#

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

        let inventory = RemoteInventoryParser.parse(inventoryResult.stdout)
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
        let remotePorts = eligibleRemotePorts(in: inventory)
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
        return RemoteTextMatching.firstCapture(
            in: result.stdout + result.stderr,
            pattern: #"pid=(\d+)"#
        ).flatMap(Int.init)
    }

    private static func checkMasterSynchronously(host: String, socket: String) -> Int? {
        let result = CommandRunner.run(
            ssh,
            arguments: ["-S", socket, "-o", "ControlMaster=no", "-O", "check", host],
            timeout: 2
        )
        guard result.status == 0 else { return nil }
        return RemoteTextMatching.firstCapture(
            in: result.stdout + result.stderr,
            pattern: #"pid=(\d+)"#
        ).flatMap(Int.init)
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

    static func inventoryWarning(in output: String) -> String? {
        RemoteInventoryParser.parse(output).warningMessage
    }

    static func hasMandatorySocketSection(in output: String) -> Bool {
        RemoteInventoryParser.parse(output).sawSocketSection
    }

    private static func eligibleRemotePorts(in inventory: RemoteInventory) -> Set<Int> {
        RemoteServiceRecognitionPipeline(inventory: inventory).eligiblePorts
    }

    static func services(fromInventoryOutput output: String, activePorts: Set<Int> = []) -> [RemoteService] {
        let inventory = RemoteInventoryParser.parse(output)
        return makeServices(
            inventory: inventory,
            remotePorts: eligibleRemotePorts(in: inventory),
            active: activePorts,
            conflicts: [],
            localListeners: [:]
        )
    }

    private static func makeServices(
        inventory: RemoteInventory,
        remotePorts: Set<Int>,
        active: Set<Int>,
        conflicts: Set<Int>,
        localListeners: [Int: LocalListenerInfo]
    ) -> [RemoteService] {
        let pipeline = RemoteServiceRecognitionPipeline(inventory: inventory)

        return remotePorts.sorted().map { port in
            let recognized = pipeline.recognize(port: port)

            return RemoteService(
                port: port,
                name: recognized.name,
                group: recognized.group,
                kind: recognized.kind,
                details: recognized.details,
                isForwarded: active.contains(port),
                hasConflict: conflicts.contains(port),
                conflictOwners: conflicts.contains(port) ? (localListeners[port]?.owners ?? []) : []
            )
        }
    }
}
