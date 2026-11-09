import AppKit

@MainActor
final class PanelController: NSViewController {
    static let size = NSSize(width: 288, height: 116)
    let warmth: any NightShiftControlling
    let updates = UpdateController()
    let loginItem = LoginItemController()
    let warmthSlider = WarmthSlider(frame: .zero)
    let statusLabel = NSTextField(labelWithString: "")
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

    init(warmth: any NightShiftControlling = NightShiftClient()) {
        self.warmth = warmth
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

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
        let header = NSStackView(views: [heading, headerSpacer, more])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10

        warmthSlider.target = self
        warmthSlider.action = #selector(changeWarmth)
        warmthSlider.onDragEnded = { [weak self] in
            self?.refresh(reconcileSlider: true)
        }
        warmthSlider.setAccessibilityLabel("Display warmth")
        warmthSlider.toolTip = "Move fully left to turn Night Shift off; choose a higher position to turn it on. The macOS schedule is preserved."

        let cooler = NSTextField(labelWithString: "Off")
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

    func refresh(reconcileSlider: Bool = false) {
        let snapshot = warmth.readSnapshot()
        let available = snapshot.available
        let enabled = snapshot.state?.enabled == true
        let strength = snapshot.state?.strength
        let current = PanelState(available: available, enabled: enabled, strength: strength,
                                 diagnostic: snapshot.diagnostic, error: settingError)
        let stateChanged = current != lastState
        // Native actions can move the knob even when the system state stays the same.
        if (stateChanged || reconcileSlider), !warmthSlider.isDragging, let strength {
            warmthSlider.doubleValue = WarmthAdjustment.sliderValue(enabled: enabled, strength: strength)
        }
        guard stateChanged else { return }
        lastState = current
        warmthSlider.isEnabled = available
        warmthSlider.allowsInitialOffAction = available && enabled
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
            : snapshot.diagnostic)
    }

    @objc private func showOptions(_ sender: NSButton) {
        OptionsMenuPresentation.popUp(makeOptionsMenu(), from: sender)
    }

    func makeOptionsMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let launch = menu.addItem(
            withTitle: loginItem.requiresApproval ? "Launch at Login (Approval Required)" : "Launch at Login",
            action: #selector(changeLaunchAtLogin(_:)), keyEquivalent: "")
        launch.target = self
        launch.isEnabled = loginItem.isAvailable && !loginItem.isChanging
        launch.state = loginItem.menuState
        launch.toolTip = loginItem.isAvailable
            ? "Start Display Dials in the menu bar when you sign in to macOS."
            : "Run an installed copy on a writable disk to change launch at login."
        if loginItem.requiresApproval {
            let settings = menu.addItem(withTitle: "Allow in System Settings…", action: #selector(openLoginItemSettings), keyEquivalent: "")
            settings.target = self
        }
        menu.addItem(.separator())
        let updatesItem = menu.addItem(withTitle: "Updates", action: nil, keyEquivalent: "")
        updatesItem.submenu = makeUpdatesMenu()
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit Display Dials", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        return menu
    }

    private func makeUpdatesMenu() -> NSMenu {
        let menu = NSMenu(title: "Updates")
        menu.autoenablesItems = false
        let check = menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        check.target = self
        check.isEnabled = updates.canCheck
        let automaticChecks = menu.addItem(withTitle: "Automatically Check for Updates", action: #selector(changeAutomaticChecks(_:)), keyEquivalent: "")
        automaticChecks.target = self
        automaticChecks.isEnabled = updates.isConfigured
        automaticChecks.state = updates.automaticallyChecks ? .on : .off
        let automaticInstallation = menu.addItem(withTitle: "Automatically Install Updates", action: #selector(changeAutomaticInstallation(_:)), keyEquivalent: "")
        automaticInstallation.target = self
        automaticInstallation.isEnabled = updates.isConfigured && updates.automaticallyChecks
        automaticInstallation.state = updates.automaticallyInstalls ? .on : .off
        menu.addItem(.separator())
        let version = menu.addItem(withTitle: "Version \(AppIdentity.version)", action: nil, keyEquivalent: "")
        version.isEnabled = false
        return menu
    }

    @objc private func changeLaunchAtLogin(_ sender: NSMenuItem) {
        let enable = sender.state == .off
        Task { @MainActor in
            do {
                try await loginItem.setEnabled(enable)
                if loginItem.requiresApproval {
                    let alert = NSAlert()
                    alert.messageText = "Allow Launch at Login"
                    alert.informativeText = "macOS needs your approval. Allow Display Dials in System Settings → General → Login Items & Extensions. You can also turn launch at login off from this menu."
                    alert.addButton(withTitle: "Open System Settings")
                    alert.addButton(withTitle: "Later")
                    NSApp.activate(ignoringOtherApps: true)
                    if alert.runModal() == .alertFirstButtonReturn { loginItem.openSettings() }
                }
            } catch {
                let alert = NSAlert()
                alert.messageText = "Could Not Change Launch at Login"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "OK")
                alert.addButton(withTitle: "Open System Settings")
                NSApp.activate(ignoringOtherApps: true)
                if alert.runModal() == .alertSecondButtonReturn { loginItem.openSettings() }
            }
        }
    }

    @objc private func openLoginItemSettings() { loginItem.openSettings() }

    @objc private func checkForUpdates(_ sender: Any?) {
        updates.check(sender)
    }

    @objc private func changeAutomaticChecks(_ sender: NSMenuItem) {
        updates.setAutomaticChecks(sender.state != .on)
    }

    @objc private func changeAutomaticInstallation(_ sender: NSMenuItem) {
        updates.setAutomaticInstallation(sender.state != .on)
    }

    @objc private func changeWarmth() {
        let strength = Float(warmthSlider.closestTickMarkValue(toValue: warmthSlider.doubleValue))
        let snapshot = warmth.readSnapshot()
        let success = snapshot.available && WarmthAdjustment.apply(
            strength: strength, enabled: snapshot.state?.enabled == true,
            setStrength: { self.warmth.changeStrength($0) },
            setEnabled: { self.warmth.changeEnabled($0) }
        )
        settingError = success ? nil : "Could not apply setting. Try again."
        refresh(reconcileSlider: true)
    }
}

