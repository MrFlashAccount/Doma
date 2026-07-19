import Foundation

struct KubernetesPortForwardRemoteServiceRecognizer: RemoteServiceRecognizing {
    func recognize(_ context: RemoteServiceRecognitionContext) -> RecognizedRemoteService? {
        guard context.processText.contains("kubectl"),
              context.processText.contains("port-forward"),
              let resource = capture(
                in: context.process?.arguments ?? context.processText,
                pattern: #"(?:^|\s)port-forward\s+(\S+)"#
              )
        else { return nil }

        let arguments = context.process?.arguments ?? context.processText
        let namespace = option(in: arguments, short: "-n", long: "--namespace") ?? "default"
        let clusterContext = option(in: arguments, short: nil, long: "--context")
        let targetPort = capture(
            in: arguments,
            pattern: #"(?:^|\s)(?:127\.0\.0\.1:)?"# + String(context.port) + #":(\d+)(?:\s|$)"#
        )
        let components = resource.split(separator: "/", maxSplits: 1).map(String.init)
        let resourceKind = components.count == 2 ? components[0] : "resource"
        let resourceName = components.count == 2 ? components[1] : resource

        return RecognizedRemoteService(
            kind: .kubernetes,
            name: resourceName,
            group: group(clusterContext: clusterContext, namespace: namespace),
            details: RemoteServiceDetails.joined(
                resourceKind,
                "namespace: \(namespace)",
                targetPort.map { "\(context.port) → \($0)" },
                arguments
            )
        )
    }

    private func option(in arguments: String, short: String?, long: String) -> String? {
        let names = [short, long].compactMap { $0 }.map(NSRegularExpression.escapedPattern)
            .joined(separator: "|")
        return capture(
            in: arguments,
            pattern: "(?:^|\\s)(?:" + names + ")(?:=|\\s+)(\\S+)"
        )
    }

    private func group(clusterContext: String?, namespace: String) -> String {
        guard let clusterContext else { return "Kubernetes · \(namespace)" }
        if namespace == "default" || namespace == clusterContext {
            return "Kubernetes · \(clusterContext)"
        }
        return "Kubernetes · \(clusterContext) / \(namespace)"
    }

    private func capture(in text: String, pattern: String) -> String? {
        RemoteTextMatching.firstCapture(in: text, pattern: pattern)
    }
}
