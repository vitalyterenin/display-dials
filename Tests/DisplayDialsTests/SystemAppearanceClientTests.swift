import Foundation
import Testing
@testable import DisplayDials

struct SystemAppearanceClientTests {
    private func reply(_ value: NSAppleEventDescriptor? = nil, error: Int32? = nil) -> NSAppleEventDescriptor {
        let reply = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEAnswer),
            targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        if let value { reply.setParam(value, forKeyword: AEKeyword(keyDirectObject)) }
        if let error { reply.setParam(NSAppleEventDescriptor(int32: error), forKeyword: AEKeyword(keyErrorNumber)) }
        return reply
    }

    @Test func togglesFromCurrentStateAndVerifiesReadback() throws {
        var dark = false
        var requests: [AEEventID] = []
        let client = SystemAppearanceClient { event in
            requests.append(event.eventID)
            #expect(event.eventClass == AEEventClass(kAECoreSuite))
            let target = try #require(event.attributeDescriptor(forKeyword: AEKeyword(keyAddressAttr)))
            #expect(String(data: target.data, encoding: .utf8) == "com.apple.systemevents")
            let property = try #require(event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)))
            #expect(property.descriptorType == DescType(typeObjectSpecifier))
            #expect(property.forKeyword(AEKeyword(keyAEKeyData))?.typeCodeValue == 0x74686d65)
            let preferences = try #require(property.forKeyword(AEKeyword(keyAEContainer)))
            #expect(preferences.forKeyword(AEKeyword(keyAEKeyData))?.typeCodeValue == 0x61707270)
            if event.eventID == AEEventID(kAESetData) {
                dark = try #require(event.paramDescriptor(forKeyword: AEKeyword(keyAEData))).booleanValue
                return reply()
            }
            return reply(NSAppleEventDescriptor(boolean: dark))
        }
        #expect(try client.toggle())
        #expect(dark)
        #expect(try !client.toggle())
        #expect(!dark)
        #expect(requests == [kAEGetData, kAESetData, kAEGetData, kAEGetData, kAESetData, kAEGetData].map { AEEventID($0) })
    }

    @Test func failedReadNeverWritesOrTreatsMissingStateAsLight() {
        for invalid in [nil, NSAppleEventDescriptor(string: "false")] {
            var requests = 0
            let client = SystemAppearanceClient { _ in requests += 1; return reply(invalid) }
            #expect(throws: (any Error).self) { try client.toggle() }
            #expect(requests == 1)
        }
    }

    @Test func mismatchingReadbackIsAnError() {
        var requests = 0
        let client = SystemAppearanceClient { _ in
            requests += 1
            return reply(NSAppleEventDescriptor(boolean: false))
        }
        #expect(throws: (any Error).self) { try client.toggle() }
        #expect(requests == 3)
    }

    @Test func serverAndTransportPermissionErrorsKeepRecoveryInstructions() {
        for code: Int32 in [-1743, -1744] {
            for transportError in [false, true] {
                var requests = 0
                let client = SystemAppearanceClient { _ in
                    requests += 1
                    if transportError { throw NSError(domain: NSOSStatusErrorDomain, code: Int(code)) }
                    return reply(error: code)
                }
                do {
                    _ = try client.toggle()
                    Issue.record("Expected an Automation error")
                } catch {
                    #expect(error.localizedDescription.contains("Privacy & Security → Automation"))
                }
                #expect(requests == 1)
            }
        }
    }

    @Test func failedSetStopsBeforeReadbackAndPreservesError() {
        var requests = 0
        let client = SystemAppearanceClient { event in
            requests += 1
            if event.eventID == AEEventID(kAESetData) { return reply(error: -1712) }
            return reply(NSAppleEventDescriptor(boolean: false))
        }
        do {
            _ = try client.toggle()
            Issue.record("Expected the set timeout")
        } catch {
            #expect((error as NSError).code == -1712)
        }
        #expect(requests == 2)
    }
}
