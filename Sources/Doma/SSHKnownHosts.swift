import Foundation

struct SSHKnownHostsPlan: Equatable, Sendable {
    let target: String
    let files: [String]
}

enum SSHKnownHostsManager {
    private static let ssh = "/usr/bin/ssh"
    private static let sshKeygen = "/usr/bin/ssh-keygen"

    static func removeStaleKey(host: String) -> String? {
        let configuration = CommandRunner.run(
            ssh,
            arguments: ["-G", host],
            timeout: 5
        )
        guard configuration.status == 0,
              let plan = plan(from: configuration.stdout, homeDirectory: NSHomeDirectory())
        else {
            return "Не удалось определить known_hosts для \(host)."
        }

        return removeStaleKey(using: plan)
    }

    static func removeStaleKey(using plan: SSHKnownHostsPlan) -> String? {
        var removedKey = false
        for file in plan.files where FileManager.default.fileExists(atPath: file) {
            let lookup = CommandRunner.run(
                sshKeygen,
                arguments: ["-F", plan.target, "-f", file],
                timeout: 5
            )
            guard lookup.status == 0, !(lookup.stdout + lookup.stderr).isEmpty else { continue }

            let removal = CommandRunner.run(
                sshKeygen,
                arguments: ["-R", plan.target, "-f", file],
                timeout: 5
            )
            guard removal.status == 0 else {
                let diagnostic = lastMeaningfulLine(removal.stderr.isEmpty ? removal.stdout : removal.stderr)
                return diagnostic.isEmpty
                    ? "Не удалось удалить старый ключ \(plan.target) из \(file)."
                    : diagnostic
            }
            removedKey = true
        }

        guard removedKey else {
            return "Старая запись для \(plan.target) не найдена в пользовательских known_hosts."
        }
        return nil
    }

    static func plan(from sshConfiguration: String, homeDirectory: String) -> SSHKnownHostsPlan? {
        var hostname: String?
        var port = 22
        var hostKeyAlias: String?
        var files: [String] = []

        for line in sshConfiguration.split(whereSeparator: \.isNewline) {
            let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard fields.count == 2 else { continue }

            let key = String(fields[0])
            let value = String(fields[1])
            switch key {
            case "hostname":
                hostname = value
            case "port":
                port = Int(value) ?? 22
            case "hostkeyalias" where value != "none":
                hostKeyAlias = value
            case "userknownhostsfile":
                files = value.split(whereSeparator: \.isWhitespace)
                    .map(String.init)
                    .filter { $0 != "none" }
                    .map { expand(path: $0, homeDirectory: homeDirectory) }
            default:
                continue
            }
        }

        guard let hostname else { return nil }
        let lookupHost = hostKeyAlias ?? hostname
        let target = port == 22 ? lookupHost : "[\(lookupHost)]:\(port)"
        return SSHKnownHostsPlan(target: target, files: files)
    }

    private static func expand(path: String, homeDirectory: String) -> String {
        var expanded = path.replacingOccurrences(of: "%d", with: homeDirectory)
        if expanded == "~" {
            expanded = homeDirectory
        } else if expanded.hasPrefix("~/") {
            expanded = homeDirectory + expanded.dropFirst()
        }
        return expanded
    }

    private static func lastMeaningfulLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last(where: { !$0.isEmpty }) ?? ""
    }
}
