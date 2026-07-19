import Darwin
import Foundation

/// Cancels a launched command and every descendant it has already spawned (including SSH_ASKPASS).
final class CommandCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancellationRequested = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancellationRequested
    }

    func register(_ process: Process) {
        lock.lock()
        self.process = process
        let cancelled = cancellationRequested
        lock.unlock()
        if cancelled {
            Self.terminateTree(process)
        }
    }

    func unregister(_ process: Process) {
        lock.lock()
        if self.process === process {
            self.process = nil
        }
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancellationRequested = true
        let process = self.process
        lock.unlock()
        if let process {
            Self.terminateTree(process)
        }
    }

    private static func terminateTree(_ process: Process) {
        guard process.isRunning else { return }
        let rootPID = process.processIdentifier
        // Kill the captured descendants immediately. Delayed re-kill of cached PIDs risks
        // targeting a recycled PID after the root exits and children are re-parented.
        for pid in descendantPIDs(of: rootPID).reversed() {
            _ = Darwin.kill(pid, SIGKILL)
        }
        process.terminate()

        Thread.sleep(forTimeInterval: 0.15)
        if process.isRunning {
            _ = Darwin.kill(rootPID, SIGKILL)
        }
    }

    private static func descendantPIDs(of rootPID: pid_t) -> [pid_t] {
        var discovered: [pid_t] = []
        var pending = [rootPID]
        while let parent = pending.popLast() {
            var children = [pid_t](repeating: 0, count: 256)
            let byteCount = children.count * MemoryLayout<pid_t>.stride
            let count = children.withUnsafeMutableBytes { buffer in
                proc_listchildpids(parent, buffer.baseAddress, Int32(byteCount))
            }
            guard count > 0 else { continue }
            let liveChildren = children.prefix(Int(count)).filter { $0 > 0 }
            discovered.append(contentsOf: liveChildren)
            pending.append(contentsOf: liveChildren)
        }
        return discovered
    }
}

enum CommandRunner {
    private final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Data()

        func store(_ value: Data) {
            lock.lock()
            self.value = value
            lock.unlock()
        }

        func snapshot() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    static func run(
        _ executable: String,
        arguments: [String],
        stdin: String? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval = 10,
        cancellation: CommandCancellation? = nil
    ) -> CommandResult {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        let input = Pipe()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = output
        process.standardError = errors
        if stdin != nil {
            process.standardInput = input
        }

        cancellation?.register(process)
        defer { cancellation?.unregister(process) }

        do {
            try process.run()
        } catch {
            return CommandResult(status: 127, stdout: "", stderr: error.localizedDescription)
        }
        if cancellation?.isCancelled == true {
            cancellation?.cancel()
        }

        let stdoutData = DataBox()
        let stderrData = DataBox()
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            stdoutData.store(output.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrData.store(errors.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }

        if let stdin {
            input.fileHandleForWriting.write(Data(stdin.utf8))
            try? input.fileHandleForWriting.close()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline && cancellation?.isCancelled != true {
            Thread.sleep(forTimeInterval: 0.05)
        }

        let wasCancelled = cancellation?.isCancelled == true
        let timedOut = process.isRunning && !wasCancelled
        if process.isRunning {
            if wasCancelled {
                cancellation?.cancel()
            } else {
                terminate(process)
            }
        }

        process.waitUntilExit()
        if readers.wait(timeout: .now() + 2) == .timedOut {
            try? output.fileHandleForReading.close()
            try? errors.fileHandleForReading.close()
            _ = readers.wait(timeout: .now() + 1)
        }
        let stdout = String(data: stdoutData.snapshot(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrData.snapshot(), encoding: .utf8) ?? ""
        let status: Int32
        if wasCancelled {
            status = 130
        } else {
            status = timedOut ? 124 : process.terminationStatus
        }
        return CommandResult(status: status, stdout: stdout, stderr: stderr)
    }

    static func runAsync(
        _ executable: String,
        arguments: [String],
        stdin: String? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval = 10
    ) async -> CommandResult {
        let cancellation = CommandCancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: run(
                        executable,
                        arguments: arguments,
                        stdin: stdin,
                        environment: environment,
                        timeout: timeout,
                        cancellation: cancellation
                    ))
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func terminate(_ process: Process) {
        let cancellation = CommandCancellation()
        cancellation.register(process)
        cancellation.cancel()
        cancellation.unregister(process)
    }
}
