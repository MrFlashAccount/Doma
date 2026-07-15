import AppKit
import Foundation

@MainActor
final class TunnelManager: ObservableObject {
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
    private var loopTask: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?
    private var shutdownCompletions: [@MainActor () -> Void] = []
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
        startLoop()
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
        loopTask?.cancel()
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
        selectedHost = alias
        UserDefaults.standard.set(alias, forKey: "selectedHost")
        resetRuntime()

        Task.detached {
            if !previous.isEmpty {
                TunnelEngine.stopMaster(host: previous)
            }
        }
        syncNow()
    }

    func reconnect() {
        guard !selectedHost.isEmpty else { return }
        let host = selectedHost
        state = .connecting
        resetRuntime(keepState: true)
        Task {
            await Task.detached { TunnelEngine.stopMaster(host: host) }.value
            await synchronize()
        }
    }

    func syncNow() {
        Task { await synchronize() }
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
        loopTask?.cancel()
        loopTask = nil
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
            await synchronize()
        }
    }

    func clearConflictResolutionError() {
        conflictResolutionError = nil
    }

    private func startLoop() {
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.synchronize()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func synchronize() async {
        guard !isSyncing, !selectedHost.isEmpty, !isShuttingDown else { return }
        isSyncing = true
        if masterPID == nil {
            state = .connecting
        }

        let input = CycleInput(
            host: selectedHost,
            previousMasterPID: masterPID,
            activeForwards: activeForwards,
            missingSince: missingSince
        )
        let result = await Task.detached { TunnelEngine.cycle(input) }.value

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
        isSyncing = false
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
