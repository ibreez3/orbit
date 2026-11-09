import AgentKit
import AppKit
import SwiftUI

final class AgentApprovalController: NSObject, AgentApprovalPresenting {
    static let shared = AgentApprovalController()

    private enum Kind {
        case admission(AgentAdmissionRequest)
        case write(AgentWriteRequest)
    }

    private struct Pending {
        let id: String
        let kind: Kind
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var queue: [Pending] = []
    private var active: Pending?
    private var panel: NSPanel?
    private var timeoutWorkItem: DispatchWorkItem?

    func requestAdmission(_ request: AgentAdmissionRequest) async -> Bool {
        await enqueue(requestId: request.requestId, kind: .admission(request))
    }

    func requestWrite(_ request: AgentWriteRequest) async -> Bool {
        await enqueue(requestId: request.requestId, kind: .write(request))
    }

    private func enqueue(requestId: String, kind: Kind) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                self.queue.append(Pending(id: requestId, kind: kind, continuation: continuation))
                self.showNextIfNeeded()
            }
        }
    }

    private func showNextIfNeeded() {
        guard active == nil, !queue.isEmpty else { return }
        let pending = queue.removeFirst()
        active = pending

        let view: AgentApprovalView
        let title: String
        let message: String
        let details: String
        let allowTitle: String

        switch pending.kind {
        case .admission(let request):
            title = "AI Agent 请求接入 Orbit"
            message = "允许 \(request.agentName) 使用 Orbit 的服务器执行能力？"
            details = """
            Agent: \(request.agentName)
            Client: \(request.clientVersion.isEmpty ? "unknown" : request.clientVersion)
            Parent: \(request.parentPath.isEmpty ? "unknown" : request.parentPath) [\(request.parentPid)]
            """
            allowTitle = "允许"
        case .write(let request):
            title = "AI 请求写权限"
            message = "允许本会话在 \(request.serverName) 上的写操作？"
            details = """
            Agent: \(request.agentName)
            Server: \(request.serverName) (\(request.serverId))
            Command:
            \(request.command)
            """
            allowTitle = "允许本会话写操作"
        }

        view = AgentApprovalView(
            title: title,
            message: message,
            details: details,
            allowTitle: allowTitle,
            onAllow: { [weak self] in self?.resolve(true) },
            onDeny: { [weak self] in self?.resolve(false) }
        )

        let panel = NSPanel(contentViewController: NSHostingController(rootView: view))
        panel.title = title
        panel.styleMask = [.titled]
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.center()
        self.panel = panel

        let workItem = DispatchWorkItem { [weak self] in
            self?.resolve(false)
        }
        timeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: workItem)

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func resolve(_ allowed: Bool) {
        guard let pending = active else { return }
        active = nil
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        panel?.close()
        panel = nil
        pending.continuation.resume(returning: allowed)
        showNextIfNeeded()
    }
}
