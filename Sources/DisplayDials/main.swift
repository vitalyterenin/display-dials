import AppKit
import DisplayCore
import NightShiftBridge

enum AppIdentity {
    static let name = "Display Dials"
    static let version = "0.1.0"
}

@MainActor
func displaySnapshot() -> [[String: Any]] {
    NSScreen.screens.map { screen in
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        return ["name": screen.localizedName,
                "builtIn": CGDisplayIsBuiltin(id) != 0,
                "currentEDR": screen.maximumExtendedDynamicRangeColorComponentValue,
                "potentialEDR": screen.maximumPotentialExtendedDynamicRangeColorComponentValue]
    }
}

@MainActor
final class PanelController: NSViewController {
    let warmth = DDWarmthClient()
    private let screenLabel = NSTextField(wrappingLabelWithString: "")
    private let warmthToggle = NSSwitch()
    private let warmthSlider = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let warmthValue = NSTextField(labelWithString: "—")
    private let warmthNote = NSTextField(wrappingLabelWithString: "")
    private let boostNote = NSTextField(wrappingLabelWithString: "")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private var timer: Timer?

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 460))
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -18)
        ])
        let title = NSTextField(labelWithString: AppIdentity.name)
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        stack.addArrangedSubview(title)
        screenLabel.font = .systemFont(ofSize: 11)
        screenLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(screenLabel)
        stack.addArrangedSubview(separator())

        let boostSwitch = NSSwitch()
        boostSwitch.isEnabled = false
        boostSwitch.setAccessibilityLabel("Буст яркости — в разработке")
        stack.addArrangedSubview(row("Буст яркости", control: boostSwitch))
        let boostSlider = NSSlider(value: 1, minValue: 1, maxValue: 1.25, target: nil, action: nil)
        boostSlider.isEnabled = false
        boostSlider.setAccessibilityLabel("Усиление яркости — недоступно в этой сборке")
        stack.addArrangedSubview(boostSlider)
        boostNote.font = .systemFont(ofSize: 11)
        boostNote.textColor = .secondaryLabelColor
        stack.addArrangedSubview(boostNote)
        stack.addArrangedSubview(separator())

        warmthToggle.target = self
        warmthToggle.action = #selector(toggleWarmth)
        warmthToggle.setAccessibilityLabel("Night Shift")
        stack.addArrangedSubview(row("Теплота · Night Shift", control: warmthToggle))
        warmthSlider.target = self
        warmthSlider.action = #selector(changeWarmth)
        // Commit once on release, not on every pixel while dragging.
        warmthSlider.isContinuous = false
        warmthSlider.setAccessibilityLabel("Теплота экрана")
        stack.addArrangedSubview(warmthSlider)
        stack.addArrangedSubview(row("Холоднее → теплее", control: warmthValue))
        warmthNote.font = .systemFont(ofSize: 11)
        warmthNote.textColor = .secondaryLabelColor
        stack.addArrangedSubview(warmthNote)
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true
        stack.addArrangedSubview(errorLabel)
        stack.addArrangedSubview(separator())

        let quit = NSButton(title: "Выйти", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        quit.bezelStyle = .rounded
        stack.addArrangedSubview(row("Прототип \(AppIdentity.version)", control: quit))
        for item in stack.arrangedSubviews {
            item.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        refresh()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let screen = displaySnapshot().first { ($0["builtIn"] as? Bool) == true }
        screenLabel.stringValue = screen?["name"] as? String ?? "Встроенный экран не найден"
        let headroom = screen?["currentEDR"] as? Double ?? 1
        let thermal: BoostPolicy.Thermal
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = .nominal
        case .fair: thermal = .fair
        case .serious: thermal = .serious
        case .critical: thermal = .critical
        @unknown default: thermal = .unknown
        }
        let gate = BoostPolicy().evaluate(requested: 1.25, enabled: true, rendererValidated: false,
                                         builtIn: screen != nil, awake: true, thermal: thermal,
                                         currentHeadroom: headroom)
        let status: String
        switch gate.block {
        case .thermalPressure: status = "Нагрузка на систему повышена."
        case .unsupportedDisplay: status = "Нужен поддерживаемый встроенный экран."
        default: status = "Модуль усиления ещё не подключён."
        }
        boostNote.stringValue = "Буст недоступен в этой сборке. \(status)"

        let state = warmth.readState()
        let available = state?["available"]?.boolValue == true
        warmthToggle.isEnabled = available
        warmthToggle.state = state?["enabled"]?.boolValue == true ? .on : .off
        warmthSlider.isEnabled = available && warmthToggle.state == .on
        if let value = state?["strength"]?.doubleValue {
            warmthSlider.doubleValue = value
            warmthValue.stringValue = "\(Int((value * 100).rounded()))%"
        } else {
            warmthValue.stringValue = "—"
        }
        warmthNote.stringValue = available
            ? "Используется системный Night Shift. Расписание macOS сохраняется."
            : "Night Shift недоступен. \(warmth.diagnostic)."
    }

    @objc private func toggleWarmth() {
        let ok = warmth.changeEnabled(warmthToggle.state == .on)
        report(ok)
    }

    @objc private func changeWarmth() {
        report(warmth.changeStrength(warmthSlider.floatValue))
    }

    private func report(_ success: Bool) {
        errorLabel.stringValue = success ? "" : "macOS не применила настройку. Попробуйте ещё раз."
        errorLabel.isHidden = success
        refresh()
    }

    private func row(_ text: String, control: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [label, spacer, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        return row
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
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
        popover.contentSize = NSSize(width: 340, height: 460)
        popover.behavior = .transient
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = status.button {
            button.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: AppIdentity.name)
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
            togglePanel()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !popover.isShown { togglePanel() }
        return false
    }

    @objc private func togglePanel() {
        guard let button = status.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

let app = NSApplication.shared
if CommandLine.arguments.contains("--diagnostics") {
    let warmth = DDWarmthClient()
    let result: [String: Any] = [
        "app": AppIdentity.name,
        "version": AppIdentity.version,
        "boostRenderer": "not implemented; no brightness writes",
        "screens": displaySnapshot(),
        "nightShiftSupported": warmth.supported,
        "nightShiftDiagnostic": warmth.diagnostic,
        "nightShiftState": warmth.readState() ?? [:],
        "thermalState": ProcessInfo.processInfo.thermalState.rawValue
    ]
    let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
} else {
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
