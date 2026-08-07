import SwiftUI

struct SidebarPresentation: Equatable {
    static let widthKey = "assetTreeWidth"
    static let collapsedKey = "assetTreeCollapsed"

    var collapsed: Bool
    var width: CGFloat

    init(collapsed: Bool = false, width: CGFloat = 240) {
        self.collapsed = collapsed
        self.width = Self.clampedWidth(width)
    }

    var displayWidth: CGFloat { collapsed ? 48 : width }

    static func clampedWidth(_ width: CGFloat) -> CGFloat {
        min(360, max(180, width))
    }

    static func restore(from defaults: UserDefaults = .standard) -> Self {
        let storedWidth = defaults.object(forKey: widthKey) == nil
            ? CGFloat(240)
            : CGFloat(defaults.double(forKey: widthKey))
        return .init(
            collapsed: defaults.bool(forKey: collapsedKey),
            width: storedWidth
        )
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(Double(width), forKey: Self.widthKey)
        defaults.set(collapsed, forKey: Self.collapsedKey)
    }
}

final class UIState: ObservableObject {
    @Published var spotlightOpen = false
    @Published var spotlightQuery = ""
    @Published var dialogOpen = false
    @Published var cgDialogOpen = false
    @Published var showQuitConfirmation = false
    @Published var pendingCloseTabId: String?
    @Published var assetTreeWidth: CGFloat
    @Published var assetTreeCollapsed: Bool
    @Published var assetTreeSearchQuery = ""
    @Published var selectedServerSystemView: ServerSystemView = .all
    @Published var recentServers: [String] = []
    @Published var alertMessage: String?
    @Published var alertTitle: String = ""
    @Published var serverQuickConnectQuery = ""
    @Published var serverQuickConnectResultsVisible = false
    @Published var serverQuickConnectInputFocused = false
    @Published var temporaryConnectionDraft: TemporaryConnectionDraft?
    var temporaryConnectionToken: UUID?

    init(defaults: UserDefaults = .standard) {
        let presentation = SidebarPresentation.restore(from: defaults)
        assetTreeWidth = presentation.width
        assetTreeCollapsed = presentation.collapsed
    }

    var showAlert: Binding<Bool> {
        Binding(get: { self.alertMessage != nil }, set: { if !$0 { self.alertMessage = nil } })
    }
}
