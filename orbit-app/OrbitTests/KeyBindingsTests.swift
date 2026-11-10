import XCTest
@testable import Orbit

final class KeyBindingsTests: XCTestCase {
    func testSpecialKeyCodesUseNamedTokens() {
        XCTAssertEqual(KeyBinding.token(keyCode: 126, characters: "\u{1b}"), "up")
        XCTAssertEqual(KeyBinding.token(keyCode: 125, characters: "\u{1c}"), "down")
        XCTAssertEqual(KeyBinding.token(keyCode: 123, characters: "\u{1d}"), "left")
        XCTAssertEqual(KeyBinding.token(keyCode: 124, characters: "\u{1e}"), "right")
        XCTAssertEqual(KeyBinding.token(keyCode: 0x35, characters: "\u{1b}"), "escape")
        XCTAssertEqual(KeyBinding.token(keyCode: 0x24, characters: "\r"), "return")
        XCTAssertEqual(KeyBinding.token(keyCode: 0x33, characters: "\u{7f}"), "delete")
        XCTAssertEqual(KeyBinding.token(keyCode: 0, characters: "K"), "k")
    }

    func testNamedTokensHaveReadableDisplayStrings() {
        let binding = KeyBinding(key: "right", command: true, shift: true)
        XCTAssertEqual(binding.displayString, "⇧⌘→")
    }

    func testPaneDefaultBindingsUseNamedArrowTokens() {
        XCTAssertEqual(KeyBindings.defaultBindings["navPrevPane"]?.key, "up")
        XCTAssertEqual(KeyBindings.defaultBindings["navNextPane"]?.key, "down")
        XCTAssertEqual(KeyBindings.defaultBindings["growPane"]?.key, "right")
        XCTAssertEqual(KeyBindings.defaultBindings["shrinkPane"]?.key, "left")
    }

    func testEveryActionHasABinding() {
        for action in KeyBindings.actionNames {
            XCTAssertNotNil(KeyBindings.defaultBindings[action], "missing default for \(action)")
        }
    }
}
