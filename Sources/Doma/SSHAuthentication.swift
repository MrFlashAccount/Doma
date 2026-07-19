import Foundation

struct SSHAuthenticationConfiguration: Sendable {
    let batchMode: String
    let environment: [String: String]?
}

enum SSHAuthentication {
    static func configuration(
        bundle: Bundle = .main,
        environment baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> SSHAuthenticationConfiguration {
        configuration(
            askPassPath: askPassPath(bundle: bundle),
            environment: baseEnvironment
        )
    }

    static func configuration(
        askPassPath: String?,
        environment baseEnvironment: [String: String]
    ) -> SSHAuthenticationConfiguration {
        guard let helper = askPassPath else {
            return SSHAuthenticationConfiguration(batchMode: "yes", environment: nil)
        }

        var environment = baseEnvironment
        environment["SSH_ASKPASS"] = helper
        environment["SSH_ASKPASS_REQUIRE"] = "force"
        environment["DISPLAY"] = environment["DISPLAY"] ?? "Doma"
        return SSHAuthenticationConfiguration(batchMode: "no", environment: environment)
    }

    static func askPassPath(bundle: Bundle = .main) -> String? {
        let manager = FileManager.default
        let bundled = bundle.bundleURL
            .appendingPathComponent("Contents/Helpers/DomaAskPass", isDirectory: false)
            .path
        if manager.isExecutableFile(atPath: bundled) {
            return bundled
        }

        guard let executable = bundle.executableURL else { return nil }
        let sibling = executable.deletingLastPathComponent()
            .appendingPathComponent("DomaAskPass", isDirectory: false)
            .path
        return manager.isExecutableFile(atPath: sibling) ? sibling : nil
    }
}

enum SSHConnectionErrorFormatter {
    static func details(host: String, result: CommandResult) -> SSHConnectionErrorDetails {
        let diagnostic = [result.stdout, result.stderr]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let raw = lastMeaningfulLine(diagnostic)
        let lowercased = diagnostic.lowercased()

        if lowercased.contains("remote host identification has changed") {
            return SSHConnectionErrorDetails(
                message: "Ключ SSH-сервера \(host) изменился. Это может быть ожидаемой заменой или признаком атаки. Автоматическое подключение остановлено. Сверь новый fingerprint с администратором перед продолжением.",
                shouldRetryAutomatically: false,
                hostKeyChanged: true
            )
        }

        if lowercased.contains("permission denied")
            || lowercased.contains("too many authentication failures")
        {
            return SSHConnectionErrorDetails(
                message: "Сервер отклонил учётные данные для \(host). Проверь логин, пароль или SSH-ключ.",
                shouldRetryAutomatically: false,
                hostKeyChanged: false
            )
        }
        if lowercased.contains("host key verification failed") {
            return SSHConnectionErrorDetails(
                message: "Ключ SSH-сервера \(host) не был подтверждён. Проверь fingerprint перед повторной попыткой.",
                shouldRetryAutomatically: false,
                hostKeyChanged: false
            )
        }
        if lowercased.contains("could not resolve hostname")
            || lowercased.contains("name or service not known")
        {
            return SSHConnectionErrorDetails(
                message: "Не удалось найти SSH-сервер \(host). Проверь SSH alias и сеть.",
                shouldRetryAutomatically: true,
                hostKeyChanged: false
            )
        }
        if lowercased.contains("connection refused") {
            return SSHConnectionErrorDetails(
                message: "SSH-сервер \(host) отклонил соединение. Проверь адрес, порт и запущен ли sshd.",
                shouldRetryAutomatically: true,
                hostKeyChanged: false
            )
        }
        if lowercased.contains("operation timed out")
            || lowercased.contains("connection timed out")
        {
            return SSHConnectionErrorDetails(
                message: "SSH-сервер \(host) не ответил вовремя. Проверь сеть, VPN и доступность хоста.",
                shouldRetryAutomatically: true,
                hostKeyChanged: false
            )
        }
        if lowercased.contains("no route to host") {
            return SSHConnectionErrorDetails(
                message: "До SSH-сервера \(host) нет сетевого маршрута. Проверь сеть или VPN.",
                shouldRetryAutomatically: true,
                hostKeyChanged: false
            )
        }

        let fallback = "Не удалось подключиться к SSH-серверу \(host)."
        return SSHConnectionErrorDetails(
            message: raw.isEmpty ? fallback : fallback + "\n\n" + raw,
            shouldRetryAutomatically: true,
            hostKeyChanged: false
        )
    }

    private static func lastMeaningfulLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last(where: { !$0.isEmpty }) ?? ""
    }
}
