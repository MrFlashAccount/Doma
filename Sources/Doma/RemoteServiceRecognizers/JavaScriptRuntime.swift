import Foundation

struct JavaScriptRuntimeRemoteServiceRecognizer: RemoteServiceRecognizing {
    private let runtimes = ["node", "bun", "pnpm", "npm", "yarn"]

    func recognize(_ context: RemoteServiceRecognitionContext) -> RecognizedRemoteService? {
        guard runtimes.contains(where: {
            containsRuntime($0, in: context.executable)
                || containsRuntime($0, in: context.processText)
        }) else { return nil }
        return RecognizedRemoteService(
            kind: .node,
            name: runtimeName(context),
            group: context.cwd ?? "Bun / Node",
            details: context.standardDetails
        )
    }

    private func runtimeName(_ context: RemoteServiceRecognitionContext) -> String {
        if matches("bun", context) { return "Bun" }
        if matches("pnpm", context) { return "pnpm" }
        if matches("yarn", context) { return "Yarn" }
        if matches("npm", context) { return "npm" }
        return "Node"
    }

    private func matches(_ runtime: String, _ context: RemoteServiceRecognitionContext) -> Bool {
        containsRuntime(runtime, in: context.executable)
            || containsRuntime(runtime, in: context.processText)
    }

    private func containsRuntime(_ runtime: String, in text: String) -> Bool {
        RemoteTextMatching.firstCapture(
            in: text,
            pattern: "((?:^|[^a-z0-9])" + NSRegularExpression.escapedPattern(for: runtime)
                + "(?:[^a-z0-9]|$))"
        ) != nil
    }
}
