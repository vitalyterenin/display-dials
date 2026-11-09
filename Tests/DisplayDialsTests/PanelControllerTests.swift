import AppKit
import Testing
@testable import DisplayDials

@MainActor
private final class FakeNightShift: NightShiftControlling {
    var enabled: Bool
    var strength: Double
    var available = true
    var readable = true
    var failStrength = false
    var failEnabled = false
    var reads = 0
    var writes: [String] = []

    init(enabled: Bool, strength: Double) { self.enabled = enabled; self.strength = strength }

    func readSnapshot() -> NightShiftSnapshot {
        reads += 1
        return NightShiftSnapshot(supported: true, diagnostic: readable ? "Available" : "Read failed",
            state: readable ? NightShiftState(available: available, enabled: enabled,
                                             active: enabled, strength: strength) : nil)
    }

    func changeStrength(_ value: Float) -> Bool {
        writes.append("strength")
        if failStrength { return false }
        strength = Double(value)
        return true
    }

    func changeEnabled(_ value: Bool) -> Bool {
        writes.append(value ? "enable" : "disable")
        if failEnabled { return false }
        enabled = value
        return true
    }
}

@MainActor
private final class TrackingCell: NSSliderCell {
    var values: [Double] = []
    var afterActions: [Double] = []
    override func trackMouse(with event: NSEvent, in cellFrame: NSRect,
                             of controlView: NSView, untilMouseUp flag: Bool) -> Bool {
        let slider = controlView as! WarmthSlider
        for value in values {
            slider.doubleValue = value
            _ = slider.sendAction(slider.action, to: slider.target)
            afterActions.append(slider.doubleValue)
        }
        return true
    }
}

@Suite(.serialized)
@MainActor
struct PanelControllerTests {
    private func panel(_ client: FakeNightShift) -> PanelController {
        _ = NSApplication.shared
        let panel = PanelController(warmth: client)
        _ = panel.view
        panel.view.layoutSubtreeIfNeeded()
        return panel
    }

    @discardableResult
    private func drag(_ panel: PanelController, values: [Double]) -> [Double] {
        let slider = panel.warmthSlider
        let initial = slider.doubleValue
        let target = slider.target
        let action = slider.action
        let cell = TrackingCell()
        slider.cell = cell
        slider.target = target
        slider.action = action
        slider.minValue = 0
        slider.maxValue = 1
        slider.numberOfTickMarks = 10
        slider.allowsTickMarkValuesOnly = true
        slider.isContinuous = true
        slider.doubleValue = initial
        slider.frame = NSRect(x: 0, y: 0, width: 250, height: 24)
        cell.values = values
        let location = slider.convert(NSPoint(x: 5, y: 12), to: nil)
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: location,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1)!
        slider.mouseDown(with: event)
        return cell.afterActions
    }

    private func action(_ panel: PanelController, value: Double) {
        panel.warmthSlider.doubleValue = value
        _ = panel.warmthSlider.sendAction(panel.warmthSlider.action, to: panel.warmthSlider.target)
    }

    @Test func updatesMenuFollowsReleaseSettingsOrder() throws {
        let controller = panel(FakeNightShift(enabled: false, strength: 0.5))
        let menu = controller.makeOptionsMenu()
        let updates = try #require(menu.item(withTitle: "Updates"))
        #expect(updates.isEnabled)
        let submenu = try #require(updates.submenu)
        let items = submenu.items.filter { !$0.isSeparatorItem }
        #expect(items.map(\.title) == [
            "Check for Updates…",
            "Automatically Check for Updates",
            "Automatically Install Updates",
            "Version \(AppIdentity.version)"
        ])
        #expect(items.prefix(3).allSatisfy { $0.target === controller })
        #expect(items.compactMap { $0.action.map(NSStringFromSelector) } == [
            "checkForUpdates:", "changeAutomaticChecks:", "changeAutomaticInstallation:"
        ])
        let version = try #require(items.last)
        #expect(!version.isEnabled)
        #expect(version.action == nil)
    }

    @Test func offDisablesExternalNearZeroWithoutWritingOnRead() {
        for strength in [0.0, 0.01, 0.05, 0.06] {
            let client = FakeNightShift(enabled: true, strength: strength)
            let panel = panel(client)
            panel.refresh()
            #expect(client.writes.isEmpty)
            #expect(panel.statusLabel.stringValue == "On · \(Int((strength * 100).rounded()))%")
            drag(panel, values: [0, 0, 0])
            #expect(client.writes == ["disable"])
            #expect(!client.enabled && client.strength == strength)
            #expect(panel.statusLabel.stringValue == "Off")
            #expect(panel.warmthSlider.doubleValue == 0)
        }
    }

    @Test func disabledUnchangedGestureAndReversalPreserveOrdering() {
        let client = FakeNightShift(enabled: false, strength: 0.8)
        let panel = panel(client)
        drag(panel, values: [0, 0])
        #expect(client.writes.isEmpty)
        #expect(client.strength == 0.8)
        drag(panel, values: [1.0 / 9, 1.0 / 9, 2.0 / 9, 1.0 / 9, 0, 0])
        #expect(client.writes == ["strength", "enable", "strength", "strength", "disable"])
        #expect(!client.enabled)
        #expect(abs(client.strength - 1.0 / 9) < 0.00001)
    }

    @Test func failedDisableCanBeRetriedWithoutMovingAwayFromOff() {
        let client = FakeNightShift(enabled: true, strength: 0.01)
        client.failEnabled = true
        let panel = panel(client)
        drag(panel, values: [0, 0])
        #expect(client.writes == ["disable"])
        #expect(panel.statusLabel.stringValue == "Could not apply setting. Try again.")
        #expect(client.enabled && panel.warmthSlider.doubleValue == 0)
        client.failEnabled = false
        drag(panel, values: [0, 0])
        #expect(client.writes == ["disable", "disable"])
        #expect(panel.statusLabel.stringValue == "Off")
    }

    @Test func failedWritesReconcileAndNonDragActionsRecover() {
        let client = FakeNightShift(enabled: false, strength: 0.7)
        let panel = panel(client)
        client.failStrength = true
        action(panel, value: 4.0 / 9)
        #expect(client.writes == ["strength"])
        #expect(!client.enabled && client.strength == 0.7)
        #expect(panel.warmthSlider.doubleValue == 0)
        let firstError = panel.statusLabel.stringValue
        #expect(firstError == "Could not apply setting. Try again.")
        action(panel, value: 5.0 / 9)
        #expect(client.writes == ["strength", "strength"])
        #expect(panel.warmthSlider.doubleValue == 0)
        #expect(panel.statusLabel.stringValue == firstError)
        client.failStrength = false
        client.failEnabled = true
        action(panel, value: 4.0 / 9)
        #expect(client.writes == ["strength", "strength", "strength", "enable"])
        #expect(!client.enabled && abs(client.strength - 4.0 / 9) < 0.00001)
        #expect(panel.warmthSlider.doubleValue == 0)
        client.failEnabled = false
        action(panel, value: 4.0 / 9)
        #expect(client.enabled)
        #expect(panel.statusLabel.stringValue == "On · 44%")
        action(panel, value: 0)
        #expect(!client.enabled && panel.statusLabel.stringValue == "Off")
    }

    @Test func failedDragKeepsRequestedTicksUntilCompletionThenReconciles() {
        let client = FakeNightShift(enabled: true, strength: 2.0 / 9)
        client.failStrength = true
        let panel = panel(client)
        let positions = drag(panel, values: [5.0 / 9, 6.0 / 9])
        #expect(positions == [5.0 / 9, 6.0 / 9])
        #expect(client.writes == ["strength", "strength"])
        #expect(panel.warmthSlider.doubleValue == 2.0 / 9)
        #expect(panel.statusLabel.stringValue == "Could not apply setting. Try again.")
    }

    @Test func failedOrUnavailableReadDisablesControlsAndRecovers() {
        let client = FakeNightShift(enabled: true, strength: 0.5)
        let panel = panel(client)
        client.readable = false
        panel.refresh()
        #expect(!panel.warmthSlider.isEnabled)
        #expect(panel.statusLabel.stringValue == "Unavailable")
        #expect(panel.statusLabel.toolTip == "Read failed")
        action(panel, value: 0)
        #expect(client.writes.isEmpty)
        client.readable = true
        client.available = false
        panel.refresh()
        #expect(!panel.warmthSlider.isEnabled)
        client.available = true
        panel.refresh()
        #expect(panel.warmthSlider.isEnabled)
        action(panel, value: 0)
        #expect(client.writes == ["disable"])
        #expect(panel.statusLabel.stringValue == "Off")
    }

    @Test func pollingRunsOnlyWhileVisibleWithoutDuplicateTimers() {
        let client = FakeNightShift(enabled: true, strength: 0.5)
        let panel = panel(client)
        panel.viewWillAppear()
        panel.viewWillAppear()
        let before = client.reads
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 6.2))
        #expect(client.reads == before + 1)
        panel.viewDidDisappear()
        let hidden = client.reads
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 6.2))
        #expect(client.reads == hidden)
        #expect(client.writes.isEmpty)
    }
}
