import Foundation

struct RemoteMonitorOutputParser {
    private static let changeMarker = "__DOMA_INVENTORY_CHANGED__"
    private var buffer = Data()

    mutating func consume(_ data: Data) -> Int {
        buffer.append(data)
        var changes = 0

        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            if Self.isChangeLine(line) {
                changes += 1
            }
        }

        return changes
    }

    static func isChangeLine(_ line: String) -> Bool {
        line == changeMarker || line.hasPrefix(changeMarker + " ")
    }
}

final class RemoteInventoryMonitor: @unchecked Sendable {
    static let watcherScript = #"""
    if [ ! -r /proc/net/tcp ]; then
      printf '/proc/net/tcp is unavailable on the remote host\n' >&2
      exit 127
    fi

    doma_listener_signature() {
      awk '$4 == "0A" {
        split($2, local_address, ":")
        port = "x" toupper(local_address[2])
        if (port >= "x0400" && port <= "x7FFF") {
          print FILENAME, $2, $10
        }
      }' /proc/net/tcp /proc/net/tcp6 2>/dev/null \
        | LC_ALL=C sort \
        | cksum
    }

    previous=''
    while :; do
      current=$(doma_listener_signature)
      if [ "$current" != "$previous" ]; then
        printf '__DOMA_INVENTORY_CHANGED__ %s\n' "$current"
        previous=$current
      fi
      sleep 1
    done
    """#

    private static let ssh = "/usr/bin/ssh"

    private let host: String
    private let socketPath: String
    private let queue = DispatchQueue(label: "com.mrflashaccount.doma.remote-monitor")

    private var process: Process?
    private var output: Pipe?
    private var errors: Pipe?
    private var parser = RemoteMonitorOutputParser()
    private var stderr = Data()
    private var stopping = false
    private var onChange: (@Sendable () -> Void)?
    private var onTermination: (@Sendable (String?) -> Void)?

    init(host: String, socketPath: String) {
        self.host = host
        self.socketPath = socketPath
    }

    func start(
        onChange: @escaping @Sendable () -> Void,
        onTermination: @escaping @Sendable (String?) -> Void
    ) throws {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        let input = Pipe()

        process.executableURL = URL(fileURLWithPath: Self.ssh)
        process.arguments = [
            "-S", socketPath,
            "-o", "ControlMaster=no",
            "-o", "ConnectTimeout=5",
            "-o", "BatchMode=yes",
            host,
            "--", "sh", "-s",
        ]
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = input

        queue.sync {
            self.process = process
            self.output = output
            self.errors = errors
            self.onChange = onChange
            self.onTermination = onTermination
            stopping = false
            parser = RemoteMonitorOutputParser()
            stderr = Data()
        }

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.consumeOutput(data)
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.consumeError(data)
        }
        process.terminationHandler = { [weak self] process in
            self?.finish(status: process.terminationStatus)
        }

        do {
            try process.run()
            input.fileHandleForWriting.write(Data(Self.watcherScript.utf8))
            try input.fileHandleForWriting.close()
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        let process: Process? = queue.sync {
            stopping = true
            onChange = nil
            onTermination = nil
            output?.fileHandleForReading.readabilityHandler = nil
            errors?.fileHandleForReading.readabilityHandler = nil
            let current = self.process
            self.process = nil
            output = nil
            errors = nil
            return current
        }

        process?.terminationHandler = nil
        if process?.isRunning == true {
            process?.terminate()
        }
    }

    private func consumeOutput(_ data: Data) {
        queue.async { [weak self] in
            guard let self, !stopping else { return }
            let changeCount = parser.consume(data)
            guard let onChange else { return }
            for _ in 0..<changeCount {
                onChange()
            }
        }
    }

    private func consumeError(_ data: Data) {
        queue.async { [weak self] in
            guard let self, !stopping else { return }
            stderr.append(data)
            if stderr.count > 16_384 {
                stderr.removeFirst(stderr.count - 16_384)
            }
        }
    }

    private func finish(status: Int32) {
        queue.async { [weak self] in
            guard let self, !stopping else { return }
            stopping = true
            output?.fileHandleForReading.readabilityHandler = nil
            errors?.fileHandleForReading.readabilityHandler = nil
            process = nil
            output = nil
            errors = nil

            let message = String(data: stderr, encoding: .utf8)?
                .split(whereSeparator: \.isNewline)
                .last
                .map(String.init)
            let fallback = status == 0 ? nil : "Remote monitor exited with status \(status)"
            let callback = onTermination
            onChange = nil
            onTermination = nil
            callback?(message ?? fallback)
        }
    }
}
