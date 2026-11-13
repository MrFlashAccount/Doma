import AppKit
@testable import Doma
import XCTest

@MainActor
final class DomaSearchFieldTests: XCTestCase {
    func testSearchFieldUsesEditableSystemCellWithoutBuiltInSearchIcon() throws {
        let searchField = DomaSearchField(frame: NSRect(x: 0, y: 0, width: 280, height: 48))
        let searchCell = try XCTUnwrap(searchField.cell as? NSSearchFieldCell)

        XCTAssertTrue(searchField.isEditable)
        XCTAssertTrue(searchField.isSelectable)
        XCTAssertTrue(searchField.acceptsFirstResponder)
        XCTAssertTrue(searchCell.isMember(of: NSSearchFieldCell.self))
        XCTAssertNil(searchCell.searchButtonCell)
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
        var didFocus = false
        searchField.requestFocus { didFocus = $0 }
        await Task.yield()

        XCTAssertTrue(didFocus)
        XCTAssertNotNil(searchField.currentEditor())
        XCTAssertTrue(window.firstResponder === searchField.currentEditor())
    }

    func testSearchFieldDoesNotRefocusWhenLayoutReattachesIt() async {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 140),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let searchField = DomaSearchField(frame: NSRect(x: 20, y: 20, width: 280, height: 40))
        let otherField = NSTextField(frame: NSRect(x: 20, y: 80, width: 280, height: 24))
        window.contentView?.addSubview(otherField)
        window.contentView?.addSubview(searchField)
        searchField.requestFocus { _ in }
        await Task.yield()

        XCTAssertTrue(window.makeFirstResponder(otherField))
        let otherEditor = otherField.currentEditor()
        XCTAssertNotNil(otherEditor)

        searchField.removeFromSuperview()
        window.contentView?.addSubview(searchField)
        await Task.yield()

        XCTAssertTrue(window.firstResponder === otherEditor)
    }

    func testRecreatedSearchFieldDoesNotAutofocusWithoutARequest() async {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 140),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let otherField = NSTextField(frame: NSRect(x: 20, y: 80, width: 280, height: 24))
        window.contentView?.addSubview(otherField)
        XCTAssertTrue(window.makeFirstResponder(otherField))
        let otherEditor = otherField.currentEditor()
        XCTAssertNotNil(otherEditor)

        let recreatedSearchField = DomaSearchField(
            frame: NSRect(x: 20, y: 20, width: 280, height: 40)
        )
        window.contentView?.addSubview(recreatedSearchField)
        await Task.yield()

        XCTAssertTrue(window.firstResponder === otherEditor)
    }

    func testExternalStateDoesNotOverwriteActiveEditing() async {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let searchField = DomaSearchField(frame: NSRect(x: 20, y: 20, width: 280, height: 40))
        window.contentView?.addSubview(searchField)
        searchField.requestFocus { _ in }
        await Task.yield()
        let editor = searchField.currentEditor()
        XCTAssertNotNil(editor)

        editor?.string = "abcd"
        editor?.selectedRange = NSRange(location: 4, length: 0)
        searchField.applyExternalText("abc")

        XCTAssertEqual(editor?.string, "abcd")
        XCTAssertEqual(editor?.selectedRange, NSRange(location: 4, length: 0))
    }

    func testExternalStateUpdatesInactiveField() {
        let searchField = DomaSearchField()

        searchField.applyExternalText("abc")

        XCTAssertEqual(searchField.stringValue, "abc")
    }
}
