struct ViteRemoteServiceRecognizer: RemoteServiceRecognizing {
    func recognize(_ context: RemoteServiceRecognitionContext) -> RecognizedRemoteService? {
        guard context.processText.contains("vite") else { return nil }
        return RecognizedRemoteService(
            kind: .vite,
            name: "Vite",
            group: context.cwd ?? "Vite",
            details: context.standardDetails
        )
    }
}
