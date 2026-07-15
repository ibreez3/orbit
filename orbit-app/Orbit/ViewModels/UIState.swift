import SwiftUI

final class UIState: ObservableObject {
    @Published var spotlightOpen = false
    @Published var spotlightQuery = ""
    @Published var dialogOpen = false
    @Published var cgDialogOpen = false
    @Published var showQuitConfirmation = false
    @Published var pendingCloseTabId: String?
    @Published var assetTreeWidth: CGFloat = 220
    @Published var assetTreeSearchQuery = ""
    @Published var recentServers: [String] = []
    @Published var alertMessage: String?
    @Published var alertTitle: String = ""

    var showAlert: Binding<Bool> {
        Binding(get: { self.alertMessage != nil }, set: { if !$0 { self.alertMessage = nil } })
    }
}
