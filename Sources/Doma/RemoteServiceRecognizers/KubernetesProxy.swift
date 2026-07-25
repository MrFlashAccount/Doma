import Foundation

struct KubernetesProxyRemoteServiceRecognizer: RemoteServiceRecognizing {
    func recognize(_ context: RemoteServiceRecognitionContext) -> RecognizedRemoteService? {
        guard context.processText.contains("kubectl"),
              RemoteTextMatching.firstCapture(
                in: context.processText,
                pattern: #"((?:^|\s)proxy(?:\s|$))"#
              ) != nil
        else {
            return nil
        }

        let arguments = context.process?.arguments ?? context.processText
        let clusterContext = option(in: arguments, long: "--context")

        return RecognizedRemoteService(
            kind: .kubernetes,
            name: "Kubernetes API Proxy",
            group: clusterContext.map { "Kubernetes · \($0)" } ?? "Kubernetes",
            details: RemoteServiceDetails.joined(
                "local API proxy",
                arguments
            )
        )
    }

    private func option(in arguments: String, long: String) -> String? {
        RemoteTextMatching.firstCapture(
            in: arguments,
            pattern: "(?:^|\\s)" + NSRegularExpression.escapedPattern(for: long)
                + "(?:=|\\s+)(\\S+)"
        )
    }
}
