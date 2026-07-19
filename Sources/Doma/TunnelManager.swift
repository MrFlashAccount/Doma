import AppKit
import Foundation

@MainActor
final class TunnelManager: ObservableObject {
    private static let fullResyncInterval: TimeInterval = 300
    private static let conflictRetryInterval: TimeInterval = 15

    @Published private(set) var hosts: [SSHHost] = []
    @Published private(set) var selectedHost = ""
    @Published private(set) var state: ConnectionState = .disconnected
    @Published private(set) var services: [RemoteService] = []
    @Published private(set) var activeCount = 0
    @Published private(set) var conflictCount = 0
    @Published private(set) var remoteCount = 0
    @Published private(set) var lastError: String?
    @Published private(set) var lastSync: Date?
    @Published private(set) var isSyncing = false
    @Published private(set) var resolvingPorts = Set<Int>()
    @Published private(set) var conflictResolutionError: String?

    private var masterPID: Int?
    private var activeForwards = Set<Int>()
    private var missingSince: [Int: Date] = [:]
    private var monitor: RemoteInventoryMonitor?
    private var monitorHost: String?
    private var connectionTask: Task<Void, Never>?
    private var connectionGeneration: UUID?
    private var syncTask: Task<Void, Never>?
    private var resyncTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var disappearanceTask: Task<Void, Never>?
    private var conflictRetryTask: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?
    private var shutdownCompletions: [@MainActor () -> Void] = []
    private var syncPending = false
    private var reconnectAttempt = 0
    private var isShuttingDown = false

    init(preview: Bool = false) {
        #if DEBUG
        if preview {
            loadPreviewState()
            return
        }
        #endif

        reloadHosts()
        let saved = UserDefaults.standard.string(forKey: "selectedHost")
        selectedHost = hosts.contains(where: { $0.alias == saved })
            ? saved!
            : (hosts.first(where: { $0.alias == "buddy" })?.alias ?? hosts.first?.alias ?? "")
        beginMonitoring()
    }

    #if DEBUG
    private func loadPreviewState() {
        let project = "studio"
        hosts = [SSHHost(alias: project), SSHHost(alias: "staging")]
        selectedHost = project
        state = .connected
        services = [
            RemoteService(
                port: 4174,
                name: "Vite",
                group: "~/Projects/atlas",
                kind: .vite,
                details: "vite --host 127.0.0.1",
                isForwarded: true,
                hasConflict: false,
                conflictOwners: []
            ),
            RemoteService(
                port: 8765,
                name: "Python",
                group: "~/Projects/atlas",
                kind: .python,
                details: "python3 -m http.server",
                isForwarded: false,
                hasConflict: true,
                conflictOwners: [
                    LocalPortOwner(
                        pid: 4312,
                        name: "python3",
                        userID: getuid(),
                        terminationBlockReason: nil
                    ),
                ]
            ),
            RemoteService(
                port: 12000,
                name: "root-front",
                group: "atlas-compose",
                kind: .docker,
                details: "atlas-root-front",
                isForwarded: true,
                hasConflict: false,
                conflictOwners: []
            ),
            RemoteService(
                port: 12010,
                name: "document",
                group: "atlas-compose",
                kind: .docker,
                details: "atlas-document",
                isForwarded: true,
                hasConflict: false,
                conflictOwners: []
            ),
            RemoteService(
                port: 12012,
                name: "spreadsheet",
                group: "atlas-compose",
                kind: .docker,
                details: "atlas-spreadsheet",
                isForwarded: true,
                hasConflict: false,
                conflictOwners: []
            ),
        ]
        activeCount = services.count(where: \.isForwarded)
        conflictCount = services.count(where: \.hasConflict)
        remoteCount = services.count
        lastSync = Date()
    }
    #endif

    deinit {
        monitor?.stop()
        connectionTask?.cancel()
        syncTask?.cancel()
        resyncTask?.cancel()
        reconnectTask?.cancel()
        disappearanceTask?.cancel()
        conflictRetryTask?.cancel()
        shutdownTask?.cancel()
    }

    var groupedServices: [(String, [RemoteService])] {
        Dictionary(grouping: services, by: \.group)
            .map { ($0.key, $0.value.sorted { $0.port < $1.port }) }
            .sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
    }

    func reloadHosts() {
        hosts = SSHConfig.hosts()
    }

    func selectHost(_ alias: String) {
        guard alias != selectedHost else { return }
        let previous = selectedHost
        stopMonitoring()
        selectedHost = alias
        UserDefaults.standard.set(alias, forKey: "selectedHost")
        resetRuntime()

        Task.detached {
            if !previous.isEmpty {
                TunnelEngine.stopMaster(host: previous)
            }
        }
        beginMonitoring()
    }

    func reconnect() {
        guard !selectedHost.isEmpty else { return }
        let host = selectedHost
        stopMonitoring()
        state = .connecting
        resetRuntime(keepState: true)
        let generation = UUID()
        connectionGeneration = generation
        connectionTask = Task { [weak self] in
            await Task.detached { TunnelEngine.stopMaster(host: host) }.value
            guard let self, connectionGeneration == generation else { return }
            connectionTask = nil
            connectionGeneration = nil
            guard !Task.isCancelled, selectedHost == host, !isShuttingDown else { return }
            beginMonitoring()
        }
    }

    func syncNow() {
        guard monitor != nil else {
            if connectionTask == nil {
                beginMonitoring()
            }
            return
        }
        requestSync()
    }

    func openService(_ service: RemoteService) {
        guard service.isForwarded,
              let url = URL(string: "http://127.0.0.1:\(service.port)/")
        else { return }
        NSWorkspace.shared.open(url)
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    func shutdown(completion: @escaping @MainActor () -> Void) {
        shutdownCompletions.append(completion)
        guard shutdownTask == nil else { return }

        isShuttingDown = true
        stopMonitoring()
        state = .disconnected

        shutdownTask = Task { [weak self] in
            guard let self else { return }

            while isSyncing {
                try? await Task.sleep(for: .milliseconds(50))
            }

            let host = selectedHost
            let forwards = activeForwards
            if !host.isEmpty {
                await Task.detached {
                    TunnelEngine.shutdown(host: host, activeForwards: forwards)
                }.value
            }

            resetRuntime()
            resolvingPorts = []
            conflictResolutionError = nil
            let completions = shutdownCompletions
            shutdownCompletions = []
            shutdownTask = nil
            completions.forEach { $0() }
        }
    }

    func resolveConflict(for service: RemoteService) {
        guard service.hasConflict,
              !service.conflictOwners.isEmpty,
              service.conflictOwners.allSatisfy(\.canTerminate),
              !resolvingPorts.contains(service.port),
              !isShuttingDown
        else { return }

        let port = service.port
        let owners = service.conflictOwners
        resolvingPorts.insert(port)
        conflictResolutionError = nil

        Task {
            let error = await Task.detached {
                LocalProcessController.terminate(owners, on: port)
            }.value
            resolvingPorts.remove(port)
            conflictResolutionError = error
            requestSync()
        }
    }

    func clearConflictResolutionError() {
        conflictResolutionError = nil
    }

    private func beginMonitoring() {
        guard !selectedHost.isEmpty,
              !isShuttingDown,
              monitor == nil,
              connectionTask == nil
        else { return }

        let host = selectedHost
        let generation = UUID()
        state = .connecting
        reconnectTask?.cancel()
        reconnectTask = nil
        connectionGeneration = generation

        connectionTask = Task { [weak self] in
            let masterPID = await Task.detached {
                TunnelEngine.prepareMaster(host: host)
            }.value

            guard let self else { return }
            guard connectionGeneration == generation else { return }
            connectionTask = nil
            connectionGeneration = nil
            guard !Task.isCancelled, selectedHost == host, !isShuttingDown else {
                return
            }
            guard let masterPID else {
                state = .failed
                lastError = "Не удалось установить SSH-соединение"
                scheduleReconnect(for: host)
                return
            }

            self.masterPID = masterPID
            let monitor = RemoteInventoryMonitor(
                host: host,
                socketPath: TunnelEngine.socketPath(for: host)
            )
            do {
                try monitor.start(
                    onChange: { [weak self] in
                        Task { @MainActor in
                            self?.handleInventoryChange(for: host)
                        }
                    },
                    onTermination: { [weak self] error in
                        Task { @MainActor in
                            self?.handleMonitorTermination(for: host, error: error)
                        }
                    }
                )
                self.monitor = monitor
                monitorHost = host
                startResyncLoop(for: host)
            } catch {
                state = .failed
                lastError = error.localizedDescription
                scheduleReconnect(for: host)
            }
        }
    }

    private func handleInventoryChange(for host: String) {
        guard monitorHost == host, selectedHost == host, !isShuttingDown else { return }
        requestSync()
    }

    private func handleMonitorTermination(for host: String, error: String?) {
        guard monitorHost == host, selectedHost == host, !isShuttingDown else { return }
        monitor = nil
        monitorHost = nil
        resyncTask?.cancel()
        resyncTask = nil
        disappearanceTask?.cancel()
        disappearanceTask = nil
        conflictRetryTask?.cancel()
        conflictRetryTask = nil
        syncTask?.cancel()
        syncPending = false
        state = .failed
        lastError = error ?? "Соединение с удалённым монитором закрыто"
        scheduleReconnect(for: host)
    }

    private func stopMonitoring() {
        monitor?.stop()
        monitor = nil
        monitorHost = nil
        connectionTask?.cancel()
        connectionTask = nil
        connectionGeneration = nil
        syncTask?.cancel()
        resyncTask?.cancel()
        resyncTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        disappearanceTask?.cancel()
        disappearanceTask = nil
        conflictRetryTask?.cancel()
        conflictRetryTask = nil
        syncPending = false
    }

    private func scheduleReconnect(for host: String) {
        guard selectedHost == host, !isShuttingDown, reconnectTask == nil else { return }
        reconnectAttempt += 1
        let delay = min(30, 1 << min(reconnectAttempt - 1, 5))
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, selectedHost == host, !isShuttingDown else { return }
            reconnectTask = nil
            beginMonitoring()
        }
    }

    private func startResyncLoop(for host: String) {
        resyncTask?.cancel()
        resyncTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.fullResyncInterval))
                guard let self, !Task.isCancelled, monitorHost == host else { return }
                requestSync()
            }
        }
    }

    private func requestSync() {
        guard !selectedHost.isEmpty, !isShuttingDown, monitor != nil else { return }
        syncPending = true
        guard syncTask == nil else { return }
        syncTask = Task { [weak self] in
            await self?.drainSyncRequests()
        }
    }

    private func drainSyncRequests() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer {
            isSyncing = false
            syncTask = nil
            if syncPending, !isShuttingDown {
                requestSync()
            }
        }

        while syncPending, !Task.isCancelled, !isShuttingDown, monitor != nil {
            syncPending = false
            let host = selectedHost
            if masterPID == nil {
                state = .connecting
            }

            let input = CycleInput(
                host: host,
                previousMasterPID: masterPID,
                activeForwards: activeForwards,
                missingSince: missingSince
            )
            let result = await Task.detached { TunnelEngine.cycle(input) }.value
            guard !Task.isCancelled,
                  selectedHost == host,
                  monitorHost == host,
                  !isShuttingDown
            else { continue }
            apply(result, for: host)
        }
    }

    private func apply(_ result: CycleResult, for host: String) {
        masterPID = result.masterPID
        activeForwards = result.activeForwards
        missingSince = result.missingSince
        services = result.services
        state = result.state
        activeCount = result.activeForwards.count
        conflictCount = result.conflicts.count
        remoteCount = result.remoteCount
        lastError = result.error
        lastSync = Date()
        persistStatus(result)
        scheduleDisappearanceSync()
        scheduleConflictRetry(hasConflicts: !result.conflicts.isEmpty)

        if result.state == .failed {
            syncPending = false
            monitor?.stop()
            monitor = nil
            monitorHost = nil
            resyncTask?.cancel()
            resyncTask = nil
            disappearanceTask?.cancel()
            disappearanceTask = nil
            conflictRetryTask?.cancel()
            conflictRetryTask = nil
            scheduleReconnect(for: host)
        } else {
            reconnectAttempt = 0
        }
    }

    private func scheduleDisappearanceSync() {
        disappearanceTask?.cancel()
        disappearanceTask = nil
        guard let earliest = missingSince.values.min() else { return }
        let delay = max(2, earliest.addingTimeInterval(TunnelEngine.disappearGrace).timeIntervalSinceNow)
        disappearanceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            disappearanceTask = nil
            requestSync()
        }
    }

    private func scheduleConflictRetry(hasConflicts: Bool) {
        conflictRetryTask?.cancel()
        conflictRetryTask = nil
        guard hasConflicts else { return }
        conflictRetryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.conflictRetryInterval))
            guard let self, !Task.isCancelled else { return }
            conflictRetryTask = nil
            requestSync()
        }
    }

    private func persistStatus(_ result: CycleResult) {
        let payload: [String: Any] = [
            "updatedAt": ISO8601DateFormatter().string(from: Date()),
            "host": selectedHost,
            "state": result.state.rawValue,
            "masterPID": result.masterPID.map { $0 as Any } ?? NSNull(),
            "activeForwards": result.activeForwards.sorted(),
            "conflicts": result.conflicts.sorted(),
            "remoteCount": result.remoteCount,
            "error": result.error.map { $0 as Any } ?? NSNull(),
            "services": result.services.map { service in
                [
                    "port": service.port,
                    "name": service.name,
                    "group": service.group,
                    "kind": service.kind.rawValue,
                    "details": service.details,
                    "forwarded": service.isForwarded,
                    "conflict": service.hasConflict,
                ] as [String: Any]
            },
        ]

        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        else { return }

        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Doma", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent("status.json"), options: .atomic)
    }

    private func resetRuntime(keepState: Bool = false) {
        masterPID = nil
        activeForwards = []
        missingSince = [:]
        services = []
        activeCount = 0
        conflictCount = 0
        remoteCount = 0
        lastError = nil
        if !keepState {
            state = .disconnected
        }
    }
}
