import Foundation
import Testing
@testable import UsageTelemetry

@MainActor
private final class CaptureTransport: UsageTransport {
    var bodies: [Data] = []
    var cancelled = false
    func send(_ body: Data) { bodies.append(body) }
    func cancel() { cancelled = true }
}

@MainActor
struct UsageTelemetryTests {
    private let appID = "C9BDEB80-7297-458C-B646-F85F6DE4C60D"

    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "DisplayDials.StatisticsTests.\(UUID().uuidString)")!
    }

    @Test func noCollectionBeforeConsentOrAfterDeclining() {
        let defaults = isolatedDefaults()
        let capture = CaptureTransport()
        var creations = 0
        let telemetry = UsageTelemetry(appID: appID, version: "test", build: "1", defaults: defaults) {
            creations += 1
            return capture
        }
        telemetry.start()
        telemetry.record(.panelOpened(.menuBar))
        telemetry.flush()
        #expect(!telemetry.hasChosen)
        #expect(defaults.string(forKey: UsageTelemetry.identifierKey) == nil)
        telemetry.setEnabled(false)
        telemetry.record(.manualUpdateCheck)
        telemetry.flush()
        #expect(telemetry.hasChosen)
        #expect(creations == 0)
        #expect(capture.bodies.isEmpty)
    }

    @Test func optOutDropsQueueCancelsTransportAndResetsIdentity() throws {
        let defaults = isolatedDefaults()
        let capture = CaptureTransport()
        let telemetry = UsageTelemetry(appID: appID, version: "test", build: "1", defaults: defaults) { capture }
        telemetry.start()
        telemetry.setEnabled(true)
        telemetry.flush()
        let firstIdentity = try #require(defaults.string(forKey: UsageTelemetry.identifierKey))
        telemetry.record(.warmthChanged(position: 5, succeeded: true))
        telemetry.setEnabled(false)
        telemetry.flush()
        #expect(capture.cancelled)
        #expect(capture.bodies.count == 1)
        #expect(defaults.string(forKey: UsageTelemetry.identifierKey) == nil)
        telemetry.setEnabled(true)
        telemetry.flush()
        #expect(defaults.string(forKey: UsageTelemetry.identifierKey) != firstIdentity)
        let newBatch = try #require(JSONSerialization.jsonObject(with: capture.bodies[1]) as? [[String: Any]])
        #expect(newBatch.count == 1)
        #expect(newBatch[0]["type"] as? String == "Statistics.enabled")
        telemetry.setEnabled(false)
    }

    @Test func payloadContainsOnlyDocumentedFieldsAndNoPreConsentReplay() throws {
        let defaults = isolatedDefaults()
        let capture = CaptureTransport()
        let telemetry = UsageTelemetry(appID: appID, version: "0.6.0", build: "10", defaults: defaults, testMode: true) { capture }
        telemetry.start()
        telemetry.record(.panelOpened(.launch))
        telemetry.setEnabled(true)
        telemetry.record(.warmthChanged(position: 999, succeeded: false))
        telemetry.flush()
        let batch = try #require(JSONSerialization.jsonObject(with: capture.bodies[0]) as? [[String: Any]])
        #expect(batch.compactMap { $0["type"] as? String } == ["Statistics.enabled", "Warmth.changed"])
        #expect(Set(batch[1].keys) == Set(["appID", "clientUser", "sessionID", "type", "isTestMode", "receivedAt", "payload"]))
        let payload = try #require(batch[1]["payload"] as? [String: String])
        #expect(Set(payload.keys) == Set(["TelemetryDeck.AppInfo.version", "TelemetryDeck.AppInfo.buildNumber",
            "TelemetryDeck.Device.platform", "TelemetryDeck.Device.systemMajorMinorVersion", "position", "succeeded"]))
        #expect(payload["position"] == "10")
        #expect(batch[1]["isTestMode"] as? Bool == true)
        let hash = try #require(batch[1]["clientUser"] as? String)
        #expect(hash.count == 64)
        #expect(hash != defaults.string(forKey: UsageTelemetry.identifierKey))
        telemetry.setEnabled(false)
    }

    @Test func diagnosticsAndInvalidConfigurationCannotCollectEvenWithSavedConsent() {
        for (id, allowed) in [(appID, false), ("invalid", true)] {
            let defaults = isolatedDefaults()
            defaults.set(true, forKey: UsageTelemetry.consentKey)
            var creations = 0
            let telemetry = UsageTelemetry(appID: id, version: "test", build: "1", defaults: defaults, runtimeAllowed: allowed) {
                creations += 1
                return CaptureTransport()
            }
            telemetry.start()
            telemetry.record(.manualUpdateCheck)
            telemetry.flush()
            #expect(!telemetry.isEnabled)
            #expect(creations == 0)
            #expect(defaults.string(forKey: UsageTelemetry.identifierKey) == nil)
        }
    }

    @Test func queueIsBoundedAndOptOutSurvivesRelaunch() throws {
        let defaults = isolatedDefaults()
        let capture = CaptureTransport()
        let telemetry = UsageTelemetry(appID: appID, version: "test", build: "1", defaults: defaults) { capture }
        telemetry.start()
        telemetry.setEnabled(true)
        for _ in 0..<100 { telemetry.record(.panelOpened(.menuBar)) }
        telemetry.flush()
        let batch = try #require(JSONSerialization.jsonObject(with: capture.bodies[0]) as? [[String: Any]])
        #expect(batch.count == 50)
        telemetry.setEnabled(false)
        let relaunched = UsageTelemetry(appID: appID, version: "test", build: "1", defaults: defaults) { capture }
        relaunched.start()
        relaunched.flush()
        #expect(relaunched.hasChosen && !relaunched.isEnabled)
        #expect(capture.bodies.count == 1)
    }
}
