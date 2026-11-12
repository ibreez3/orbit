import AppKit

struct SSHHostKeyRequest: Decodable, Equatable {
    let id: String
    let host: String
    let port: UInt16
    let role: String
    let algorithm: String
    let fingerprint: String
    let previousFingerprint: String?

    enum CodingKeys: String, CodingKey {
        case id, host, port, role, algorithm, fingerprint
        case previousFingerprint = "previous_fingerprint"
    }

    var isChanged: Bool { previousFingerprint != nil }
    var endpoint: String { "[\(host)]:\(port)" }
    var roleLabel: String {
        switch role {
        case "jump": return "跳板机"
        case "target": return "目标服务器（经跳板机）"
        default: return "直连服务器"
        }
    }
    var details: String {
        var text = "\(roleLabel)：\(endpoint)\n公钥类型：\(algorithm)\n当前指纹：\(fingerprint)"
        if let previousFingerprint {
            text += "\n原指纹：\(previousFingerprint)\n\n服务器可能已重装或更换密钥，也可能连接到了其他主机。"
        }
        text += "\n\n请通过可信渠道向管理员核对指纹。当前连接已停止；保存信任后请手动重试，Orbit 不会自动重放操作。"
        return text
    }
}

@MainActor
final class SSHHostKeyVerification {
    static let shared = SSHHostKeyVerification(
        present: { SSHHostKeyVerification.presentAlert($0, run: { $0.runModal() }) },
        resolve: { id, trust in try OrbitBridge.shared.resolveHostKey(id: id, trust: trust) },
        reportError: { message in
            let alert = NSAlert()
            alert.messageText = "无法保存 SSH 主机信任"
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.addButton(withTitle: "确定")
            alert.runModal()
        }
    )

    private let present: (SSHHostKeyRequest) -> Bool
    private let resolve: (String, Bool) throws -> Void
    private let reportError: (String) -> Void
    private var queue: [SSHHostKeyRequest] = []
    private var seen: [String] = []
    private var isPresenting = false

    init(present: @escaping (SSHHostKeyRequest) -> Bool,
         resolve: @escaping (String, Bool) throws -> Void,
         reportError: @escaping (String) -> Void) {
        self.present = present
        self.resolve = resolve
        self.reportError = reportError
    }

    func enqueue(_ request: SSHHostKeyRequest) {
        guard !seen.contains(request.id) else { return }
        seen.append(request.id)
        if seen.count > 256 { seen.removeFirst() }
        queue.append(request)
        guard !isPresenting else { return }
        isPresenting = true
        defer { isPresenting = false }
        while !queue.isEmpty {
            let next = queue.removeFirst()
            let trust = present(next)
            do {
                try resolve(next.id, trust)
            } catch {
                reportError(error.localizedDescription)
            }
        }
    }

    static func presentAlert(
        _ request: SSHHostKeyRequest,
        run: (NSAlert) -> NSApplication.ModalResponse
    ) -> Bool {
        let alert = NSAlert()
        alert.messageText = request.isChanged ? "SSH 主机指纹已变化" : "首次连接此 SSH 主机"
        alert.informativeText = request.details
        alert.alertStyle = .warning
        alert.addButton(withTitle: "取消连接")
        alert.addButton(withTitle: request.isChanged ? "核对后更换指纹…" : "信任并保存")
        guard run(alert) == .alertSecondButtonReturn else { return false }
        guard request.isChanged else { return true }
        let confirmation = NSAlert()
        confirmation.messageText = "确认替换已保存的主机指纹？"
        confirmation.informativeText = request.details
        confirmation.alertStyle = .critical
        confirmation.addButton(withTitle: "取消")
        confirmation.addButton(withTitle: "已核对，替换指纹")
        return run(confirmation) == .alertSecondButtonReturn
    }
}
