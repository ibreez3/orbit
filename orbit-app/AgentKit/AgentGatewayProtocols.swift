import Foundation

public protocol AgentGatewayCalling {
    func hello(_ hello: AgentHello) throws -> AgentAdmissionResult
    func approvalStatus(requestId: String) throws -> AgentApprovalStatus
    func call(tool: String, args: AgentJSONValue, session: AgentSessionCredential) throws -> AgentJSONValue
    func revoke(_ session: AgentSessionCredential) throws
}
