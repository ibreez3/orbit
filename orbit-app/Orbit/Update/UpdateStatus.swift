import Foundation

struct AppVersion: Equatable {
    let shortVersion: String
    let build: String

    static var current: AppVersion {
        let info = Bundle.main.infoDictionary
        return AppVersion(
            shortVersion: info?["CFBundleShortVersionString"] as? String ?? "0.0.0",
            build: info?["CFBundleVersion"] as? String ?? "0"
        )
    }

    var displayText: String { "版本 \(shortVersion) (\(build))" }
}

struct AvailableUpdate: Equatable {
    let shortVersion: String
    let build: String
    let title: String
    let notes: String?
    let notesFormat: String?
    let fullNotesURL: URL?
    let releasePageURL: URL?

    var displayVersion: String { shortVersion.isEmpty ? build : shortVersion }
}

enum NoUpdateReason: Equatable {
    case latest
    case newerThanFeed
    case systemTooOld
    case systemTooNew
    case hardwareUnsupported
    case unknown
}

enum UpdateStatus: Equatable {
    case idle
    case checking
    case upToDate
    case updateAvailable(AvailableUpdate)
    case newerThanFeed(latest: AvailableUpdate?)
    case failed(String)
    case disabled
}

enum UpdateEvent: Equatable {
    case started
    case found(AvailableUpdate)
    case noUpdate(reason: NoUpdateReason, latest: AvailableUpdate?)
    case failure(String)
    case finished
}

enum UpdateStatusReducer {
    static func reduce(_ status: UpdateStatus, event: UpdateEvent) -> UpdateStatus {
        switch event {
        case .started:
            return .checking
        case .found(let update):
            return .updateAvailable(update)
        case .noUpdate(let reason, let latest):
            switch reason {
            case .latest: return .upToDate
            case .newerThanFeed: return .newerThanFeed(latest: latest)
            case .systemTooOld: return .failed("线上稳定版需要更高版本的 macOS")
            case .systemTooNew: return .failed("线上稳定版暂不支持当前 macOS 版本")
            case .hardwareUnsupported: return .failed("线上稳定版不支持当前硬件架构")
            case .unknown: return .upToDate
            }
        case .failure(let message):
            return .failed(message)
        case .finished:
            if case .checking = status { return .upToDate }
            return status
        }
    }
}

extension UpdateStatus {
    var statusText: String {
        switch self {
        case .idle: return "尚未检查更新"
        case .checking: return "正在检查更新…"
        case .upToDate: return "已是最新版本"
        case .updateAvailable(let update): return "发现新版本 \(update.displayVersion)"
        case .newerThanFeed(let latest):
            if let latest { return "当前版本高于线上稳定版（线上：\(latest.displayVersion)）" }
            return "当前版本高于线上稳定版"
        case .failed(let message): return "检查更新失败：\(message)"
        case .disabled: return "更新检查已在测试模式下禁用"
        }
    }
}
