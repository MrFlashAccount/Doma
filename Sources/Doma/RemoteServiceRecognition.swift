import Foundation

struct RecognizedRemoteService {
    let kind: ServiceKind
    let name: String
    let group: String
    let details: String
}

protocol RemoteServiceRecognizing {
    func additionalPorts(in inventory: RemoteInventory) -> Set<Int>
    func recognize(_ context: RemoteServiceRecognitionContext) -> RecognizedRemoteService?
}

extension RemoteServiceRecognizing {
    func additionalPorts(in _: RemoteInventory) -> Set<Int> { [] }
}

struct RemoteServiceRecognitionContext {
    let port: Int
    let inventory: RemoteInventory
    let listener: RemoteListenerRecord?
    let process: RemoteProcessRecord?
    let processChain: [RemoteProcessRecord]
    let cwd: String?

    var docker: RemoteDockerRecord? { inventory.dockerByPort[port] }

    var processText: String {
        processChain
            .map { "\($0.command) \($0.arguments)" }
            .joined(separator: " ")
            .lowercased()
    }

    var executable: String {
        (process?.command ?? listener?.command ?? "TCP").lowercased()
    }

    var isSystemOwned: Bool {
        guard let currentUserID = inventory.currentUserID else { return false }
        if let process { return process.userID != currentUserID }
        if let userID = listener?.userID { return userID != currentUserID }
        return true
    }

    var standardDetails: String {
        RemoteServiceDetails.joined(
            process?.arguments,
            process.map { "user: \($0.user) (UID \($0.userID))" },
            cwd
        )
    }
}

struct RemoteServiceRecognitionPipeline {
    private let inventory: RemoteInventory
    private let listenersByPort: [Int: [RemoteListenerRecord]]
    private let recognizers: [any RemoteServiceRecognizing]

    init(inventory: RemoteInventory) {
        self.inventory = inventory
        listenersByPort = Dictionary(grouping: inventory.listeners, by: \.port)
        recognizers = [
            ZrokRemoteServiceRecognizer(inventory: inventory),
            MinikubeRemoteServiceRecognizer(),
            DockerRemoteServiceRecognizer(),
            SystemRemoteServiceRecognizer(),
            ViteRemoteServiceRecognizer(),
            JavaScriptRuntimeRemoteServiceRecognizer(),
            PythonRemoteServiceRecognizer(),
            GenericProcessRemoteServiceRecognizer(),
        ]
    }

    var eligiblePorts: Set<Int> {
        let standardPorts = inventory.listeners.lazy.map(\.port).filter { 1024...32767 ~= $0 }
        return recognizers.reduce(into: Set(standardPorts)) { ports, recognizer in
            ports.formUnion(recognizer.additionalPorts(in: inventory))
        }
    }

    func recognize(port: Int) -> RecognizedRemoteService {
        let context = makeContext(port: port)
        for recognizer in recognizers {
            if let service = recognizer.recognize(context) {
                return service
            }
        }
        preconditionFailure("GenericProcessRemoteServiceRecognizer must terminate the pipeline")
    }

    private func makeContext(port: Int) -> RemoteServiceRecognitionContext {
        let listener = RemoteProcessResolver.bestListener(in: listenersByPort[port] ?? [])
        let inferredPID = listener.flatMap {
            RemoteProcessResolver.inferProcessID(for: port, listener: $0, inventory: inventory)
        }
        let processPID = listener?.pid ?? inferredPID
        let process = processPID.flatMap { inventory.processes[$0] }
        return RemoteServiceRecognitionContext(
            port: port,
            inventory: inventory,
            listener: listener,
            process: process,
            processChain: RemoteProcessResolver.processChain(
                startingAt: processPID,
                inventory: inventory
            ),
            cwd: processPID.flatMap { inventory.cwdByPID[$0] }
        )
    }
}

enum RemoteProcessResolver {
    static func bestListener(in listeners: [RemoteListenerRecord]) -> RemoteListenerRecord? {
        listeners.max { lhs, rhs in
            metadataScore(lhs) < metadataScore(rhs)
        }
    }

    static func inferProcessID(
        for port: Int,
        listener: RemoteListenerRecord,
        inventory: RemoteInventory
    ) -> Int? {
        let candidates = inventory.processes.filter { _, process in
            guard listener.userID == nil || process.userID == listener.userID else { return false }
            let pattern = #"(?:^|[^0-9])"# + String(port) + #"(?:[^0-9]|$)"#
            return RemoteTextMatching.firstCapture(
                in: process.arguments,
                pattern: "(" + pattern + ")"
            ) != nil
        }
        return preferredLeafProcess(in: candidates)
    }

    static func preferredLeafProcess(in candidates: [Int: RemoteProcessRecord]) -> Int? {
        guard !candidates.isEmpty else { return nil }
        let leaves = candidates.filter { pid, _ in
            !candidates.contains { _, possibleChild in possibleChild.parentPID == pid }
        }
        if leaves.count == 1 { return leaves.first?.key }

        let wrappers = Set(["bash", "fish", "sh", "timeout", "tmux"])
        let executableLeaves = leaves.filter { _, process in
            !wrappers.contains(process.command.lowercased())
        }
        return executableLeaves.count == 1 ? executableLeaves.first?.key : nil
    }

    static func processChain(startingAt pid: Int?, inventory: RemoteInventory) -> [RemoteProcessRecord] {
        var result: [RemoteProcessRecord] = []
        var currentPID = pid
        var visited = Set<Int>()
        while let pid = currentPID, visited.insert(pid).inserted, result.count < 6,
              let process = inventory.processes[pid]
        {
            result.append(process)
            currentPID = process.parentPID == pid ? nil : process.parentPID
        }
        return result
    }

    private static func metadataScore(_ listener: RemoteListenerRecord) -> Int {
        (listener.pid == nil ? 0 : 4)
            + (listener.command == nil ? 0 : 2)
            + (listener.userID == nil ? 0 : 1)
    }
}

enum RemoteServiceDetails {
    static func joined(_ values: String?...) -> String {
        values.compactMap { value in
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }.joined(separator: " · ")
    }
}
