import Foundation

enum ConnectionState: String, Sendable {
    case disconnected
    case connecting
    case connected
    case failed

    var title: String {
        switch self {
        case .disconnected: "Отключено"
        case .connecting: "Подключение…"
        case .connected: "Подключено"
        case .failed: "Ошибка"
        }
    }

    var symbol: String {
        switch self {
        case .disconnected: "network.slash"
        case .connecting: "arrow.triangle.2.circlepath"
        case .connected: "network"
        case .failed: "exclamationmark.triangle.fill"
        }
    }
}

enum ServiceKind: String, Sendable {
    case docker
    case hermes
    case kubernetes
    case minikube
    case vite
    case node
    case python
    case zrok
    case process
    case system

    var title: String {
        switch self {
        case .docker: "Docker"
        case .hermes: "Hermes"
        case .kubernetes: "Kubernetes"
        case .minikube: "Minikube"
        case .vite: "Vite"
        case .node: "Bun / Node"
        case .python: "Python"
        case .zrok: "zrok"
        case .process: "Процесс"
        case .system: "Системный сервис"
        }
    }

    var symbol: String {
        switch self {
        case .docker: "shippingbox.fill"
        case .hermes: "message.fill"
        case .kubernetes: "point.3.connected.trianglepath.dotted"
        case .minikube: "hexagon.fill"
        case .vite: "bolt.fill"
        case .node: "server.rack"
        case .python: "chevron.left.forwardslash.chevron.right"
        case .zrok: "globe"
        case .process: "terminal.fill"
        case .system: "gearshape.2.fill"
        }
    }
}

enum ServiceForwardingPreference: String, Codable, Sendable {
    case automatic
    case included
    case excluded

    func resolves(defaultEnabled: Bool) -> Bool {
        switch self {
        case .automatic:
            defaultEnabled
        case .included:
            true
        case .excluded:
            false
        }
    }
}

struct SSHHost: Identifiable, Hashable, Sendable {
    let alias: String

    var id: String { alias }
}

struct RemoteService: Identifiable, Hashable, Sendable {
    let port: Int
    let name: String
    let group: String
    let kind: ServiceKind
    let details: String
    let forwardingKey: String
    let defaultForwardingEnabled: Bool
    var forwardingPreference: ServiceForwardingPreference
    let isForwarded: Bool
    let hasConflict: Bool
    let conflictOwners: [LocalPortOwner]

    init(
        port: Int,
        name: String,
        group: String,
        kind: ServiceKind,
        details: String,
        forwardingKey: String = "",
        defaultForwardingEnabled: Bool = true,
        forwardingPreference: ServiceForwardingPreference = .automatic,
        isForwarded: Bool,
        hasConflict: Bool,
        conflictOwners: [LocalPortOwner]
    ) {
        self.port = port
        self.name = name
        self.group = group
        self.kind = kind
        self.details = details
        self.forwardingKey = forwardingKey
        self.defaultForwardingEnabled = defaultForwardingEnabled
        self.forwardingPreference = forwardingPreference
        self.isForwarded = isForwarded
        self.hasConflict = hasConflict
        self.conflictOwners = conflictOwners
    }

    var id: Int { port }

    var isForwardingEnabled: Bool {
        forwardingPreference.resolves(defaultEnabled: defaultForwardingEnabled)
    }
}

struct LocalPortOwner: Identifiable, Hashable, Sendable {
    let pid: Int32
    let name: String
    let userID: UInt32
    let terminationBlockReason: String?

    var id: Int32 { pid }
    var canTerminate: Bool { terminationBlockReason == nil }
}

struct CycleInput: Sendable {
    let host: String
    let previousMasterPID: Int?
    let activeForwards: Set<Int>
    let missingSince: [Int: Date]
    let forwardingPreferences: [String: ServiceForwardingPreference]

    init(
        host: String,
        previousMasterPID: Int?,
        activeForwards: Set<Int>,
        missingSince: [Int: Date],
        forwardingPreferences: [String: ServiceForwardingPreference] = [:]
    ) {
        self.host = host
        self.previousMasterPID = previousMasterPID
        self.activeForwards = activeForwards
        self.missingSince = missingSince
        self.forwardingPreferences = forwardingPreferences
    }
}

struct CycleResult: Sendable {
    let state: ConnectionState
    let masterPID: Int?
    let activeForwards: Set<Int>
    let conflicts: Set<Int>
    let missingSince: [Int: Date]
    let services: [RemoteService]
    let remoteCount: Int
    let error: String?
    let warning: String?
    let failedForwardingPorts: Set<Int>
    let shouldRetryAutomatically: Bool
    let hostKeyChanged: Bool
    let forwardingStateIsAuthoritative: Bool

    init(
        state: ConnectionState,
        masterPID: Int?,
        activeForwards: Set<Int>,
        conflicts: Set<Int>,
        missingSince: [Int: Date],
        services: [RemoteService],
        remoteCount: Int,
        error: String?,
        warning: String?,
        failedForwardingPorts: Set<Int> = [],
        shouldRetryAutomatically: Bool,
        hostKeyChanged: Bool,
        forwardingStateIsAuthoritative: Bool = true
    ) {
        self.state = state
        self.masterPID = masterPID
        self.activeForwards = activeForwards
        self.conflicts = conflicts
        self.missingSince = missingSince
        self.services = services
        self.remoteCount = remoteCount
        self.error = error
        self.warning = warning
        self.failedForwardingPorts = failedForwardingPorts
        self.shouldRetryAutomatically = shouldRetryAutomatically
        self.hostKeyChanged = hostKeyChanged
        self.forwardingStateIsAuthoritative = forwardingStateIsAuthoritative
    }
}

struct SSHMasterPreparation: Sendable {
    let pid: Int?
    let error: String?
    let shouldRetryAutomatically: Bool
    let hostKeyChanged: Bool
}

struct SSHConnectionErrorDetails: Sendable {
    let message: String
    let shouldRetryAutomatically: Bool
    let hostKeyChanged: Bool
}

struct RemoteAccessErrorDetails: Sendable {
    let message: String
    let shouldRetryAutomatically: Bool
}

struct RemoteMonitorTermination: Sendable {
    let message: String?
    let shouldRetryAutomatically: Bool
}

struct CommandResult: Sendable {
    let status: Int32
    let stdout: String
    let stderr: String
}
