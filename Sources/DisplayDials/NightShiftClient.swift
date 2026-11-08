import Foundation
import NightShiftBridge

struct NightShiftState: Equatable {
    let available: Bool
    let enabled: Bool
    let active: Bool
    let strength: Double

    init(available: Bool, enabled: Bool, active: Bool, strength: Double) {
        self.available = available
        self.enabled = enabled
        self.active = active
        self.strength = strength
    }

    init?(_ values: [String: NSNumber]?) {
        guard let values, let available = values["available"],
              let enabled = values["enabled"], let active = values["active"],
              let strength = values["strength"]?.doubleValue,
              strength.isFinite, (0...1).contains(strength) else { return nil }
        self.init(available: available.boolValue, enabled: enabled.boolValue,
                  active: active.boolValue, strength: strength)
    }

    var json: [String: Any] {
        ["available": available, "enabled": enabled, "active": active, "strength": strength]
    }
}

struct NightShiftSnapshot: Equatable {
    let supported: Bool
    let diagnostic: String
    let state: NightShiftState?

    var available: Bool { state?.available == true }
    var stateJSON: [String: Any] { state?.json ?? [:] }
}

@MainActor
protocol NightShiftControlling: AnyObject {
    func readSnapshot() -> NightShiftSnapshot
    func changeStrength(_ strength: Float) -> Bool
    func changeEnabled(_ enabled: Bool) -> Bool
}

/// Keeps private API calls in the bridge and exposes one completed read to Swift.
@MainActor
final class NightShiftClient: NightShiftControlling {
    private let client: DDWarmthClient

    init(client: DDWarmthClient = DDWarmthClient()) { self.client = client }

    func readSnapshot() -> NightShiftSnapshot {
        let state = NightShiftState(client.readState())
        // A read exception can update these properties; capture them after the read.
        let supported = client.supported
        let diagnostic: String
        if supported && state == nil {
            diagnostic = "Could not read Night Shift state."
        } else if supported && state?.available == false {
            diagnostic = "Night Shift is unavailable in the current display configuration."
        } else {
            diagnostic = client.diagnostic
        }
        return NightShiftSnapshot(supported: supported, diagnostic: diagnostic, state: state)
    }

    func changeStrength(_ strength: Float) -> Bool { client.changeStrength(strength) }
    func changeEnabled(_ enabled: Bool) -> Bool { client.changeEnabled(enabled) }
}
