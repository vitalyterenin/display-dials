import AppKit
import DisplayCore
import NightShiftBridge
import Darwin

enum AppIdentity {
    static let name = "Display Dials"
    static let version = "0.2.0"
}

@MainActor
func displaySnapshot() -> [[String: Any]] {
    NSScreen.screens.map { screen in
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        return ["name": screen.localizedName,
                "builtIn": CGDisplayIsBuiltin(id) != 0,
                "currentEDR": screen.maximumExtendedDynamicRangeColorComponentValue,
                "potentialEDR": screen.maximumPotentialExtendedDynamicRangeColorComponentValue,
                "brightnessReadback": BrightnessReadback.values(for: id)]
    }
}

@MainActor
final class PanelController: NSViewController {
    let warmth = DDWarmthClient()
    let boost = BoostController()
    private let boostSwitch = NSSwitch()
    private let boostSlider = NSSlider(value: 1.1, minValue: 1, maxValue: 1.25, target: nil, action: nil)
    private let boostValue = NSTextField(labelWithString: "×1.10")
    private let screenLabel = NSTextField(wrappingLabelWithString: "")
    private let warmthToggle = NSSwitch()
    private let warmthSlider = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let warmthValue = NSTextField(labelWithString: "—")
    private let warmthNote = NSTextField(wrappingLabelWithString: "")
    private let boostNote = NSTextField(wrappingLabelWithString: "")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private var timer: Timer?

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 500))
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

        boostSwitch.target = self
        boostSwitch.action = #selector(toggleBoost)
        boostSwitch.setAccessibilityLabel("Буст яркости — тест на 30 секунд")
        stack.addArrangedSubview(row("Буст · эксперимент", control: boostSwitch))
        boostSlider.target = self
        boostSlider.action = #selector(changeBoost)
        boostSlider.isContinuous = false
        boostSlider.setAccessibilityLabel("Коэффициент усиления яркости")
        stack.addArrangedSubview(boostSlider)
        stack.addArrangedSubview(row("Усиление", control: boostValue))
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
        boost.onChange = { [weak self] in self?.refreshBoost() }
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
        refreshBoost()

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

    private func refreshBoost() {
        let running = boost.running
        let available = boost.unavailableReason
        boostSwitch.state = running && boost.report.phase != "off" ? .on : .off
        boostSwitch.isEnabled = running || available == nil
        boostSlider.isEnabled = running || available == nil
        if boost.report.phase == "active" {
            boostValue.stringValue = String(format: "×%.2f · %d с", boost.report.factor, boost.report.remaining)
            boostNote.stringValue = "Тест работает. Выключится автоматически. Коэффициент не является измерением яркости в нитах."
        } else if boost.report.phase == "preparing" && running {
            boostValue.stringValue = "Подготовка…"
            boostNote.stringValue = "Ожидаем доступную HDR-яркость. Переключатель останавливает тест."
        } else {
            boostValue.stringValue = String(format: "×%.2f", boost.factor)
            boostNote.stringValue = available ?? (boost.report.reason == nil || boost.report.reason == "manual"
                ? "Тест на 30 секунд. Повышает нагрев и расход энергии."
                : BoostPlatform.reason(boost.report.reason))
        }
    }

    @objc private func toggleBoost() {
        if boostSwitch.state == .on { boost.start(); boostSlider.doubleValue = boost.factor }
        else { boost.stop() }
        refreshBoost()
    }

    @objc private func changeBoost() {
        boost.changeFactor(boostSlider.doubleValue)
        refreshBoost()
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
    private var panel: PanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let controller = PanelController()
        panel = controller
        popover.contentViewController = controller
        popover.contentSize = NSSize(width: 340, height: 500)
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

    func applicationWillTerminate(_ notification: Notification) {
        panel?.boost.stop()
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
if CommandLine.arguments.contains("--boost-worker") {
    let worker = BoostWorker()
    worker.run()
    withExtendedLifetime(worker) { app.run() }
} else if CommandLine.arguments.contains("--renderer-check") {
    let data = try JSONSerialization.data(withJSONObject: HDRRenderer.offscreenCheck(), options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
} else if CommandLine.arguments.contains("--controller-check") {
    // Integration check of the UI controller/IPC path with only a tiny HDR marker.
    app.setActivationPolicy(.prohibited)
    let controller = BoostController(triggerOnly: true)
    var observedActive = false
    controller.onChange = {
        if controller.report.phase == "active" { observedActive = true }
        if !controller.running {
            let passed = observedActive && controller.report.phase == "off" && controller.report.reason == "manual"
            print("Controller start/stop: \(passed ? "PASS" : "FAIL")")
            exit(passed ? 0 : 1)
        }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { controller.stop() }
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 8) { _exit(74) }
    controller.start()
    withExtendedLifetime(controller) { app.run() }
} else if CommandLine.arguments.contains("--diagnostics") {
    let warmth = DDWarmthClient()
    let result: [String: Any] = [
        "app": AppIdentity.name,
        "version": AppIdentity.version,
        "boostRenderer": "experimental Metal overlay; 30 second worker lease",
        "conflictingApps": BoostPlatform.conflictingApps,
        "sessionActive": BoostPlatform.sessionActive,
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
