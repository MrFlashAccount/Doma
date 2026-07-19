import Foundation

struct RemoteListenerRecord {
    let port: Int
    let pid: Int?
    let command: String?
    let userID: Int?
}

struct RemoteDockerRecord {
    let container: String
    let image: String
    let project: String
    let service: String
    let containerPort: Int?
}

struct RemoteProcessRecord {
    let parentPID: Int
    let userID: Int
    let user: String
    let command: String
    let arguments: String
}

struct RemoteInventory {
    var currentUserID: Int?
    var listeners: [RemoteListenerRecord] = []
    var dockerByPort: [Int: RemoteDockerRecord] = [:]
    var processes: [Int: RemoteProcessRecord] = [:]
    var cwdByPID: [Int: String] = [:]
    var warnings = Set<RemoteInventoryWarning>()
    var sawSocketSection = false
    var sawProcessSection = false

    var warningMessage: String? {
        let messages = warnings.sorted { $0.rawValue < $1.rawValue }.map(\.message)
        return messages.isEmpty ? nil : messages.joined(separator: " ")
    }
}

enum RemoteInventoryWarning: String {
    case docker
    case partialProcesses
    case partialSockets
    case processes
    case protocolSections

    var message: String {
        switch self {
        case .docker:
            "Метаданные Docker недоступны; порты продолжают пробрасываться как TCP."
        case .processes:
            "Метаданные процессов недоступны; порты продолжают пробрасываться как TCP."
        case .partialSockets:
            "Часть listening sockets пришла без PID/имени процесса; TCP-пробросы продолжают работать."
        case .partialProcesses:
            "Часть процессов не сопоставилась с listening sockets; TCP-пробросы продолжают работать."
        case .protocolSections:
            "Удалённый inventory вернул неполный набор секций; доступные TCP-порты продолжают пробрасываться."
        }
    }
}

enum RemoteInventoryParser {
    static func parse(_ output: String) -> RemoteInventory {
        enum Section { case none, user, ss, docker, ps, cwd }
        var section = Section.none
        var inventory = RemoteInventory()

        for line in output.split(whereSeparator: \.isNewline).map(String.init) {
            if line == "__DOMA_WARNING_DOCKER__" {
                inventory.warnings.insert(.docker)
                continue
            }
            if line == "__DOMA_WARNING_PROCESSES__" {
                inventory.warnings.insert(.processes)
                continue
            }

            switch line {
            case "__USER__": section = .user
            case "__SS__":
                inventory.sawSocketSection = true
                section = .ss
            case "__DOCKER__": section = .docker
            case "__PS__":
                inventory.sawProcessSection = true
                section = .ps
            case "__CWD__": section = .cwd
            default:
                switch section {
                case .user:
                    if inventory.currentUserID == nil {
                        inventory.currentUserID = Int(line.trimmingCharacters(in: .whitespaces))
                    }
                case .ss:
                    let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
                    guard fields.count >= 4,
                          let port = RemoteTextMatching.firstCapture(
                            in: fields[3],
                            pattern: #":(\d+)$"#
                          ).flatMap(Int.init)
                    else { continue }
                    let pid = RemoteTextMatching.firstCapture(
                        in: line,
                        pattern: #"pid=(\d+)"#
                    ).flatMap(Int.init)
                    let command = RemoteTextMatching.firstCapture(
                        in: line,
                        pattern: #"\(\(\"([^\"]+)\""#
                    )
                    let userID = RemoteTextMatching.firstCapture(
                        in: line,
                        pattern: #"uid:(\d+)"#
                    ).flatMap(Int.init)
                    inventory.listeners.append(
                        RemoteListenerRecord(
                            port: port,
                            pid: pid,
                            command: command,
                            userID: userID
                        )
                    )
                case .docker:
                    parseDocker(line, into: &inventory)
                case .ps:
                    parseProcess(line, into: &inventory)
                case .cwd:
                    let fields = line.split(separator: "|", maxSplits: 1).map(String.init)
                    if fields.count == 2, let pid = Int(fields[0]) {
                        inventory.cwdByPID[pid] = fields[1]
                    }
                case .none:
                    break
                }
            }
        }

        addCompletenessWarnings(to: &inventory)
        return inventory
    }

    private static func parseDocker(_ line: String, into inventory: inout RemoteInventory) {
        let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 5 else { return }
        for mapping in RemoteTextMatching.captureGroupMatches(
            in: fields[2],
            pattern: #"(?:^|,\s)(?:[^,]*:)?(\d+)->(\d+)/tcp"#
        ) {
            guard mapping.count == 2,
                  let hostPort = Int(mapping[0]),
                  let containerPort = Int(mapping[1])
            else { continue }
            inventory.dockerByPort[hostPort] = RemoteDockerRecord(
                container: fields[0],
                image: fields[1],
                project: fields[3],
                service: fields[4],
                containerPort: containerPort
            )
        }
    }

    private static func parseProcess(_ line: String, into inventory: inout RemoteInventory) {
        guard let groups = RemoteTextMatching.captureGroups(
            in: line,
            pattern: #"^\s*(\d+)\s+(\d+)\s+(\d+)\s+(\S+)\s+(\S+)\s+(.*)$"#
        ),
              groups.count == 6,
              let pid = Int(groups[0]),
              let parentPID = Int(groups[1]),
              let userID = Int(groups[2])
        else { return }
        inventory.processes[pid] = RemoteProcessRecord(
            parentPID: parentPID,
            userID: userID,
            user: groups[3],
            command: groups[4],
            arguments: groups[5]
        )
    }

    private static func addCompletenessWarnings(to inventory: inout RemoteInventory) {
        if !inventory.sawProcessSection {
            inventory.warnings.insert(.protocolSections)
        }
        let hasAnySocketProcessMetadata = inventory.listeners.contains {
            $0.pid != nil || $0.command != nil
        }
        if hasAnySocketProcessMetadata,
           inventory.listeners.contains(where: { $0.pid == nil || $0.command == nil })
        {
            inventory.warnings.insert(.partialSockets)
        }
        let listenerPIDs = Set(inventory.listeners.compactMap(\.pid))
        let missingProcessCount = listenerPIDs.subtracting(inventory.processes.keys).count
        if missingProcessCount >= max(1, listenerPIDs.count / 2), !listenerPIDs.isEmpty {
            inventory.warnings.insert(.partialProcesses)
        }
    }
}

enum RemoteTextMatching {
    static func firstCapture(in text: String, pattern: String) -> String? {
        captureGroups(in: text, pattern: pattern)?.first
    }

    static func captureGroupMatches(in text: String, pattern: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            var groups: [String] = []
            for index in 1..<match.numberOfRanges {
                guard let range = Range(match.range(at: index), in: text) else { return nil }
                groups.append(String(text[range]))
            }
            return groups
        }
    }

    static func captureGroups(in text: String, pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: text,
                range: NSRange(text.startIndex..<text.endIndex, in: text)
              )
        else { return nil }

        return (1..<match.numberOfRanges).compactMap { index in
            guard let range = Range(match.range(at: index), in: text) else { return nil }
            return String(text[range])
        }
    }
}
