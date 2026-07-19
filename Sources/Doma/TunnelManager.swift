import AppKit
import Foundation

@MainActor
final class TunnelManager: ObservableObject {
    private static let fullResyncInterval: TimeInterval = 300
    private static let conflictRetryInterval: TimeInterval = 15
    private static let maxReconnectAttempts = 5

    @Published private(set) var hosts: [SSHHost] = []
    @Published private(set) var selectedHost = ""
    @Published private(set) var state: ConnectionState = .disconnected
    @Published private(set) var services: [RemoteService] = []
    @Published private(set) var activeCount = 0
    @Published private(set) var conflictCount = 0
    @Published private(set) var remoteCount = 0
    @Published private(set) var lastError: String?
    @Published private(set) var lastWarning: String?
    @Published private(set) var hostKeyChanged = false
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
    private var recoveryTask: Task<Void, Never>?
    private var hostCleanupTask: Task<Void, Never>?
    private var hostCleanupGeneration: UUID?
    private var connectionGeneration: UUID?
    private var syncTask: Task<Void, Never>?
    private var syncGeneration: UUID?
    private var resyncTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var disappearanceTask: Task<Void, Never>?
    private var conflictRetryTask: Task<Void, Never>?
    private var degradedRetryTask: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?
    private var shutdownCompletions: [@MainActor () -> Void] = []
    private var syncPending = false
    private var reconnectAttempt = 0
    private var reconnectBudgetHost: String?
    private var isShuttingDown = false

    init(
        preview: Bool = false,
        previewConnectionError: Bool = false,
        previewHostKeyChanged: Bool = false,
        previewRemotePermissionError: Bool = false
    ) {
        #if DEBUG
        if preview {
            loadPreviewState()
            if previewRemotePermissionError {
                state = .failed
                services = []
                activeCount = 0
                conflictCount = 0
                remoteCount = 0
                lastError = "Недостаточно прав на SSH-сервере studio: Doma не может прочитать listening sockets. Проверь права удалённого пользователя на /proc/net/tcp и запуск ss."
            } else if previewHostKeyChanged {
                state = .failed
                services = []
                activeCount = 0
                conflictCount = 0
                remoteCount = 0
                hostKeyChanged = true
                lastError = "Ключ SSH-сервера studio изменился. Это может быть ожидаемой заменой или признаком атаки. Автоматическое подключение остановлено. Сверь новый fingerprint с администратором перед продолжением."
            } else if previewConnectionError {
                state = .failed
                services = []
                activeCount = 0
                conflictCount = 0
                remoteCount = 0
                lastError = "Не удалось найти SSH-сервер studio. Проверь SSH alias и сеть."
            }
            return
        }
        #endif

        reloadHosts()
        let saved = UserDefaults.standard.string(forKey: "selectedHost")
        selectedHost = hosts.contains(where: { $0.alias == saved })
            ? saved!
            : (hosts.first(where: { $0.alias == "buddy" })?.alias ?? hosts.first?.alias ?? "")
        DomaStatusStore.standard.clear()
        if let recoveryError = SSHKnownHostsManager.recoverInterruptedTransactions() {
            state = .failed
            lastError = recoveryError
            return
        }
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
        recoveryTask?.cancel()
        syncTask?.cancel()
        syncGeneration = nil
        resyncTask?.cancel()
        reconnectTask?.cancel()
        disappearanceTask?.cancel()
        conflictRetryTask?.cancel()
        degradedRetryTask?.cancel()
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
        guard alias != selectedHost, recoveryTask == nil else { return }
        let previous = selectedHost
        stopMonitoring()
        selectedHost = alias
        UserDefaults.standard.set(alias, forKey: "selectedHost")
        resetReconnectBudget(for: alias)
        resetRuntime()

        let generation = UUID()
        connectionGeneration = generation
        let cleanup = queueHostCleanup(previous)
        connectionTask = Task { [weak self] in
            await cleanup?.value
            guard let self, connectionGeneration == generation else { return }
            connectionTask = nil
            connectionGeneration = nil
            guard !Task.isCancelled, selectedHost == alias, !isShuttingDown else { return }
            beginMonitoring()
        }
    }

    func reconnect() {
        guard !selectedHost.isEmpty, recoveryTask == nil else { return }
        let host = selectedHost
        resetReconnectBudget(for: host)
        stopMonitoring()
        state = .connecting
        resetRuntime(keepState: true)
        let generation = UUID()
        connectionGeneration = generation
        let cleanup = queueHostCleanup(host)
        connectionTask = Task { [weak self] in
            await cleanup?.value
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

        let activeRecovery = recoveryTask
        let activeSync = syncTask
        let activeCleanup = hostCleanupTask
        isShuttingDown = true
        stopMonitoring()
        state = .disconnected

        shutdownTask = Task { [weak self] in
            guard let self else { return }
            await activeRecovery?.value
            await activeSync?.value
            await activeCleanup?.value

            let host = selectedHost
            let forwards = activeForwards
            if !host.isEmpty {
                await TunnelEngine.shutdown(host: host, activeForwards: forwards)
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

    func removeStaleHostKeyAndReconnect() {
        guard hostKeyChanged,
              !selectedHost.isEmpty,
              !isShuttingDown,
              recoveryTask == nil
        else { return }

        let host = selectedHost
        stopMonitoring()
        state = .connecting
        lastError = nil
        hostKeyChanged = false
        recoveryTask = Task { [weak self] in
            let error = await SSHKnownHostsManager.removeStaleKeyAndRequireConfirmationAsync(host: host)

            guard let self else { return }
            recoveryTask = nil
            guard selectedHost == host, !isShuttingDown else { return }

            if let error {
                state = .failed
                lastError = error
                return
            }
            reconnect()
        }
    }

    private func beginMonitoring() {
        guard !selectedHost.isEmpty,
              !isShuttingDown,
              monitor == nil,
              connectionTask == nil,
              recoveryTask == nil
        else { return }

        let host = selectedHost
        let generation = UUID()
        state = .connecting
        reconnectTask?.cancel()
        reconnectTask = nil
        connectionGeneration = generation

        connectionTask = Task { [weak self] in
            let preparation = await TunnelEngine.prepareMaster(host: host)

            guard let self else { return }
            guard connectionGeneration == generation else { return }
            connectionTask = nil
            connectionGeneration = nil
            guard !Task.isCancelled, selectedHost == host, !isShuttingDown else {
                return
            }
            guard let masterPID = preparation.pid else {
                state = .failed
                lastError = preparation.error ?? "Не удалось установить SSH-соединение"
                hostKeyChanged = preparation.hostKeyChanged
                DomaStatusStore.standard.clear()
                if preparation.shouldRetryAutomatically {
                    scheduleReconnect(for: host)
                }
                return
            }

            self.masterPID = masterPID
            hostKeyChanged = false
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
                    onTermination: { [weak self] termination in
                        Task { @MainActor in
                            self?.handleMonitorTermination(for: host, termination: termination)
                        }
                    }
                )
                self.monitor = monitor
                monitorHost = host
                startResyncLoop(for: host)
            } catch {
                state = .failed
                lastError = error.localizedDescription
                hostKeyChanged = false
                DomaStatusStore.standard.clear()
                scheduleReconnect(for: host)
            }
        }
    }

    private func handleInventoryChange(for host: String) {
        guard monitorHost == host, selectedHost == host, !isShuttingDown else { return }
        requestSync()
    }

    private func handleMonitorTermination(for host: String, termination: RemoteMonitorTermination) {
        guard monitorHost == host, selectedHost == host, !isShuttingDown else { return }
        monitor = nil
        monitorHost = nil
        resyncTask?.cancel()
        resyncTask = nil
        disappearanceTask?.cancel()
        disappearanceTask = nil
        conflictRetryTask?.cancel()
        conflictRetryTask = nil
        degradedRetryTask?.cancel()
        degradedRetryTask = nil
        syncTask?.cancel()
        syncTask = nil
        syncGeneration = nil
        syncPending = false
        state = .failed
        lastError = termination.message ?? "Соединение с удалённым монитором закрыто"
        lastWarning = nil
        hostKeyChanged = false
        DomaStatusStore.standard.clear()
        if termination.shouldRetryAutomatically {
            scheduleReconnect(for: host)
        }
    }

    private func stopMonitoring() {
        DomaStatusStore.standard.clear()
        monitor?.stop()
        monitor = nil
        monitorHost = nil
        connectionTask?.cancel()
        connectionTask = nil
        connectionGeneration = nil
        syncTask?.cancel()
        syncTask = nil
        syncGeneration = nil
        resyncTask?.cancel()
        resyncTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        disappearanceTask?.cancel()
        disappearanceTask = nil
        conflictRetryTask?.cancel()
        conflictRetryTask = nil
        degradedRetryTask?.cancel()
        degradedRetryTask = nil
        syncPending = false
    }

    private func scheduleReconnect(for host: String) {
        guard selectedHost == host, !isShuttingDown, reconnectTask == nil else { return }
        if reconnectBudgetHost != host {
            reconnectBudgetHost = host
            reconnectAttempt = 0
        }
        guard reconnectAttempt < Self.maxReconnectAttempts else {
            if let lastError, !lastError.contains("Повтори подключение вручную") {
                self.lastError = lastError + "\n\nАвтоматические попытки остановлены. Проверь сеть и повтори подключение вручную."
            }
            return
        }
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
        let generation = UUID()
        syncGeneration = generation
        syncTask = Task { [weak self] in
            await self?.drainSyncRequests(generation: generation)
        }
    }

    private func drainSyncRequests(generation: UUID) async {
        guard !isSyncing else {
            if syncGeneration == generation {
                syncTask = nil
                syncGeneration = nil
            }
            return
        }
        isSyncing = true
        defer {
            isSyncing = false
            if syncGeneration == generation {
                syncTask = nil
                syncGeneration = nil
            }
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
            let result = await TunnelEngine.cycle(input)
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
        if !result.forwardingStateIsAuthoritative {
            activeCount = 0
        }
        conflictCount = result.conflicts.count
        remoteCount = result.remoteCount
        lastError = result.error
        lastWarning = result.warning
        hostKeyChanged = result.hostKeyChanged
        lastSync = Date()
        if result.state == .connected {
            try? DomaStatusStore.standard.write(result)
        } else {
            DomaStatusStore.standard.clear()
        }
        scheduleDisappearanceSync()
        scheduleConflictRetry(hasConflicts: !result.conflicts.isEmpty)
        scheduleDegradedRetry(isDegraded: !result.forwardingStateIsAuthoritative)

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
            degradedRetryTask?.cancel()
            degradedRetryTask = nil
            if result.shouldRetryAutomatically {
                scheduleReconnect(for: host)
            }
        } else {
            reconnectAttempt = 0
            reconnectBudgetHost = host
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

    private func scheduleDegradedRetry(isDegraded: Bool) {
        degradedRetryTask?.cancel()
        degradedRetryTask = nil
        guard isDegraded else { return }
        degradedRetryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            degradedRetryTask = nil
            requestSync()
        }
    }

    private func resetReconnectBudget(for host: String) {
        reconnectBudgetHost = host
        reconnectAttempt = 0
    }

    private func queueHostCleanup(_ host: String) -> Task<Void, Never>? {
        guard !host.isEmpty else { return hostCleanupTask }
        let predecessor = hostCleanupTask
        let generation = UUID()
        hostCleanupGeneration = generation
        let task = Task { [weak self] in
            await predecessor?.value
            await TunnelEngine.stopMaster(host: host)
            guard let self, hostCleanupGeneration == generation else { return }
            hostCleanupTask = nil
            hostCleanupGeneration = nil
        }
        hostCleanupTask = task
        return task
    }

    private func resetRuntime(keepState: Bool = false) {
        DomaStatusStore.standard.clear()
        masterPID = nil
        activeForwards = []
        missingSince = [:]
        services = []
        activeCount = 0
        conflictCount = 0
        remoteCount = 0
        lastError = nil
        lastWarning = nil
        hostKeyChanged = false
        if !keepState {
            state = .disconnected
        }
    }
}

struct DomaStatusStore: Sendable {
    let directory: URL

    static var standard: DomaStatusStore {
        DomaStatusStore(
            directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Doma", isDirectory: true)
        )
    }

    var statusURL: URL {
        directory.appendingPathComponent("status.json", isDirectory: false)
    }

    func write(_ result: CycleResult) throws {
        let payload: [String: Any] = [
            "schemaVersion": 2,
            "updatedAt": ISO8601DateFormatter().string(from: Date()),
            "state": result.state.rawValue,
            "activeCount": result.forwardingStateIsAuthoritative ? result.activeForwards.count : 0,
            "conflictCount": result.conflicts.count,
            "remoteCount": result.remoteCount,
            "degraded": !result.forwardingStateIsAuthoritative || result.warning != nil,
        ]
        let data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        try data.write(to: statusURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: statusURL.path
        )
    }

    func clear() {
        try? FileManager.default.removeItem(at: statusURL)
    }
}
