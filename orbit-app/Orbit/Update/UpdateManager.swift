import Foundation
import Combine
import Sparkle

@MainActor
final class UpdateManager: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = UpdateManager()

    @Published private(set) var status: UpdateStatus = .idle
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = true
    @Published private(set) var lastCheckDate: Date?
    @Published private(set) var isInstallingUpdate = false
    @Published private(set) var currentVersion = AppVersion.current

    let isDisabledForTesting: Bool

    private var hasStarted = false
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: nil
    )
    private var updater: SPUUpdater { updaterController.updater }

    private override init() {
        isDisabledForTesting =
            ProcessInfo.processInfo.environment["ORBIT_DISABLE_UPDATE_CHECKS"] == "1"
        super.init()
        if isDisabledForTesting { status = .disabled }
    }

    func startAtLaunch() {
        guard !isDisabledForTesting, !hasStarted else { return }
        hasStarted = true
        updaterController.startUpdater()
        refreshFromUpdater()
        guard updater.automaticallyChecksForUpdates, updater.canCheckForUpdates else { return }
        status = .checking
        updater.checkForUpdatesInBackground()
        refreshFromUpdater()
    }

    func checkForUpdates() {
        guard canPerformCheck else { return }
        if !updater.sessionInProgress { status = .checking }
        updater.checkForUpdates()
        refreshFromUpdater()
    }

    func checkForUpdateInformation() {
        guard canPerformCheck, !updater.sessionInProgress else { return }
        status = .checking
        updater.checkForUpdateInformation()
        refreshFromUpdater()
    }

    func setAutomaticallyChecksForUpdates(_ value: Bool) {
        guard !isDisabledForTesting else { return }
        automaticallyChecksForUpdates = value
        updater.automaticallyChecksForUpdates = value
        refreshFromUpdater()
    }

    func refreshFromUpdater() {
        guard !isDisabledForTesting, hasStarted else { return }
        canCheckForUpdates = updater.canCheckForUpdates
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        lastCheckDate = updater.lastUpdateCheckDate
        currentVersion = .current
    }

    private var canPerformCheck: Bool {
        !isDisabledForTesting && hasStarted && updater.canCheckForUpdates
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        status = .updateAvailable(AvailableUpdate(item: item))
        refreshFromUpdater()
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        let nsError = error as NSError
        let latest = (nsError.userInfo[SPULatestAppcastItemFoundKey] as? SUAppcastItem)
            .map(AvailableUpdate.init(item:))
        status = UpdateStatusReducer.reduce(
            status,
            event: .noUpdate(reason: NoUpdateReason(userInfo: nsError.userInfo), latest: latest)
        )
        refreshFromUpdater()
    }

    func updater(_ updater: SPUUpdater,
                 didFinishUpdateCycleFor check: SPUUpdateCheck,
                 error: Error?) {
        if let error {
            let nsError = error as NSError
            if !Self.isExpectedCycleEnd(nsError) {
                status = .failed(error.localizedDescription)
            } else if case .checking = status {
                status = .idle
            }
        } else if case .checking = status {
            status = .upToDate
        }
        refreshFromUpdater()
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let nsError = error as NSError
        isInstallingUpdate = false
        if !Self.isExpectedCycleEnd(nsError) {
            status = .failed(error.localizedDescription)
        }
        refreshFromUpdater()
    }

    static func isExpectedCycleEnd(_ error: NSError) -> Bool {
        error.domain == SUSparkleErrorDomain && (
            error.code == SUError.noUpdateError.rawValue
                || error.code == SUError.installationCanceledError.rawValue
        )
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        isInstallingUpdate = true
    }
}

private extension AvailableUpdate {
    init(item: SUAppcastItem) {
        self.init(
            shortVersion: item.displayVersionString,
            build: item.versionString,
            title: item.title ?? "",
            notes: item.itemDescription,
            notesFormat: item.itemDescriptionFormat,
            fullNotesURL: item.fullReleaseNotesURL,
            releasePageURL: item.infoURL
        )
    }
}

private extension NoUpdateReason {
    init(userInfo: [String: Any]) {
        let raw = (userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber)?.int32Value
        switch raw {
        case SPUNoUpdateFoundReason.onLatestVersion.rawValue:
            self = .latest
        case SPUNoUpdateFoundReason.onNewerThanLatestVersion.rawValue:
            self = .newerThanFeed
        case SPUNoUpdateFoundReason.systemIsTooOld.rawValue:
            self = .systemTooOld
        case SPUNoUpdateFoundReason.systemIsTooNew.rawValue:
            self = .systemTooNew
        case SPUNoUpdateFoundReason.hardwareDoesNotSupportARM64.rawValue:
            self = .hardwareUnsupported
        default:
            self = .unknown
        }
    }
}
