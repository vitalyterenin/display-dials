import AppKit

@MainActor
final class WarmthSlider: NSSlider {
    private(set) var isDragging = false
    var onDragEnded: (() -> Void)?
    private var lastSentStrength: Double?

    override init(frame: NSRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        minValue = 0
        maxValue = 1
        doubleValue = 0.5
        numberOfTickMarks = 10
        allowsTickMarkValuesOnly = true
        isContinuous = true
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isDragging = true
        lastSentStrength = doubleValue
        defer {
            isDragging = false
            lastSentStrength = nil
            onDragEnded?()
        }
        super.mouseDown(with: event)
    }

    override func sendAction(_ action: Selector?, to target: Any?) -> Bool {
        if isDragging {
            let strength = closestTickMarkValue(toValue: doubleValue)
            guard strength != lastSentStrength else { return false }
            lastSentStrength = strength
        }
        return super.sendAction(action, to: target)
    }
}
