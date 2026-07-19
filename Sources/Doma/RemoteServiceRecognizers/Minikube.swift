struct MinikubeRemoteServiceRecognizer: RemoteServiceRecognizing {
    func additionalPorts(in inventory: RemoteInventory) -> Set<Int> {
        Set(inventory.dockerByPort.compactMap { port, docker in
            matches(docker) && 1024...65535 ~= port ? port : nil
        })
    }

    func recognize(_ context: RemoteServiceRecognitionContext) -> RecognizedRemoteService? {
        guard let docker = context.docker, matches(docker) else { return nil }
        return RecognizedRemoteService(
            kind: .minikube,
            name: serviceName(containerPort: docker.containerPort),
            group: "Minikube · \(docker.container)",
            details: RemoteServiceDetails.joined(
                "\(docker.container):\(docker.containerPort.map(String.init) ?? "?")",
                docker.image
            )
        )
    }

    private func matches(_ docker: RemoteDockerRecord) -> Bool {
        let image = docker.image.lowercased()
        return image.contains("k8s-minikube/kicbase") || image.contains("minikube")
    }

    private func serviceName(containerPort: Int?) -> String {
        switch containerPort {
        case 22: "Minikube SSH"
        case 2376: "Minikube Docker"
        case 5000: "Minikube Registry"
        case 8443: "Minikube Kubernetes API"
        case 32443: "Minikube HTTPS"
        case let port?: "Minikube :\(port)"
        case nil: "Minikube"
        }
    }
}
