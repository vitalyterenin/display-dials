import AppKit

@MainActor
final class TrackingCell: NSSliderCell {
    var values: [Double] = []

    override func trackMouse(with event: NSEvent, in cellFrame: NSRect,
                             of controlView: NSView, untilMouseUp flag: Bool) -> Bool {
        let slider = controlView as! WarmthSlider
        for value in values {
            slider.doubleValue = value
            _ = slider.sendAction(slider.action, to: slider.target)
        }
        return true
    }
}

@MainActor
final class Receiver: NSObject {
    var positions: [Int] = []
    var duringDrag: [Bool] = []

    @objc func changed(_ slider: WarmthSlider) {
        positions.append(Int((slider.doubleValue * 9).rounded()) + 1)
        duringDrag.append(slider.isDragging)
    }
}

@main
struct WarmthSliderTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        let slider = WarmthSlider(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        precondition(slider.isContinuous, "Tick changes must be sent before mouse release.")
        let cell = TrackingCell()
        slider.cell = cell
        slider.minValue = 0
        slider.maxValue = 1
        slider.numberOfTickMarks = 10
        slider.allowsTickMarkValuesOnly = true
        slider.isContinuous = true
        slider.doubleValue = 0
        let receiver = Receiver()
        slider.target = receiver
        slider.action = #selector(Receiver.changed(_:))
        var completions: [[Int]] = []
        slider.onDragEnded = {
            precondition(!slider.isDragging)
            completions.append(receiver.positions)
        }
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 5, y: 12),
                                       modifierFlags: [], timestamp: 0, windowNumber: 0,
                                       context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        // Exercise the native mouseDown lifecycle with an isolated cell; no OS writes/input injection.
        cell.values = [0, 1.0 / 9, 1.0 / 9, 2.0 / 9, 2.0 / 9, 1.0 / 9, 1.0 / 9]
        slider.mouseDown(with: event)
        precondition(receiver.positions == [2, 3, 2], "Apply each changed tick once, including reversals.")
        precondition(receiver.duringDrag == [true, true, true], "Changes must arrive while the mouse is held.")
        precondition(completions == [[2, 3, 2]], "Finish a drag once, after all immediate changes.")
        receiver.positions = []
        receiver.duringDrag = []
        cell.values = [1.0 / 9, 1.0 / 9]
        slider.mouseDown(with: event)
        precondition(receiver.positions.isEmpty, "An unchanged gesture must not write again.")
        slider.doubleValue = 3.0 / 9
        _ = slider.sendAction(slider.action, to: slider.target)
        precondition(receiver.positions == [4] && receiver.duringDrag == [false],
                     "Non-drag actions must remain immediate.")
        print("Warmth slider: immediate tracking, tick deduplication, reversal and completion checks passed.")
    }
}
