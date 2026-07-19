import Darwin
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

enum SSHInvocation {
    static let securityOptions = [
        "-o", "ForwardAgent=no",
        "-o", "ForwardX11=no",
        "-o", "PermitLocalCommand=no",
    ]
}

/// Crash-durable marker proving stale-key recovery must not inherit permissive SSH config.
enum SSHHostTrustMarkerState: Equatable, Sendable {
    case absent
    case pending
}

enum SSHHostTrustStoreError: LocalizedError, Equatable, Sendable {
    case corrupt
    case unreadable

    var errorDescription: String? {
        switch self {
        case .corrupt:
            "Маркер обязательного подтверждения SSH-ключа повреждён."
        case .unreadable:
            "Не удалось прочитать маркер обязательного подтверждения SSH-ключа."
        }
    }
}

struct SSHHostTrustStore: Sendable {
    let directory: URL

    static var standard: SSHHostTrustStore {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return SSHHostTrustStore(
            directory: applicationSupport.appendingPathComponent("Doma/host-trust", isDirectory: true)
        )
    }

    func markerState(for target: String) throws -> SSHHostTrustMarkerState {
        let marker = markerURL(for: target)
        var metadata = stat()
        if Darwin.lstat(marker.path, &metadata) != 0 {
            if errno == ENOENT { return .absent }
            throw SSHHostTrustStoreError.unreadable
        }
        let data: Data
        do {
            data = try Data(contentsOf: marker)
        } catch {
            throw SSHHostTrustStoreError.unreadable
        }
        guard data == markerData(for: target) else {
            throw SSHHostTrustStoreError.corrupt
        }
        return .pending
    }

    func requiresExplicitConfirmation(for target: String) throws -> Bool {
        try markerState(for: target) == .pending
    }

    func requireExplicitConfirmation(for target: String) throws {
        let manager = FileManager.default
        try manager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let marker = markerURL(for: target)
        let temporary = directory.appendingPathComponent(".pending-\(UUID().uuidString)")
        let data = markerData(for: target)
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var shouldRemoveTemporary = true
        defer {
            Darwin.close(descriptor)
            if shouldRemoveTemporary {
                try? manager.removeItem(at: temporary)
            }
        }

        try data.withUnsafeBytes { rawBuffer in
            guard var address = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, address, remaining)
                guard written > 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
                remaining -= written
                address = address.advanced(by: written)
            }
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        guard Darwin.rename(temporary.path, marker.path) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        shouldRemoveTemporary = false
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
        try syncDirectory()
        guard try requiresExplicitConfirmation(for: target) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    func markConfirmed(target: String) throws {
        let marker = markerURL(for: target)
        guard FileManager.default.fileExists(atPath: marker.path) else { return }
        try FileManager.default.removeItem(at: marker)
        try syncDirectory()
    }

    func strictHostKeyArguments(for target: String) throws -> [String] {
        try requiresExplicitConfirmation(for: target)
            ? ["-o", "StrictHostKeyChecking=ask", "-o", "UpdateHostKeys=no"]
            : []
    }

    private func markerURL(for target: String) -> URL {
        directory.appendingPathComponent(String(format: "%016llx.pending", fnv1a(target)))
    }

    private func markerData(for target: String) -> Data {
        Data(("doma-host-trust-v1\n" + target + "\n").utf8)
    }

    private func syncDirectory() throws {
        let descriptor = Darwin.open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }

    private func fnv1a(_ value: String) -> UInt64 {
        value.utf8.reduce(14695981039346656037) { hash, byte in
            (hash ^ UInt64(byte)) &* 1099511628211
        }
    }
}

enum SSHHostTrustState {
    static func requiresExplicitConfirmation(for target: String) throws -> Bool {
        try SSHHostTrustStore.standard.requiresExplicitConfirmation(for: target)
    }

    static func requireExplicitConfirmation(for target: String) throws {
        try SSHHostTrustStore.standard.requireExplicitConfirmation(for: target)
    }

    static func markConfirmed(target: String) throws {
        try SSHHostTrustStore.standard.markConfirmed(target: target)
    }

    static func strictHostKeyArguments(for target: String) throws -> [String] {
        try SSHHostTrustStore.standard.strictHostKeyArguments(for: target)
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
