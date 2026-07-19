import Foundation

struct ZrokRemoteServiceRecognizer: RemoteServiceRecognizing {
    private struct Share {
        let name: String?
        let arguments: String
    }

    private let inventory: RemoteInventory
    private let sharesByPort: [Int: Share]

    init(inventory: RemoteInventory) {
        self.inventory = inventory
        sharesByPort = Self.findShares(in: inventory.processes.values)
    }

    func recognize(_ context: RemoteServiceRecognitionContext) -> RecognizedRemoteService? {
        if let share = sharesByPort[context.port] {
            return RecognizedRemoteService(
                kind: .zrok,
                name: share.name.map { "zrok Share · \($0)" } ?? "zrok Share",
                group: "zrok Shares",
                details: RemoteServiceDetails.joined(
                    share.arguments,
                    context.process?.arguments,
                    context.cwd
                )
            )
        }

        guard !context.isSystemOwned else { return nil }
        let process = context.process ?? defaultAgentProcess(for: context)
        let text = [process?.command, process?.arguments, context.processText]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        guard text.contains("zrok") else { return nil }

        let name: String
        if text.contains("agent start") {
            name = "zrok Admin Panel"
        } else if text.contains("access private") {
            name = "zrok Private Access"
        } else {
            name = "zrok"
        }
        return RecognizedRemoteService(
            kind: .zrok,
            name: name,
            group: "zrok",
            details: RemoteServiceDetails.joined(
                process?.arguments,
                process.map { "user: \($0.user) (UID \($0.userID))" },
                context.cwd
            )
        )
    }

    private func defaultAgentProcess(for context: RemoteServiceRecognitionContext) -> RemoteProcessRecord? {
        guard context.port == 8888 else { return nil }
        let candidates = inventory.processes.filter { _, process in
            guard context.listener?.userID == nil || process.userID == context.listener?.userID else {
                return false
            }
            let arguments = process.arguments.lowercased()
            return arguments.contains("zrok") && arguments.contains("agent start")
        }
        return RemoteProcessResolver.preferredLeafProcess(in: candidates)
            .flatMap { inventory.processes[$0] }
    }

    private static func findShares(
        in processes: Dictionary<Int, RemoteProcessRecord>.Values
    ) -> [Int: Share] {
        var shares: [Int: Share] = [:]
        for process in processes {
            let arguments = process.arguments
            guard arguments.lowercased().contains("zrok share public"),
                  let port = RemoteTextMatching.firstCapture(
                    in: arguments,
                    pattern: #"https?://(?:127\.0\.0\.1|localhost|\[::1\]):(\d+)"#
                  ).flatMap(Int.init)
            else { continue }
            let name = RemoteTextMatching.firstCapture(
                in: arguments,
                pattern: #"--name-selection\s+[^\s:]+:([a-zA-Z0-9.-]+)"#
            )
            if shares[port]?.name == nil || name != nil {
                shares[port] = Share(name: name, arguments: arguments)
            }
        }
        return shares
    }
}
