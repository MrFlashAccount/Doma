import Foundation

enum SSHConfig {
    static func hosts() -> [SSHHost] {
        let config = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/config")

        guard let contents = try? String(contentsOf: config, encoding: .utf8) else {
            return []
        }

        var aliases = Set<String>()
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#") else { continue }

            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.first?.lowercased() == "host" else { continue }

            for alias in parts.dropFirst()
            where !alias.contains("*") && !alias.contains("?") && !alias.contains("!") {
                aliases.insert(alias)
            }
        }

        return aliases
            .sorted { lhs, rhs in
                if lhs == "buddy" { return true }
                if rhs == "buddy" { return false }
                return lhs.localizedStandardCompare(rhs) == .orderedAscending
            }
            .map(SSHHost.init(alias:))
    }
}
