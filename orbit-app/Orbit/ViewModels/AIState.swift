import Foundation

final class AIState: ObservableObject {
    @Published var aiConfig: AIConfig = .defaults
    @Published var aiSessions: [String: [AISession]] = [:]
    @Published var activeAISessionId: [String: String] = [:]
    @Published var aiLoading = false
    @Published var aiPanelWidth: CGFloat = 280
    @Published var aiPendingConfirmation: PendingAICommand?
    @Published var databaseAIContexts: [String: DatabaseAIContext] = [:]
    @Published var auditEventsByContext: [String: [AuditEvent]] = [:]
}
