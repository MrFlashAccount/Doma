import Foundation

enum RemoteAccessErrorFormatter {
    static let permissionMarker = "__DOMA_PERMISSION_DENIED__"
    static let dependencyMarker = "__DOMA_DEPENDENCY_MISSING__"
    static let socketScanMarker = "__DOMA_SOCKET_SCAN_FAILED__"

    static func inventoryDetails(host: String, result: CommandResult) -> RemoteAccessErrorDetails {
        let diagnostic = combinedOutput(result)
        let lowercased = diagnostic.lowercased()

        if result.status == 255 {
            let ssh = SSHConnectionErrorFormatter.details(host: host, result: result)
            return RemoteAccessErrorDetails(
                message: ssh.message,
                shouldRetryAutomatically: ssh.shouldRetryAutomatically
            )
        }
        if diagnostic.contains(permissionMarker)
            || lowercased.contains("permission denied")
        {
            return RemoteAccessErrorDetails(
                message: permissionMessage(host: host, diagnostic: diagnostic),
                shouldRetryAutomatically: false
            )
        }
        if diagnostic.contains(dependencyMarker)
            || lowercased.contains("command not found")
            || result.status == 127
        {
            return RemoteAccessErrorDetails(
                message: dependencyMessage(host: host, diagnostic: diagnostic),
                shouldRetryAutomatically: false
            )
        }
        if diagnostic.contains(socketScanMarker) {
            return RemoteAccessErrorDetails(
                message: "Не удалось прочитать listening sockets на SSH-сервере \(host).\(diagnosticSuffix(diagnostic))",
                shouldRetryAutomatically: true
            )
        }

        let fallback = "Не удалось получить список портов с SSH-сервера \(host)."
        return RemoteAccessErrorDetails(
            message: fallback + diagnosticSuffix(diagnostic),
            shouldRetryAutomatically: true
        )
    }

    static func monitorTermination(host: String, status: Int32, stderr: String) -> RemoteMonitorTermination {
        let lowercased = stderr.lowercased()
        if status == 255 {
            let ssh = SSHConnectionErrorFormatter.details(
                host: host,
                result: CommandResult(status: status, stdout: "", stderr: stderr)
            )
            return RemoteMonitorTermination(
                message: ssh.message,
                shouldRetryAutomatically: ssh.shouldRetryAutomatically
            )
        }
        if stderr.contains(permissionMarker)
            || lowercased.contains("permission denied")
        {
            return RemoteMonitorTermination(
                message: permissionMessage(host: host, diagnostic: stderr),
                shouldRetryAutomatically: false
            )
        }
        if stderr.contains(dependencyMarker) || status == 127 {
            return RemoteMonitorTermination(
                message: dependencyMessage(host: host, diagnostic: stderr),
                shouldRetryAutomatically: false
            )
        }
        let raw = lastMeaningfulLine(stderr)
        return RemoteMonitorTermination(
            message: raw.isEmpty && status != 0 ? "Remote monitor exited with status \(status)" : raw.nilIfEmpty,
            shouldRetryAutomatically: true
        )
    }

    private static func permissionMessage(host: String, diagnostic: String) -> String {
        "Недостаточно прав на SSH-сервере \(host): Doma не может прочитать listening sockets. Проверь права удалённого пользователя на /proc/net/tcp и запуск ss.\(diagnosticSuffix(diagnostic))"
    }

    private static func dependencyMessage(host: String, diagnostic: String) -> String {
        "SSH-сервер \(host) не предоставляет команды или /proc, необходимые для поиска listening sockets.\(diagnosticSuffix(diagnostic))"
    }

    private static func combinedOutput(_ result: CommandResult) -> String {
        [result.stdout, result.stderr]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static func diagnosticSuffix(_ diagnostic: String) -> String {
        let raw = lastMeaningfulLine(diagnostic)
        let detail = [permissionMarker, dependencyMarker, socketScanMarker]
            .reduce(raw) { value, marker in
                value.replacingOccurrences(of: marker, with: "")
            }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? "" : "\n\n" + detail
    }

    private static func lastMeaningfulLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last(where: { !$0.isEmpty }) ?? ""
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
