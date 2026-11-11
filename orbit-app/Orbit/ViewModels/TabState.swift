import Foundation

struct ActiveTabError: Equatable {
    let tabId: String
    let sessionId: String
    let message: String
    let generation: UUID
}

final class TabState: ObservableObject {
    @Published var tabs: [TabItem] = []
    @Published var activeTabId: String?
    @Published var activeTabError: ActiveTabError?
    @Published var temporaryDrafts: [String: TemporaryConnectionDraft] = [:]
    @Published var temporaryPromotionFailures: [String: TemporaryPromotionFailure] = [:]
    var temporaryTabTokens: [String: UUID] = [:]
    var temporaryPromotionTabIds: Set<String> = []

    var visibleActiveTabError: ActiveTabError? {
        guard let error = activeTabError, let tab = activeTab,
              error.tabId == tab.id, error.sessionId == (tab.focusedChannelId ?? tab.sessionId) else { return nil }
        return error
    }

    var activeTab: TabItem? {
        guard let activeTabId else { return nil }
        return tabs.first { $0.id == activeTabId }
    }

    func tab(id: String) -> TabItem? {
        tabs.first { $0.id == id }
    }
}
