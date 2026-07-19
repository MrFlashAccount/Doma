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
    let isForwarded: Bool
    let hasConflict: Bool
    let conflictOwners: [LocalPortOwner]

    var id: Int { port }
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
