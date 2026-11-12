import Foundation

/// The same System Events scripting property, without launching an AppleScript interpreter.
struct SystemAppearanceClient {
    private let transport: (NSAppleEventDescriptor) throws -> NSAppleEventDescriptor

    init(transport: @escaping (NSAppleEventDescriptor) throws -> NSAppleEventDescriptor = {
        try $0.sendEvent(options: [.waitForReply, .canInteract], timeout: 15)
    }) {
        self.transport = transport
    }

    func toggle() throws -> Bool {
        let requested = try !readDarkMode()
        let set = try event(id: AEEventID(kAESetData))
        set.setParam(NSAppleEventDescriptor(boolean: requested), forKeyword: AEKeyword(keyAEData))
        _ = try send(set)
        guard try readDarkMode() == requested else {
            throw AppearanceController.ChangeError(detail: "macOS did not apply the appearance change. Try again.")
        }
        return requested
    }

    func readDarkMode() throws -> Bool {
        let reply = try send(event(id: AEEventID(kAEGetData)))
        guard let value = reply.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)),
              [typeBoolean, typeTrue, typeFalse].map({ DescType($0) }).contains(value.descriptorType) else {
            throw AppearanceController.ChangeError(detail: "macOS returned an invalid appearance state. Try again.")
        }
        return value.booleanValue
    }

    private func event(id: AEEventID) throws -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kAECoreSuite), eventID: id,
            targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: "com.apple.systemevents"),
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        // Codes are declared in System Events.app's public scripting dictionary.
        let preferences = try property(0x61707270, of: .null()) // aprp: appearance preferences
        let darkMode = try property(0x74686d65, of: preferences) // thme: dark mode
        event.setParam(darkMode, forKeyword: AEKeyword(keyDirectObject))
        return event
    }

    private func property(_ code: OSType, of container: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: OSType(typeProperty)), forKeyword: AEKeyword(keyAEDesiredClass))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: OSType(formPropertyID)), forKeyword: AEKeyword(keyAEKeyForm))
        record.setDescriptor(NSAppleEventDescriptor(typeCode: code), forKeyword: AEKeyword(keyAEKeyData))
        record.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
        guard let specifier = record.coerce(toDescriptorType: DescType(typeObjectSpecifier)) else {
            throw AppearanceController.ChangeError(detail: "Could not prepare the macOS appearance request.")
        }
        return specifier
    }

    private func send(_ event: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        do {
            let reply = try transport(event)
            if let error = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber)), error.int32Value != 0 {
                let message = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorString))?.stringValue
                    ?? "macOS could not change the appearance. Try again."
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(error.int32Value),
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
            return reply
        } catch {
            if [-1743, -1744].contains((error as NSError).code) {
                throw AppearanceController.ChangeError(detail: "Allow Display Dials to control System Events in System Settings → Privacy & Security → Automation, then try again.")
            }
            throw error
        }
    }
}
