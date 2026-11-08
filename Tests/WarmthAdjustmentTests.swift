import Foundation

@main
struct WarmthAdjustmentTests {
    static func main() {
        precondition(WarmthAdjustment.sliderValue(enabled: false, strength: 1) == 0)
        precondition(WarmthAdjustment.sliderValue(enabled: true, strength: 0.37) == 0.37)
        var writes: [String] = []
        func apply(_ strength: Float, enabled: Bool, strengthOK: Bool = true, enableOK: Bool = true) -> Bool {
            WarmthAdjustment.apply(strength: strength, enabled: enabled,
                setStrength: { writes.append("strength:\($0)"); return strengthOK },
                setEnabled: { writes.append("enabled:\($0)"); return enableOK })
        }
        precondition(apply(0, enabled: true))
        precondition(writes == ["enabled:false"], "Off must disable, without overwriting remembered warmth.")
        writes = []
        precondition(apply(0, enabled: false))
        precondition(writes.isEmpty, "Repeated Off must not write again.")
        precondition(apply(0.5, enabled: false))
        precondition(writes == ["strength:0.5", "enabled:true"], "Set warmth before enabling.")
        writes = []
        precondition(apply(1, enabled: true))
        precondition(writes == ["strength:1.0"], "Positive changes need not re-enable an enabled system.")
        writes = []
        precondition(!apply(0.5, enabled: false, strengthOK: false))
        precondition(writes == ["strength:0.5"], "A failed strength change must not enable the old value.")
        writes = []
        precondition(!apply(0.5, enabled: false, enableOK: false))
        precondition(writes == ["strength:0.5", "enabled:true"])
        writes = []
        precondition(!apply(0, enabled: true, enableOK: false))
        precondition(writes == ["enabled:false"])
        for invalid: Float in [-1, 2, .nan, .infinity] {
            writes = []
            precondition(!apply(invalid, enabled: false))
            precondition(writes.isEmpty)
        }
        print("Warmth adjustment: Off/on transitions, ordering, read mapping and failure checks passed.")
    }
}
