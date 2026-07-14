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
    case vite
    case node
    case python
    case system

    var title: String {
        switch self {
        case .docker: "Docker"
        case .vite: "Vite"
        case .node: "Node"
        case .python: "Python"
        case .system: "TCP"
        }
    }

    var symbol: String {
        switch self {
        case .docker: "shippingbox.fill"
        case .vite: "bolt.fill"
        case .node: "server.rack"
        case .python: "chevron.left.forwardslash.chevron.right"
        case .system: "point.3.connected.trianglepath.dotted"
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

    var id: Int { port }
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
}

struct CommandResult: Sendable {
    let status: Int32
    let stdout: String
    let stderr: String
}
