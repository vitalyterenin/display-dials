import Foundation
import NightShiftBridge
import Testing
@testable import DisplayDials

private final class FakeBridge: DDWarmthClient {
    var reads = 0
    var failsPermanently = false
    var rawState: [String: NSNumber]? = ["available": true, "enabled": true,
                                        "active": false, "strength": 0.42]
    override var supported: Bool { !(failsPermanently && reads > 0) }
    override var diagnostic: String { supported ? "Night Shift API is available" : "Night Shift API stopped responding" }
    override func readState() -> [String: NSNumber]? {
        reads += 1
        return failsPermanently ? nil : rawState
    }
}

@MainActor
struct NightShiftClientTests {
    @Test func firstFailureCapturesPostReadSupportAndDiagnostic() throws {
        let bridge = FakeBridge()
        bridge.failsPermanently = true
        let snapshot = NightShiftClient(client: bridge).readSnapshot()
        #expect(bridge.reads == 1)
        #expect(!snapshot.supported)
        #expect(snapshot.diagnostic == "Night Shift API stopped responding")
        #expect(snapshot.state == nil && snapshot.stateJSON.isEmpty)
        #expect(JSONSerialization.isValidJSONObject(snapshot.stateJSON))
    }

    @Test func failedAndInvalidReadsRemainSupportedAndCanRecover() {
        let bridge = FakeBridge()
        let client = NightShiftClient(client: bridge)
        let valid = bridge.rawState
        let invalid: [[String: NSNumber]?] = [nil, [:],
            ["available": true, "enabled": true, "active": false, "strength": NSNumber(value: Double.nan)],
            ["available": true, "enabled": true, "active": false, "strength": 1.1]]
        for raw in invalid {
            bridge.rawState = raw
            let snapshot = client.readSnapshot()
            #expect(snapshot.supported && !snapshot.available)
            #expect(snapshot.diagnostic == "Could not read Night Shift state.")
            #expect(snapshot.state == nil)
        }
        bridge.rawState = valid
        let recovered = client.readSnapshot()
        #expect(recovered.available && recovered.supported)
        #expect(recovered.state?.strength == 0.42)
        #expect(recovered.state?.active == false)
        #expect(Set(recovered.stateJSON.keys) == ["available", "enabled", "active", "strength"])
        #expect(JSONSerialization.isValidJSONObject(recovered.stateJSON))
    }

    @Test func unavailableStateIsDistinctFromAnUnsupportedAPI() {
        let bridge = FakeBridge()
        bridge.rawState?["available"] = false
        let snapshot = NightShiftClient(client: bridge).readSnapshot()
        #expect(snapshot.supported && !snapshot.available && snapshot.state != nil)
        #expect(snapshot.diagnostic == "Night Shift is unavailable in the current display configuration.")
    }
}
