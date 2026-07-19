struct GenericProcessRemoteServiceRecognizer: RemoteServiceRecognizing {
    func recognize(_ context: RemoteServiceRecognitionContext) -> RecognizedRemoteService? {
        RecognizedRemoteService(
            kind: .process,
            name: context.process?.command ?? context.listener?.command ?? "TCP process",
            group: context.cwd ?? "Пользовательские процессы",
            details: context.standardDetails
        )
    }
}
