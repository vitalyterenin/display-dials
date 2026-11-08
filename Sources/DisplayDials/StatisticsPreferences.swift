import AppKit
import UsageTelemetry

@MainActor
final class StatisticsPreferences: NSWindowController, NSWindowDelegate {
    private let telemetry: UsageTelemetry
    private let onEnable: () -> Void
    private let firstChoice: Bool

    init(telemetry: UsageTelemetry, onEnable: @escaping () -> Void) {
        self.telemetry = telemetry
        self.onEnable = onEnable
        firstChoice = !telemetry.hasChosen
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 470),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Usage Statistics"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildContents()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildContents() {
        guard let content = window?.contentView else { return }
        let title = NSTextField(labelWithString: "Help improve Display Dials")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        let introduction = label("Optionally share usage statistics with the developer through TelemetryDeck. All app features work without sharing.")
        let details = label("""
        What is sent
        • App launches and panel openings, including how the panel was opened.
        • Final slider positions (1–10, where 1 means Off), and whether changes succeeded.
        • Automatic-update preferences and manual update checks.
        • App version/build, macOS major/minor version, event times, and random installation/session identifiers. The installation identifier is hashed before sending.

        No names, email addresses, files, screen recordings, hardware identifiers, or location are collected. TelemetryDeck receives your IP address to deliver the request; it says it does not store it.

        You can turn sharing off here at any time. This clears unsent events and resets the local identifier; it does not remove data already received by TelemetryDeck.
        """)
        details.font = .systemFont(ofSize: 12)
        let privacy = NSButton(title: "TelemetryDeck Privacy & Storage…", target: self, action: #selector(openPrivacy))
        privacy.bezelStyle = .inline
        var views: [NSView] = [title, introduction, details, privacy]
        if !firstChoice {
            let checkbox = NSButton(checkboxWithTitle: "Share Usage Statistics", target: self, action: #selector(toggleSharing(_:)))
            checkbox.state = telemetry.isEnabled ? .on : .off
            checkbox.isEnabled = telemetry.isConfigured
            views.append(checkbox)
        }
        if !telemetry.isConfigured { views.append(label("Statistics are unavailable in this build.")) }
        let buttons: NSStackView
        if firstChoice {
            let decline = NSButton(title: "Don't Send", target: self, action: #selector(decline))
            let allow = NSButton(title: "Allow Statistics", target: self, action: #selector(allow))
            allow.isEnabled = telemetry.isConfigured
            decline.bezelStyle = .rounded
            allow.bezelStyle = .rounded
            buttons = NSStackView(views: [decline, allow])
        } else {
            let done = NSButton(title: "Done", target: self, action: #selector(done))
            done.bezelStyle = .rounded
            done.keyEquivalent = "\r"
            buttons = NSStackView(views: [done])
        }
        buttons.orientation = .horizontal
        buttons.spacing = 12
        views.append(buttons)
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24)
        ])
        for view in [introduction, details] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        content.layoutSubtreeIfNeeded()
        window?.setContentSize(NSSize(width: 480, height: stack.fittingSize.height + 48))
    }

    private func label(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 13)
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        return label
    }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func allow() {
        telemetry.setEnabled(true)
        onEnable()
        close()
    }
    @objc private func decline() { telemetry.setEnabled(false); close() }
    @objc private func done() { close() }
    @objc private func toggleSharing(_ sender: NSButton) {
        telemetry.setEnabled(sender.state == .on)
        if sender.state == .on { onEnable() }
    }
    @objc private func openPrivacy() {
        NSWorkspace.shared.open(URL(string: "https://telemetrydeck.com/docs/guides/privacy-faq/")!)
    }
    func windowWillClose(_ notification: Notification) {
        if firstChoice && !telemetry.hasChosen { telemetry.setEnabled(false) }
    }
}
