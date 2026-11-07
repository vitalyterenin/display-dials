import AppKit
import ServiceManagement

@MainActor
final class LoginItemController {
    private(set) var isChanging = false

    var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
            && !CommandLine.arguments.contains("--diagnostics")
            && !CommandLine.arguments.contains("--smoke-test")
            && (try? Bundle.main.bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) == false
    }

    var status: SMAppService.Status { isAvailable ? SMAppService.mainApp.status : .notFound }

    var menuState: NSControl.StateValue {
        switch status {
        case .enabled: .on
        case .requiresApproval: .mixed
        default: .off
        }
    }

    var requiresApproval: Bool { status == .requiresApproval }

    func setEnabled(_ enabled: Bool) async throws {
        guard isAvailable, !isChanging else { return }
        isChanging = true
        defer { isChanging = false }
        let current = status
        if enabled {
            guard current != .enabled, current != .requiresApproval else { return }
            try SMAppService.mainApp.register()
        } else if current == .enabled || current == .requiresApproval {
            try await SMAppService.mainApp.unregister()
        }
    }

    func openSettings() { SMAppService.openSystemSettingsLoginItems() }

    /// Read this only while applicationDidFinishLaunching handles the launch event.
    static var wasLaunchedAtLogin: Bool {
        let event = NSAppleEventManager.shared().currentAppleEvent
        return event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}
