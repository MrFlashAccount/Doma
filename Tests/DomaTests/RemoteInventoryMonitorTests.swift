@testable import Doma
import XCTest

final class RemoteInventoryMonitorTests: XCTestCase {
    func testParserRecognizesMarkersAcrossArbitraryChunks() {
        var parser = RemoteMonitorOutputParser()

        XCTAssertEqual(parser.consume(Data("ignored\n__DOMA_INVEN".utf8)), 0)
        XCTAssertEqual(parser.consume(Data("TORY_CHANGED__ 42 7\n".utf8)), 1)
        XCTAssertEqual(
            parser.consume(Data("__DOMA_INVENTORY_CHANGED__\nnoise\n__DOMA_INVENTORY_CHANGED__ 43 8\n".utf8)),
            2
        )
    }

    func testParserRejectsSimilarButInvalidLines() {
        XCTAssertFalse(RemoteMonitorOutputParser.isChangeLine("DOMA_INVENTORY_CHANGED"))
        XCTAssertFalse(RemoteMonitorOutputParser.isChangeLine("x__DOMA_INVENTORY_CHANGED__ 42"))
        XCTAssertTrue(RemoteMonitorOutputParser.isChangeLine("__DOMA_INVENTORY_CHANGED__ 42 7"))
    }

    func testWatcherHotPathOnlyHashesListeningSocketRows() {
        let script = RemoteInventoryMonitor.watcherScript

        XCTAssertTrue(script.contains("/proc/net/tcp"))
        XCTAssertTrue(script.contains(#"$4 == "0A""#))
        XCTAssertTrue(script.contains(#"port >= "x0400""#))
        XCTAssertTrue(script.contains(#"port <= "x7FFF""#))
        XCTAssertTrue(script.contains("cksum"))
        XCTAssertTrue(script.contains("sleep 1"))
        XCTAssertFalse(script.contains("ss -H"))
        XCTAssertFalse(script.contains("docker ps"))
        XCTAssertFalse(script.contains("ps -eo"))
        XCTAssertFalse(script.contains("/proc/[0-9]"))
    }
}
