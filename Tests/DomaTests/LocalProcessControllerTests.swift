@testable import Doma
import XCTest

final class LocalProcessControllerTests: XCTestCase {
    func testParseListenersGroupsOwnersAndProtectsUnsafeProcesses() throws {
        let output = """
        p123
        cvite
        u501
        n127.0.0.1:3000
        p456
        cssh
        u501
        n*:3000
        p789
        crootd
        u0
        n*:4000
        p999
        cDoma
        u501
        n127.0.0.1:5000
        """

        let listeners = LocalProcessController.parseListeners(
            output,
            currentUserID: 501,
            currentProcessID: 999
        )

        let port3000 = try XCTUnwrap(listeners[3000])
        XCTAssertEqual(port3000.pids, [123, 456])
        XCTAssertEqual(port3000.endpointsByPID[123], ["127.0.0.1:3000"])
        XCTAssertTrue(try XCTUnwrap(port3000.ownersByPID[123]).canTerminate)
        XCTAssertFalse(try XCTUnwrap(port3000.ownersByPID[456]).canTerminate)
        XCTAssertFalse(try XCTUnwrap(listeners[4000]?.ownersByPID[789]).canTerminate)
        XCTAssertFalse(try XCTUnwrap(listeners[5000]?.ownersByPID[999]).canTerminate)
    }

    func testTerminateStopsOwnedTemporaryListener() throws {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw XCTSkip("Python is unavailable")
        }

        let process = Process()
        let output = Pipe()
        process.executableURL = python
        process.arguments = [
            "-u",
            "-c",
            "import socket,time; s=socket.socket(); s.bind(('127.0.0.1',0)); s.listen(); print(s.getsockname()[1], flush=True); time.sleep(30)",
        ]
        process.standardOutput = output
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
            }
            process.waitUntilExit()
        }

        let line = String(data: output.fileHandleForReading.availableData, encoding: .utf8) ?? ""
        let port = try XCTUnwrap(Int(line.trimmingCharacters(in: .whitespacesAndNewlines)))

        var owner: LocalPortOwner?
        for _ in 0..<20 {
            owner = LocalProcessController.listeners()[port]?.ownersByPID[process.processIdentifier]
            if owner != nil { break }
            Thread.sleep(forTimeInterval: 0.1)
        }

        let discoveredOwner = try XCTUnwrap(owner)
        XCTAssertTrue(discoveredOwner.canTerminate)
        XCTAssertNil(LocalProcessController.terminate([discoveredOwner], on: port))
        XCTAssertNil(LocalProcessController.listeners()[port]?.ownersByPID[process.processIdentifier])
    }
}
