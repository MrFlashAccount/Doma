import Foundation

struct RemoteMonitorParseResult: Equatable, Sendable {
    let changeDetected: Bool
    let protocolError: String?
}

struct RemoteMonitorOutputParser {
    private static let changeMarker = "__DOMA_INVENTORY_CHANGED__"
    private static let maximumBufferedBytes = 16_384
    private static let maximumLinesPerChunk = 512
    private var buffer = Data()

    mutating func consume(_ data: Data) -> RemoteMonitorParseResult {
        buffer.append(data)
        guard buffer.count <= Self.maximumBufferedBytes else {
            buffer.removeAll(keepingCapacity: false)
            return RemoteMonitorParseResult(
                changeDetected: false,
                protocolError: "remote monitor produced a line larger than \(Self.maximumBufferedBytes) bytes"
            )
        }

        var changeDetected = false
        var processedLines = 0

        while let newline = buffer.firstIndex(of: 0x0A) {
            processedLines += 1
            guard processedLines <= Self.maximumLinesPerChunk else {
                buffer.removeAll(keepingCapacity: false)
                return RemoteMonitorParseResult(
                    changeDetected: changeDetected,
                    protocolError: "remote monitor flooded the channel with markers"
                )
            }
            let lineData = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            if Self.isChangeLine(line) {
                changeDetected = true
            }
        }

        return RemoteMonitorParseResult(changeDetected: changeDetected, protocolError: nil)
    }

    static func isChangeLine(_ line: String) -> Bool {
        line == changeMarker || line.hasPrefix(changeMarker + " ")
    }
}

final class RemoteInventoryMonitor: @unchecked Sendable {
    static let watcherScript = #"""
    if [ ! -e /proc/net/tcp ]; then
      printf '__DOMA_DEPENDENCY_MISSING__ /proc/net/tcp is unavailable\n' >&2
      exit 127
    fi
    if [ ! -r /proc/net/tcp ]; then
      printf '__DOMA_PERMISSION_DENIED__ cannot read /proc/net/tcp\n' >&2
      exit 77
    fi
    set -- /proc/net/tcp
    if [ -e /proc/net/tcp6 ]; then
      if [ ! -r /proc/net/tcp6 ]; then
        printf '__DOMA_PERMISSION_DENIED__ cannot read /proc/net/tcp6\n' >&2
        exit 77
      fi
      set -- "$@" /proc/net/tcp6
    fi
    for tool in awk sort cksum sleep; do
      if ! command -v "$tool" >/dev/null 2>&1; then
        printf '__DOMA_DEPENDENCY_MISSING__ %s is unavailable\n' "$tool" >&2
        exit 127
      fi
    done

    doma_listener_signature() {
      rows=$(awk '$4 == "0A" {
        split($2, local_address, ":")
        port = "x" toupper(local_address[2])
        if (port >= "x0400" && port <= "x7FFF") {
          print FILENAME, $2, $10
        }
      }' "$@" 2>&1)
      status=$?
      if [ "$status" -ne 0 ]; then
        case "$rows" in
          *ermission\ denied*) printf '__DOMA_PERMISSION_DENIED__ %s\n' "$rows" >&2; return 77 ;;
          *) printf '__DOMA_WATCHER_READ_FAILED__ %s\n' "$rows" >&2; return 75 ;;
        esac
      fi
      sorted=$(printf '%s\n' "$rows" | LC_ALL=C sort 2>&1)
      status=$?
      if [ "$status" -ne 0 ]; then
        printf '__DOMA_WATCHER_READ_FAILED__ %s\n' "$sorted" >&2
        return 75
      fi
      checksum=$(printf '%s\n' "$sorted" | cksum 2>&1)
      status=$?
      if [ "$status" -ne 0 ]; then
        printf '__DOMA_WATCHER_READ_FAILED__ %s\n' "$checksum" >&2
        return 75
      fi
      printf '%s\n' "$checksum"
    }

    previous=''
    while :; do
      current=$(doma_listener_signature "$@")
      status=$?
      if [ "$status" -ne 0 ]; then
        exit "$status"
      fi
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
    private var onTermination: (@Sendable (RemoteMonitorTermination) -> Void)?

    init(host: String, socketPath: String) {
        self.host = host
        self.socketPath = socketPath
    }

    static func sshArguments(host: String, socketPath: String) -> [String] {
        var arguments = [
            "-S", socketPath,
            "-o", "ControlMaster=no",
            "-o", "ConnectTimeout=5",
            "-o", "BatchMode=yes",
        ]
        arguments.append(contentsOf: SSHInvocation.securityOptions)
        arguments.append(contentsOf: [host, "--", "sh", "-s"])
        return arguments
    }

    func start(
        onChange: @escaping @Sendable () -> Void,
        onTermination: @escaping @Sendable (RemoteMonitorTermination) -> Void
    ) throws {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        let input = Pipe()

        process.executableURL = URL(fileURLWithPath: Self.ssh)
        process.arguments = Self.sshArguments(host: host, socketPath: socketPath)
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
        queue.sync { [weak self] in
            guard let self, !stopping else { return }
            let result = parser.consume(data)
            if let protocolError = result.protocolError {
                stderr.append(Data("__DOMA_PROTOCOL_ERROR__ \(protocolError)\n".utf8))
                process?.terminate()
                return
            }
            if result.changeDetected {
                onChange?()
            }
        }
    }

    private func consumeError(_ data: Data) {
        queue.sync { [weak self] in
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

            let errorOutput = String(data: stderr, encoding: .utf8) ?? ""
            let termination = RemoteAccessErrorFormatter.monitorTermination(
                host: host,
                status: status,
                stderr: errorOutput
            )
            let callback = onTermination
            onChange = nil
            onTermination = nil
            callback?(termination)
        }
    }
}
