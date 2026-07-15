import SwiftUI

final class ThemeState: ObservableObject {
    @Published var theme: AppTheme {
        didSet {
            UserDefaults.standard.set(theme.rawValue, forKey: "theme")
        }
    }

    @Published var keywordHighlights: [KeywordHighlight] = KeywordHighlight.defaults

    init() {
        let savedTheme = UserDefaults.standard.string(forKey: "theme") ?? "catppuccinMocha"
        theme = AppTheme(rawValue: savedTheme) ?? .catppuccinMocha
    }
}
