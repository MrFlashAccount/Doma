import Foundation

enum CommandRunner {
    private final class DataBox: @unchecked Sendable {
        var value = Data()
    }

    static func run(
        _ executable: String,
        arguments: [String],
        stdin: String? = nil,
        timeout: TimeInterval = 10
    ) -> CommandResult {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        let input = Pipe()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors
        if stdin != nil {
            process.standardInput = input
        }

        do {
            try process.run()
        } catch {
            return CommandResult(status: 127, stdout: "", stderr: error.localizedDescription)
        }

        let stdoutData = DataBox()
        let stderrData = DataBox()
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            stdoutData.value = output.fileHandleForReading.readDataToEndOfFile()
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrData.value = errors.fileHandleForReading.readDataToEndOfFile()
            readers.leave()
        }

        if let stdin {
            input.fileHandleForWriting.write(Data(stdin.utf8))
            try? input.fileHandleForWriting.close()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        let timedOut = process.isRunning
        if timedOut {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.2)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }

        process.waitUntilExit()
        readers.wait()
        let stdout = String(data: stdoutData.value, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData.value, encoding: .utf8) ?? ""
        let status: Int32 = timedOut ? 124 : process.terminationStatus
        return CommandResult(status: status, stdout: stdout, stderr: stderr)
    }
}
