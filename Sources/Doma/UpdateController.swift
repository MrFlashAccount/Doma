import Combine
import Foundation
import Sparkle

@MainActor
final class UpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var availableVersion: String?
    @Published private(set) var isCheckingForUpdates = false

    private var updaterController: SPUStandardUpdaterController?
    private var lastProbeAt: Date?

    init(startingUpdater: Bool = true) {
        super.init()

        let controller = SPUStandardUpdaterController(
            startingUpdater: startingUpdater,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        updaterController = controller
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    func performPrimaryAction() {
        updaterController?.checkForUpdates(nil)
    }

    func checkForUpdatesSilentlyIfNeeded(now: Date = Date()) {
        guard let updater = updaterController?.updater,
              canCheckForUpdates,
              !updater.sessionInProgress,
              lastProbeAt.map({ now.timeIntervalSince($0) >= 60 * 60 }) ?? true else {
            return
        }

        lastProbeAt = now
        isCheckingForUpdates = true
        updater.checkForUpdateInformation()
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        availableVersion = item.displayVersionString
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        availableVersion = nil
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: Error?
    ) {
        isCheckingForUpdates = false
    }
}
