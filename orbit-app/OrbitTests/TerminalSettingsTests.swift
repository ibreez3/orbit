import XCTest
import AppKit
import CoreText
import SwiftTerm
@testable import Orbit

final class TerminalSettingsTests: XCTestCase {
    private let defaults = UserDefaults.standard
    private var hadValue = false
    private var previousValue: Any?

    override func setUp() {
        super.setUp()
        hadValue = defaults.object(forKey: "selectToCopy") != nil
        previousValue = defaults.object(forKey: "selectToCopy")
    }

    override func tearDown() {
        if hadValue, let previousValue {
            defaults.set(previousValue, forKey: "selectToCopy")
        } else {
            defaults.removeObject(forKey: "selectToCopy")
        }
        super.tearDown()
    }

    func testSelectToCopyDefaultsToEnabledLikeTheSettingsUI() {
        defaults.removeObject(forKey: "selectToCopy")
        XCTAssertTrue(TerminalRenderSettings.selectToCopyEnabled)

        defaults.set(false, forKey: "selectToCopy")
        XCTAssertFalse(TerminalRenderSettings.selectToCopyEnabled)

        defaults.set(true, forKey: "selectToCopy")
        XCTAssertTrue(TerminalRenderSettings.selectToCopyEnabled)
    }

    @MainActor
    func testResetForNewSessionClearsTUIState() {
        let view = OrbitTerminalView()
        view.feed(text: "\u{1b}[?1049h\u{1b}[?1000h\u{1b}[?2004h")
        let before = view.terminalInputStateSnapshot()
        XCTAssertEqual(before?.isAlternateBuffer, true)

        view.resetForNewSession()

        let after = view.terminalInputStateSnapshot()
        XCTAssertEqual(after?.isAlternateBuffer, false)
        XCTAssertEqual(after?.mouseMode, .off)
        XCTAssertEqual(after?.bracketedPasteMode, false)
    }

    @MainActor
    func testNerdFontFallbackProviderClaimsOnlyPrivateUseIcons() throws {
        let provider = NerdFontGlyphFallbackProvider.shared
        guard provider.isAvailable else {
            throw XCTSkip("Requires an installed Nerd Font")
        }

        let icon = Unicode.Scalar(0xF017)!
        let supplementaryIcon = Unicode.Scalar(0xF0001)!
        let ascii = "A".unicodeScalars.first!
        let cjk = "中".unicodeScalars.first!
        let emoji = Unicode.Scalar(0x1F600)!

        XCTAssertNotNil(provider.placementPolicy(for: icon))
        XCTAssertNil(provider.placementPolicy(for: ascii))
        XCTAssertNil(provider.placementPolicy(for: cjk))
        XCTAssertNil(provider.placementPolicy(for: emoji))
        // Supplementary private-use icons are claimed only when the fallback
        // font actually contains them.
        _ = provider.placementPolicy(for: supplementaryIcon)

        let font14 = try XCTUnwrap(provider.fallbackFont(forPointSize: 14))
        XCTAssertEqual(CTFontGetSize(font14), 14, accuracy: 0.1)
        let postScriptName = CTFontCopyPostScriptName(font14) as String
        XCTAssertFalse(postScriptName.isEmpty)
        XCTAssertNotEqual(postScriptName, "LastResort")
        XCTAssertNotEqual(postScriptName, NSFont(name: "Menlo", size: 14)?.fontName)
        let again = try XCTUnwrap(provider.fallbackFont(forPointSize: 14))
        XCTAssertTrue(CFEqual(font14, again))

        let font18 = try XCTUnwrap(provider.fallbackFont(forPointSize: 18))
        XCTAssertEqual(CTFontGetSize(font18), 18, accuracy: 0.1)
    }

    @MainActor
    func testTerminalViewInstallsNerdFontFallbackAndKeepsTextFont() throws {
        guard NerdFontGlyphFallbackProvider.shared.isAvailable else {
            throw XCTSkip("Requires an installed Nerd Font")
        }
        let view = OrbitTerminalView()
        XCTAssertNotNil(view.glyphFallbackProvider)

        view.configureRenderSettings(TerminalRenderKey(
            theme: .light,
            backgroundAlpha: 1,
            snapshot: TerminalSettingsSnapshot(
                fontFamily: "Menlo",
                fontSize: 14,
                fontLigatures: false,
                cursorStyle: "bar",
                scrollbackLines: 10000,
                backgroundBlur: false
            )
        ))
        XCTAssertEqual(view.font.fontName, NSFont(name: "Menlo", size: 14)?.fontName)
    }

    @MainActor
    func testSystemFallbackStillHandlesCJKAndEmoji() {
        guard let textFont = NSFont(name: "Menlo", size: 14) else {
            XCTFail("Menlo is unavailable")
            return
        }
        for text in ["中", "😀"] {
            let resolved = CTFontCreateForString(
                textFont as CTFont,
                text as CFString,
                CFRange(location: 0, length: text.utf16.count)
            )
            XCTAssertNotEqual(CTFontCopyPostScriptName(resolved) as String, "LastResort")
        }
    }
}
