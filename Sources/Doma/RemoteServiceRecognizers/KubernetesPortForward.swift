import Foundation

struct KubernetesPortForwardRemoteServiceRecognizer: RemoteServiceRecognizing {
    func recognize(_ context: RemoteServiceRecognitionContext) -> RecognizedRemoteService? {
        let arguments = context.process?.arguments ?? context.processText
        guard context.processText.contains("kubectl"),
              context.processText.contains("port-forward"),
              let resource = resource(in: arguments)
        else { return nil }

        let namespace = option(in: arguments, short: "-n", long: "--namespace")
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
                namespace.map { "namespace: \($0)" },
                targetPort.map { "\(context.port) → \($0)" },
                arguments
            )
        )
    }

    private func resource(in arguments: String) -> String? {
        let tokens = arguments.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let commandIndex = tokens.lastIndex(of: "port-forward") else { return nil }

        let optionsWithValues: Set<String> = [
            "--address",
            "--as",
            "--as-group",
            "--as-uid",
            "--as-user-extra",
            "--cache-dir",
            "--certificate-authority",
            "--client-certificate",
            "--client-key",
            "--cluster",
            "--context",
            "--kubeconfig",
            "--kuberc",
            "--namespace",
            "--password",
            "--pod-running-timeout",
            "--profile",
            "--profile-output",
            "--request-timeout",
            "--server",
            "--storage-driver-buffer-duration",
            "--storage-driver-db",
            "--storage-driver-host",
            "--storage-driver-password",
            "--storage-driver-table",
            "--storage-driver-user",
            "--tls-server-name",
            "--token",
            "--user",
            "--username",
            "-n",
            "-s",
        ]
        var fallback: String?
        var index = commandIndex + 1

        while index < tokens.count {
            let token = tokens[index]
            if token.hasPrefix("-") {
                let option = String(token.split(separator: "=", maxSplits: 1)[0])
                index += token.contains("=") || !optionsWithValues.contains(option) ? 1 : 2
                continue
            }
            if isPortMapping(token) {
                index += 1
                continue
            }
            if token.contains("/") {
                return token
            }
            fallback = fallback ?? token
            index += 1
        }

        return fallback
    }

    private func isPortMapping(_ token: String) -> Bool {
        capture(
            in: token,
            pattern: #"^((?:\S+:)?\d+:\d+)$"#
        ) != nil
    }

    private func option(in arguments: String, short: String?, long: String) -> String? {
        let names = [short, long].compactMap { $0 }.map(NSRegularExpression.escapedPattern)
            .joined(separator: "|")
        return capture(
            in: arguments,
            pattern: "(?:^|\\s)(?:" + names + ")(?:=|\\s+)(\\S+)"
        )
    }

    private func group(clusterContext: String?, namespace: String?) -> String {
        switch (clusterContext, namespace) {
        case let (clusterContext?, namespace?)
        where namespace != "default" && namespace != clusterContext:
            return "Kubernetes · \(clusterContext) / \(namespace)"
        case let (clusterContext?, _):
            return "Kubernetes · \(clusterContext)"
        case let (nil, namespace?):
            return "Kubernetes · \(namespace)"
        case (nil, nil):
            return "Kubernetes"
        }
    }

    private func capture(in text: String, pattern: String) -> String? {
        RemoteTextMatching.firstCapture(in: text, pattern: pattern)
    }
}
