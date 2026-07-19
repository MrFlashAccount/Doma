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
    static func details(host: String, result: CommandResult) -> (message: String, shouldRetryAutomatically: Bool) {
        let raw = lastMeaningfulLine(result.stderr.isEmpty ? result.stdout : result.stderr)
        let lowercased = raw.lowercased()

        if lowercased.contains("permission denied")
            || lowercased.contains("too many authentication failures")
        {
            return (
                "Сервер отклонил учётные данные для \(host). Проверь логин, пароль или SSH-ключ.",
                false
            )
        }
        if lowercased.contains("host key verification failed")
            || lowercased.contains("remote host identification has changed")
        {
            return (
                "Не удалось подтвердить ключ сервера \(host). Проверь fingerprint и запись в known_hosts.",
                false
            )
        }
        if lowercased.contains("could not resolve hostname")
            || lowercased.contains("name or service not known")
        {
            return ("Не удалось найти SSH-сервер \(host). Проверь SSH alias и сеть.", true)
        }
        if lowercased.contains("connection refused") {
            return ("SSH-сервер \(host) отклонил соединение. Проверь адрес, порт и запущен ли sshd.", true)
        }
        if lowercased.contains("operation timed out")
            || lowercased.contains("connection timed out")
        {
            return ("SSH-сервер \(host) не ответил вовремя. Проверь сеть, VPN и доступность хоста.", true)
        }
        if lowercased.contains("no route to host") {
            return ("До SSH-сервера \(host) нет сетевого маршрута. Проверь сеть или VPN.", true)
        }

        let fallback = "Не удалось подключиться к SSH-серверу \(host)."
        guard !raw.isEmpty else { return (fallback, true) }
        return (fallback + "\n\n" + raw, true)
    }

    private static func lastMeaningfulLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last(where: { !$0.isEmpty }) ?? ""
    }
}
