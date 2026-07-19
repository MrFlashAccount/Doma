@testable import Doma
import XCTest

final class StatusStoreTests: XCTestCase {
    func testStatusIsMinimalRedactedRestrictiveAndClearable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DomaStatusStore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DomaStatusStore(directory: directory)
        let secret = "--token super-secret /Users/demo/private-project"
        let result = CycleResult(
            state: .connected,
            masterPID: 42,
            activeForwards: [4321],
            conflicts: [],
            missingSince: [:],
            services: [
                RemoteService(
                    port: 4321,
                    name: "private-service",
                    group: secret,
                    kind: .node,
                    details: secret,
                    isForwarded: true,
                    hasConflict: false,
                    conflictOwners: []
                ),
            ],
            remoteCount: 1,
            error: secret,
            warning: secret,
            shouldRetryAutomatically: true,
            hostKeyChanged: false
        )

        try store.write(result)
        let data = try Data(contentsOf: store.statusURL)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertFalse(text.contains(secret))
        XCTAssertFalse(text.contains("private-service"))
        XCTAssertEqual(Set(object.keys), [
            "schemaVersion", "updatedAt", "state", "activeCount",
            "conflictCount", "remoteCount", "degraded",
        ])
        XCTAssertEqual(try permissions(at: directory), 0o700)
        XCTAssertEqual(try permissions(at: store.statusURL), 0o600)

        store.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.statusURL.path))
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
    }
}
