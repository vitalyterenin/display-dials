import AppKit
import Sparkle

@MainActor
final class UpdateController {
    private var controller: SPUStandardUpdaterController?

    var isConfigured: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
            && Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") is String
            && Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") is String
    }

    var canCheck: Bool { controller?.updater.canCheckForUpdates == true }
    var automaticallyChecks: Bool { controller?.updater.automaticallyChecksForUpdates == true }
    var automaticallyInstalls: Bool { controller?.updater.automaticallyDownloadsUpdates == true }

    func start() {
        guard isConfigured, controller == nil else { return }
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
        )
    }

    func check(_ sender: Any?) {
        guard canCheck else { return }
        controller?.checkForUpdates(sender)
    }

    func setAutomaticChecks(_ enabled: Bool) {
        controller?.updater.automaticallyChecksForUpdates = enabled
    }

    func setAutomaticInstallation(_ enabled: Bool) {
        controller?.updater.automaticallyDownloadsUpdates = enabled
    }
}
