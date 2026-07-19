struct DockerRemoteServiceRecognizer: RemoteServiceRecognizing {
    func recognize(_ context: RemoteServiceRecognitionContext) -> RecognizedRemoteService? {
        guard let docker = context.docker else { return nil }
        return RecognizedRemoteService(
            kind: .docker,
            name: docker.service.isEmpty ? docker.container : docker.service,
            group: docker.project.isEmpty ? "Docker" : docker.project,
            details: RemoteServiceDetails.joined(docker.container, docker.image)
        )
    }
}
