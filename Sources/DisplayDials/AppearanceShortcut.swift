import Carbon

/// A fixed system hot key; no keyboard monitoring or accessibility access is needed.
@MainActor
final class AppearanceShortcut {
    private static let signature: OSType = 0x44446170 // DDap
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var action: (() -> Void)?
    private(set) var registrationError: OSStatus?
    var isRegistered: Bool { hotKey != nil }

    func start(action: @escaping () -> Void) {
        guard !isRegistered else { return }
        self.action = action
        // Release fires once per gesture, including when the key is held down.
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                  eventKind: UInt32(kEventHotKeyReleased))
        let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let result = GetEventParameter(event, UInt32(kEventParamDirectObject),
                UInt32(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard result == noErr else { return result }
            return MainActor.assumeIsolated {
                guard identifier.signature == AppearanceShortcut.signature, identifier.id == 1 else {
                    return OSStatus(eventNotHandledErr)
                }
                Unmanaged<AppearanceShortcut>.fromOpaque(context).takeUnretainedValue().action?()
                return noErr
            }
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard result == noErr else {
            registrationError = result
            self.action = nil
            return
        }
        let registration = RegisterEventHotKey(UInt32(kVK_ANSI_N), UInt32(optionKey | cmdKey),
            EventHotKeyID(signature: Self.signature, id: 1), GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive), &hotKey)
        if registration != noErr {
            stop()
            registrationError = registration
        } else {
            registrationError = nil
        }
    }

    func stop() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
        action = nil
    }
}
