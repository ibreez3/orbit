import Foundation

final class TabState: ObservableObject {
    @Published var tabs: [TabItem] = []
    @Published var activeTabId: String?
    @Published var activeTabError: String?
    @Published var temporaryDrafts: [String: TemporaryConnectionDraft] = [:]
    @Published var temporaryPromotionFailures: [String: TemporaryPromotionFailure] = [:]
    var temporaryTabTokens: [String: UUID] = [:]
    var temporaryPromotionTabIds: Set<String> = []

    var activeTab: TabItem? {
        guard let activeTabId else { return nil }
        return tabs.first { $0.id == activeTabId }
    }

    func tab(id: String) -> TabItem? {
        tabs.first { $0.id == id }
    }
}
