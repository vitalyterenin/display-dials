import Foundation

/// Maps the left endpoint to Off without changing the system's remembered warmth.
enum WarmthAdjustment {
    static func sliderValue(enabled: Bool, strength: Double) -> Double {
        enabled ? strength : 0
    }

    static func apply(strength: Float, enabled: Bool,
                      setStrength: (Float) -> Bool, setEnabled: (Bool) -> Bool) -> Bool {
        guard strength.isFinite, (0...1).contains(strength) else { return false }
        if strength == 0 { return !enabled || setEnabled(false) }
        // Set the requested warmth first so enabling never flashes the old value.
        guard setStrength(strength) else { return false }
        return enabled || setEnabled(true)
    }
}
