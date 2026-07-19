struct HermesRemoteServiceRecognizer: RemoteServiceRecognizing {
    func recognize(_ context: RemoteServiceRecognitionContext) -> RecognizedRemoteService? {
        guard matches(context) else { return nil }

        let name: String
        if context.processText.contains("hermes dashboard") {
            name = "Hermes Dashboard"
        } else if context.processText.contains("hermes gateway") {
            name = "Hermes Gateway"
        } else {
            name = "Hermes"
        }

        return RecognizedRemoteService(
            kind: .hermes,
            name: name,
            group: "Hermes",
            details: context.standardDetails
        )
    }

    private func matches(_ context: RemoteServiceRecognitionContext) -> Bool {
        context.executable == "hermes"
            || context.processText.contains("/opt/hermes/")
            || context.processText.contains(" hermes dashboard")
            || context.processText.contains(" hermes gateway")
    }
}
