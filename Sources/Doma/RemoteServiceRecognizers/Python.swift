struct PythonRemoteServiceRecognizer: RemoteServiceRecognizing {
    func recognize(_ context: RemoteServiceRecognitionContext) -> RecognizedRemoteService? {
        guard context.executable.contains("python") else { return nil }
        return RecognizedRemoteService(
            kind: .python,
            name: context.processText.contains("http.server") ? "Python HTTP Server" : "Python",
            group: context.cwd ?? "Python",
            details: context.standardDetails
        )
    }
}
