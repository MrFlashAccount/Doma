struct SystemRemoteServiceRecognizer: RemoteServiceRecognizing {
    func recognize(_ context: RemoteServiceRecognitionContext) -> RecognizedRemoteService? {
        guard context.isSystemOwned else { return nil }
        return RecognizedRemoteService(
            kind: .system,
            name: serviceName(context),
            group: "Системные сервисы",
            details: context.standardDetails
        )
    }

    private func serviceName(_ context: RemoteServiceRecognitionContext) -> String {
        if let command = context.process?.command ?? context.listener?.command { return command }
        if let userID = context.listener?.userID {
            return userID == 0 ? "root service" : "UID \(userID) service"
        }
        return "System TCP"
    }
}
