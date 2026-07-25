@testable import Doma
import Foundation
import XCTest

final class ServiceForwardingPolicyStoreTests: XCTestCase {
    func testPersistsPreferencesPerHostAndAutomaticRemovesOverride() throws {
        let suiteName = "ServiceForwardingPolicyStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ServiceForwardingPolicyStore(defaults: defaults)

        store.set(.included, for: "service-a", host: "buddy")
        store.set(.excluded, for: "service-a", host: "staging")

        XCTAssertEqual(store.preference(for: "service-a", host: "buddy"), .included)
        XCTAssertEqual(store.preference(for: "service-a", host: "staging"), .excluded)
        XCTAssertEqual(store.preference(for: "service-b", host: "buddy"), .automatic)

        store.set(.automatic, for: "service-a", host: "buddy")

        XCTAssertEqual(store.preference(for: "service-a", host: "buddy"), .automatic)
        XCTAssertEqual(store.preference(for: "service-a", host: "staging"), .excluded)
    }
}
