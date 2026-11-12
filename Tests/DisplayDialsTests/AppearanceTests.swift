import AppKit
import Carbon
import Testing
@testable import DisplayDials

private actor AppearanceChange {
    var calls = 0
    var shouldFail = true
    var continuation: CheckedContinuation<Bool, Never>?

    func change() throws -> Bool {
        calls += 1
        if shouldFail {
            shouldFail = false
            throw AppearanceController.ChangeError(detail: "Automation denied")
        }
        return true
    }

    func suspendedChange() async -> Bool {
        calls += 1
        return await withCheckedContinuation { continuation = $0 }
    }

    func finish() { continuation?.resume(returning: false); continuation = nil }
}

@Suite(.serialized)
@MainActor
struct AppearanceTests {
    @Test func permissionFailureIsReportedAndNextGestureCanRecover() async throws {
        let change = AppearanceChange()
        let controller = AppearanceController(change: { try await change.change() })
        do {
            try await controller.toggle()
            Issue.record("Expected a denied automation request")
        } catch {
            #expect(error.localizedDescription == "Automation denied")
        }
        #expect(controller.lastError == "Automation denied")
        #expect(!controller.isChanging)
        try await controller.toggle()
        #expect(controller.lastError == nil)
        #expect(!controller.isChanging)
        #expect(await change.calls == 2)
    }

    @Test func overlappingGesturesDoNotQueueExtraToggles() async throws {
        let change = AppearanceChange()
        let controller = AppearanceController(change: { await change.suspendedChange() })
        let first = Task { try await controller.toggle() }
        while await change.calls == 0 { await Task.yield() }
        #expect(controller.isChanging)
        try await controller.toggle()
        #expect(await change.calls == 1)
        await change.finish()
        try await first.value
        #expect(!controller.isChanging)
    }

    @Test func hotKeyDispatchFiltersEventsAndReleasesRegistration() throws {
        _ = NSApplication.shared
        let shortcut = AppearanceShortcut(keyCode: UInt32(kVK_F20))
        var calls = 0
        shortcut.start { calls += 1 }
        defer { shortcut.stop() }
        try #require(shortcut.isRegistered)
        #expect(shortcut.registrationError == nil)
        let conflicting = AppearanceShortcut(keyCode: UInt32(kVK_F20))
        conflicting.start { calls += 1000 }
        defer { conflicting.stop() }
        #expect(!conflicting.isRegistered)
        #expect(conflicting.registrationError != nil)
        shortcut.start { calls += 100 }
        let events = [
            (OSType(0), kEventHotKeyPressed, 0),
            (OSType(0x44446170), kEventHotKeyReleased, 0),
            (OSType(0x44446170), kEventHotKeyPressed, 1),
            (OSType(0x44446170), kEventHotKeyPressed, 1),
            (OSType(0), kEventHotKeyReleased, 1),
            (OSType(0x44446170), kEventHotKeyPressed, 1),
            (OSType(0x44446170), kEventHotKeyReleased, 1),
            (OSType(0x44446170), kEventHotKeyPressed, 2)
        ]
        for (signature, kind, expectedCalls) in events {
            var event: EventRef?
            #expect(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kind),
                0, 0, &event) == noErr)
            let released = try #require(event)
            defer { ReleaseEvent(released) }
            var identifier = EventHotKeyID(signature: signature, id: 1)
            #expect(SetEventParameter(released, UInt32(kEventParamDirectObject),
                UInt32(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &identifier) == noErr)
            _ = SendEventToEventTarget(released, GetApplicationEventTarget())
            #expect(calls == expectedCalls)
        }
        shortcut.stop()
        #expect(!shortcut.isRegistered)
        shortcut.start { calls += 1 }
        #expect(shortcut.isRegistered)
    }
}
