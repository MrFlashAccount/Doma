import AppKit
@testable import Doma
import XCTest

@MainActor
final class DomaSearchFieldTests: XCTestCase {
    func testSearchFieldRemainsEditableAfterInstallingCustomCell() {
        let searchField = DomaSearchField()

        XCTAssertTrue(searchField.isEditable)
        XCTAssertTrue(searchField.isSelectable)
        XCTAssertTrue(searchField.acceptsFirstResponder)
    }

    func testSearchFieldFocusesWhenAttachedToWindow() async {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let searchField = DomaSearchField(frame: NSRect(x: 20, y: 20, width: 280, height: 40))

        window.contentView?.addSubview(searchField)
        await Task.yield()

        XCTAssertNotNil(searchField.currentEditor())
        XCTAssertTrue(window.firstResponder === searchField.currentEditor())
    }
}
