import Foundation

final class TabState: ObservableObject {
    @Published var tabs: [TabItem] = []
    @Published var activeTabId: String?
    @Published var activeTabError: String?

    var activeTab: TabItem? {
        guard let activeTabId else { return nil }
        return tabs.first { $0.id == activeTabId }
    }
}
