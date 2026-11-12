import Foundation

struct SftpTransferRequest: Encodable {
    let id: String
    let server_id: String
    let local_path: String
    let remote_path: String
    let upload: Bool
    let overwrite: Bool
}

enum SftpTransferError: LocalizedError {
    case conflict
    case cancelled
    case failed(String)
    var errorDescription: String? {
        switch self {
        case .conflict: return "目标文件已存在"
        case .cancelled: return "已取消"
        case .failed(let message): return message
        }
    }
}

protocol SftpTransferClient: AnyObject {
    func reserveSftpTransfer() throws -> String
    func cancelSftpTransfer(_ id: String)
    func runSftpTransfer(_ request: SftpTransferRequest, progress: @escaping (UInt64, UInt64) -> Void) throws
}

final class SftpTransferQueue: ObservableObject {
    enum Status: Equatable {
        case queued, running, cancelling, conflict, completed, cancelled, failed(String)
        var label: String {
            switch self {
            case .queued: return "等待中"
            case .running: return "传输中"
            case .cancelling: return "正在取消…"
            case .conflict: return "等待覆盖确认"
            case .completed: return "已完成"
            case .cancelled: return "已取消"
            case .failed(let message): return message
            }
        }
        var isFinished: Bool {
            switch self { case .completed, .cancelled, .failed: return true; default: return false }
        }
    }
    struct Item: Identifiable {
        let id = UUID()
        let localPath: String
        let remotePath: String
        let upload: Bool
        var overwrite = false
        var backendId: String?
        var transferred: UInt64 = 0
        var total: UInt64 = 0
        var status: Status = .queued
        var name: String { ((upload ? localPath : remotePath) as NSString).lastPathComponent }
        var destination: String { upload ? remotePath : localPath }
    }
    @Published private(set) var items: [Item] = []
    @Published private(set) var revision = 0
    private let serverId: String
    private let client: SftpTransferClient
    private var activeId: UUID?
    var activityChanged: ((Bool) -> Void)?

    init(serverId: String, client: SftpTransferClient = OrbitBridge.shared) {
        self.serverId = serverId
        self.client = client
    }

    func enqueue(local: String, remote: String, upload: Bool) {
        items.append(Item(localPath: local, remotePath: remote, upload: upload))
        advance()
    }

    func cancel(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if let backendId = items[index].backendId, activeId == id {
            items[index].status = .cancelling
            client.cancelSftpTransfer(backendId)
        } else if !items[index].status.isFinished {
            items[index].status = .cancelled
        }
    }

    func cancelAll() { items.map(\.id).forEach(cancel) }

    func retry(_ id: UUID, overwrite: Bool = false) {
        guard let index = items.firstIndex(where: { $0.id == id }), activeId != id else { return }
        guard items[index].status.isFinished || items[index].status == .conflict else { return }
        items[index].overwrite = overwrite
        items[index].backendId = nil
        items[index].transferred = 0
        items[index].status = .queued
        advance()
    }

    func clearFinished() { items.removeAll { $0.status.isFinished } }

    private func advance() {
        guard activeId == nil else { return }
        guard let index = items.firstIndex(where: { $0.status == .queued }) else {
            activityChanged?(false)
            return
        }
        let id = items[index].id
        do {
            let backendId = try client.reserveSftpTransfer()
            items[index].backendId = backendId
            items[index].status = .running
            activeId = id
            activityChanged?(true)
            let item = items[index]
            let request = SftpTransferRequest(id: backendId, server_id: serverId, local_path: item.localPath,
                                              remote_path: item.remotePath, upload: item.upload, overwrite: item.overwrite)
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let result = Result {
                    try client.runSftpTransfer(request) { done, total in
                        DispatchQueue.main.async { [self] in
                            guard let index = items.firstIndex(where: { $0.id == id && $0.backendId == backendId }),
                                  activeId == id else { return }
                            items[index].transferred = done
                            items[index].total = total
                        }
                    }
                }
                DispatchQueue.main.async { [self] in
                    guard let index = items.firstIndex(where: { $0.id == id }) else { return }
                    switch result {
                    case .success:
                        items[index].status = .completed
                        revision += 1
                    case .failure(SftpTransferError.conflict): items[index].status = .conflict
                    case .failure(SftpTransferError.cancelled): items[index].status = .cancelled
                    case .failure(let error): items[index].status = .failed(error.localizedDescription)
                    }
                    items[index].backendId = nil
                    activeId = nil
                    advance()
                }
            }
        } catch {
            items[index].status = .failed(error.localizedDescription)
            advance()
        }
    }
}
