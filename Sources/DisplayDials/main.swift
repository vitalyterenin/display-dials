import AppKit

enum AppIdentity {
    static let name = "Display Dials"
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var status: NSStatusItem!
    private let popover = NSPopover()
    private let runtimeStatus = RuntimeStatus()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let launchedAtLogin = LoginItemController.wasLaunchedAtLogin
        NSApp.setActivationPolicy(.accessory)
        let controller = PanelController()
        popover.contentViewController = controller
        popover.contentSize = PanelController.size
        popover.behavior = .transient
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = status.button {
            button.image = NSImage(systemSymbolName: "sun.max", accessibilityDescription: "Display warmth")
            button.image?.isTemplate = true
            button.toolTip = AppIdentity.name
            button.target = self
            button.action = #selector(togglePanel)
        }
        if CommandLine.arguments.contains("--smoke-test") {
            _ = controller.view
            controller.refresh()
            if let index = CommandLine.arguments.firstIndex(of: "--snapshot"),
               CommandLine.arguments.indices.contains(index + 1) {
                let view = controller.view
                view.wantsLayer = true
                view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
                view.layoutSubtreeIfNeeded()
                if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    if let png = bitmap.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
                    }
                }
            }
            print("Display Dials: UI initialized; no display settings changed.")
            NSApp.terminate(nil)
        } else {
            runtimeStatus.start { [weak controller] in
                guard let controller else { return [:] }
                let snapshot = controller.warmth.readSnapshot()
                return [
                    "version": AppIdentity.version,
                    "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Development",
                    "nightShiftSupported": snapshot.supported,
                    "nightShiftState": snapshot.stateJSON,
                    "loginItemStatus": controller.loginItem.status.rawValue,
                    "loginItemEnabled": controller.loginItem.status == .enabled,
                    "loginItemRequiresApproval": controller.loginItem.requiresApproval,
                    "appearanceShortcutRegistered": controller.appearanceShortcut.isRegistered,
                    "appearanceShortcutError": controller.appearanceShortcut.registrationError.map(String.init) ?? "",
                    "appearanceChangeInProgress": controller.appearance.isChanging,
                    "appearanceError": controller.appearance.lastError ?? "",
                    "automaticChecks": controller.updates.automaticallyChecks,
                    "automaticInstallation": controller.updates.automaticallyInstalls
                ]
            }
            controller.updates.start()
            controller.registerAppearanceShortcut()
            if !launchedAtLogin { showPanel() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        (popover.contentViewController as? PanelController)?.appearanceShortcut.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !popover.isShown { showPanel() }
        return false
    }

    @objc private func togglePanel() {
        if popover.isShown { popover.performClose(nil) }
        else { showPanel() }
    }

    private func showPanel() {
        guard let button = status.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }
}

if CommandLine.arguments.contains("--status") { exit(RuntimeStatus.query() ? 0 : 1) }

let app = NSApplication.shared
if CommandLine.arguments.contains("--diagnostics") {
    let snapshot = NightShiftClient().readSnapshot()
    let result: [String: Any] = [
        "app": AppIdentity.name,
        "version": AppIdentity.version,
        "nightShiftSupported": snapshot.supported,
        "nightShiftDiagnostic": snapshot.diagnostic,
        "nightShiftState": snapshot.stateJSON
    ]
    let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
} else {
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
