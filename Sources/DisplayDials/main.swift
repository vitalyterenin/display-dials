import AppKit
import NightShiftBridge
import UsageTelemetry

enum AppIdentity {
    static let name = "Display Dials"
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
    }
}

@MainActor
final class PanelController: NSViewController, NSMenuDelegate {
    static let size = NSSize(width: 288, height: 116)
    let warmth = DDWarmthClient()
    let updates = UpdateController()
    let telemetry = UsageTelemetry(
        appID: Bundle.main.object(forInfoDictionaryKey: "TelemetryDeckAppID") as? String,
        version: AppIdentity.version,
        build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Development",
        runtimeAllowed: Bundle.main.bundleURL.pathExtension == "app"
            && !CommandLine.arguments.contains("--smoke-test")
            && !CommandLine.arguments.contains("--diagnostics")
    )
    private var statisticsPreferences: StatisticsPreferences?
    private let warmthToggle = NSSwitch()
    private let warmthSlider = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private var settingError: String?
    private var timer: Timer?
    private var lastState: PanelState?

    private struct PanelState: Equatable {
        let available: Bool
        let enabled: Bool
        let strength: Double?
        let diagnostic: String
        let error: String?
    }

    override func loadView() {
        view = NSView(frame: NSRect(origin: .zero, size: Self.size))

        let title = NSTextField(labelWithString: "Night Shift")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let heading = NSStackView(views: [title, statusLabel])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 2
        heading.setContentHuggingPriority(.defaultLow, for: .horizontal)

        warmthToggle.target = self
        warmthToggle.action = #selector(toggleWarmth)
        warmthToggle.setAccessibilityLabel("Night Shift")
        warmthToggle.controlSize = .small

        let more = NSButton(image: NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "More options")!,
                            target: self, action: #selector(showOptions(_:)))
        more.isBordered = false
        more.imagePosition = .imageOnly
        more.toolTip = "More options"
        more.setAccessibilityLabel("More options")
        more.widthAnchor.constraint(equalToConstant: 24).isActive = true
        more.heightAnchor.constraint(equalToConstant: 24).isActive = true
        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [heading, headerSpacer, warmthToggle, more])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10

        warmthSlider.target = self
        warmthSlider.action = #selector(changeWarmth)
        warmthSlider.numberOfTickMarks = 10
        warmthSlider.allowsTickMarkValuesOnly = true
        // Commit once on release using the native slider's selectable positions.
        warmthSlider.isContinuous = false
        warmthSlider.setAccessibilityLabel("Display warmth")
        warmthSlider.toolTip = "Adjust display warmth. The macOS Night Shift schedule is preserved."

        let cooler = NSTextField(labelWithString: "Cooler")
        let warmer = NSTextField(labelWithString: "Warmer")
        for label in [cooler, warmer] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let endpoints = NSStackView(views: [cooler, spacer, warmer])
        endpoints.orientation = .horizontal

        let stack = NSStackView(views: [header, warmthSlider, endpoints])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -16)
        ])
        for item in stack.arrangedSubviews {
            item.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        refresh()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
        // Only poll while visible. User actions and reopening refresh immediately.
        timer?.invalidate()
        let poll = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            // Installed on the main run loop; no additional task needs scheduling.
            MainActor.assumeIsolated {
                guard let self, self.timer != nil else { return }
                self.refresh()
            }
        }
        poll.tolerance = 1
        timer = poll
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let state = warmth.readState()
        let available = state?["available"]?.boolValue == true
        let enabled = state?["enabled"]?.boolValue == true
        let strength = state?["strength"]?.doubleValue
        let current = PanelState(available: available, enabled: enabled, strength: strength,
                                 diagnostic: warmth.diagnostic, error: settingError)
        guard current != lastState else { return }
        lastState = current
        warmthToggle.isEnabled = available
        warmthToggle.state = enabled ? .on : .off
        warmthSlider.isEnabled = available && enabled
        if let strength {
            // Reading system state must never round or commit a setting.
            warmthSlider.doubleValue = strength
        }
        statusLabel.textColor = settingError == nil ? .secondaryLabelColor : .systemRed
        if let settingError {
            statusLabel.stringValue = settingError
        } else if !available {
            statusLabel.stringValue = "Unavailable"
        } else if enabled, let strength {
            statusLabel.stringValue = "On · \(Int((strength * 100).rounded()))%"
        } else {
            statusLabel.stringValue = "Off"
        }
        statusLabel.toolTip = settingError ?? (available
            ? "The macOS Night Shift schedule is preserved."
            : warmth.diagnostic)
    }

    @objc private func showOptions(_ sender: NSButton) {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        let version = menu.addItem(withTitle: "\(AppIdentity.name) · Version \(AppIdentity.version)", action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(.separator())
        let check = menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        check.target = self
        check.isEnabled = updates.canCheck
        let automaticChecks = menu.addItem(withTitle: "Check for Updates Automatically", action: #selector(changeAutomaticChecks(_:)), keyEquivalent: "")
        automaticChecks.target = self
        automaticChecks.isEnabled = updates.isConfigured
        automaticChecks.state = updates.automaticallyChecks ? .on : .off
        let automaticInstallation = menu.addItem(withTitle: "Install Updates Automatically", action: #selector(changeAutomaticInstallation(_:)), keyEquivalent: "")
        automaticInstallation.target = self
        automaticInstallation.isEnabled = updates.isConfigured && updates.automaticallyChecks
        automaticInstallation.state = updates.automaticallyInstalls ? .on : .off
        menu.addItem(.separator())
        let statistics = menu.addItem(withTitle: "Usage Statistics…", action: #selector(showStatistics), keyEquivalent: "")
        statistics.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit Display Dials", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY - 4), in: sender)
    }

    func confinementRect(for menu: NSMenu, on screen: NSScreen?) -> NSRect {
        // A menu opened from a popover must be allowed to use the full screen.
        screen?.visibleFrame ?? .zero
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        if updates.canCheck { telemetry.record(.manualUpdateCheck) }
        updates.check(sender)
    }

    @objc private func changeAutomaticChecks(_ sender: NSMenuItem) {
        updates.setAutomaticChecks(sender.state != .on)
        recordUpdatePreferences()
    }

    @objc private func changeAutomaticInstallation(_ sender: NSMenuItem) {
        updates.setAutomaticInstallation(sender.state != .on)
        recordUpdatePreferences()
    }

    func recordUpdatePreferences() {
        telemetry.record(.updatePreferences(checks: updates.automaticallyChecks, installation: updates.automaticallyInstalls))
    }

    @objc func showStatistics() {
        if let existing = statisticsPreferences, existing.window?.isVisible == true { existing.present(); return }
        statisticsPreferences = StatisticsPreferences(telemetry: telemetry) { [weak self] in self?.recordUpdatePreferences() }
        statisticsPreferences?.present()
    }

    @objc private func toggleWarmth() {
        let enabled = warmthToggle.state == .on
        let success = warmth.changeEnabled(enabled)
        telemetry.record(.nightShiftChanged(enabled: enabled, succeeded: success))
        report(success)
    }

    @objc private func changeWarmth() {
        let strength = Float(warmthSlider.closestTickMarkValue(toValue: warmthSlider.doubleValue))
        let success = warmth.changeStrength(strength)
        telemetry.record(.warmthChanged(position: Int((strength * 9).rounded()) + 1, succeeded: success))
        report(success)
    }

    private func report(_ success: Bool) {
        settingError = success ? nil : "Could not apply setting. Try again."
        // Restore controls from macOS even if a repeated write failed identically.
        lastState = nil
        refresh()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var status: NSStatusItem!
    private let popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
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
            controller.updates.start()
            controller.telemetry.start()
            controller.recordUpdatePreferences()
            showPanel(source: .launch)
            if controller.telemetry.isConfigured && !controller.telemetry.hasChosen {
                popover.performClose(nil)
                controller.showStatistics()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !popover.isShown { showPanel(source: .reopen) }
        return false
    }

    @objc private func togglePanel() {
        if popover.isShown { popover.performClose(nil) }
        else { showPanel(source: .menuBar) }
    }

    private func showPanel(source: UsageEvent.PanelSource) {
        guard let button = status.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        (popover.contentViewController as? PanelController)?.telemetry.record(.panelOpened(source))
        NSApp.activate(ignoringOtherApps: true)
    }
}

let app = NSApplication.shared
if CommandLine.arguments.contains("--diagnostics") {
    let warmth = DDWarmthClient()
    let result: [String: Any] = [
        "app": AppIdentity.name,
        "version": AppIdentity.version,
        "nightShiftSupported": warmth.supported,
        "nightShiftDiagnostic": warmth.diagnostic,
        "nightShiftState": warmth.readState() ?? [:]
    ]
    let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
} else {
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
