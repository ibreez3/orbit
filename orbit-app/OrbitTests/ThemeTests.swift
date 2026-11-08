import XCTest
@testable import Orbit

final class ThemeTests: XCTestCase {
    func testThemeFileIdentifiersMapToAppThemes() {
        XCTAssertEqual(AppTheme(themeFileID: "catppuccin-mocha"), .catppuccinMocha)
        XCTAssertEqual(AppTheme(themeFileID: "tokyo_night"), .tokyoNight)
        XCTAssertEqual(AppTheme(themeFileID: "gruvbox-dark"), .gruvboxDark)
        XCTAssertEqual(AppTheme(themeFileID: "light"), .light)
        XCTAssertNil(AppTheme(themeFileID: "unknown-theme"))
    }
}
