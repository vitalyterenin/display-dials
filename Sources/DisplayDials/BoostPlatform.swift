import AppKit
import DisplayCore

@MainActor
enum BoostPlatform {
    static func displayID(_ screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
    static var screen: NSScreen? {
        NSScreen.screens.first { CGDisplayIsBuiltin(displayID($0)) != 0 }
    }
    static func supported(_ screen: NSScreen) -> Bool {
        #if arch(arm64)
        let id = displayID(screen)
        let potential = Double(screen.maximumPotentialExtendedDynamicRangeColorComponentValue)
        return id != 0 && CGDisplayIsBuiltin(id) != 0 && CGDisplayIsOnline(id) != 0
            && CGDisplayIsInMirrorSet(id) == 0 && potential.isFinite && potential > 1
        #else
        return false
        #endif
    }
    static var topology: String {
        NSScreen.screens.map {
            let id = displayID($0)
            return "\(id):\($0.frame):\($0.backingScaleFactor):\(CGDisplayCopyDisplayMode(id)?.ioDisplayModeID ?? 0):\(CGDisplayIsInMirrorSet(id))"
        }.sorted().joined(separator: ";")
    }
    static var thermal: BoostPolicy.Thermal {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .unknown
        }
    }
    static var sessionActive: Bool {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any],
              info[kCGSessionOnConsoleKey as String] as? Bool == true,
              info[kCGSessionLoginDoneKey as String] as? Bool == true else { return false }
        return info["CGSSessionScreenIsLocked"] as? Bool != true
    }
    static var conflictingApps: [String] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            let id = app.bundleIdentifier?.lowercased() ?? ""
            return ["betterdisplay", "brightintosh", "vivid"].contains(where: id.contains)
                ? (app.localizedName ?? id) : nil
        }.sorted()
    }
    static func reason(_ code: String?) -> String {
        switch code {
        case "timeout": "The test ended. Boost is off."
        case "heartbeat": "Connection to the panel was lost. Boost is off."
        case "unsupported": "A built-in XDR display without mirroring is required."
        case "sleeping", "sessionInactive": "The session was interrupted. Turn Boost on again."
        case "thermal": "The system is warm. Boost is off."
        case "noHeadroom": "macOS did not provide HDR brightness headroom."
        case "displayChanged": "The display configuration changed. Boost is off."
        case "conflict": "Quit BetterDisplay, BrightIntosh, and Vivid before enabling Boost."
        case "renderer": "Could not render the HDR layer. Boost is off."
        case "workerUnresponsive": "The Boost process stopped responding. Boost is off."
        case "invalidInput": "Invalid data was received. Boost is off."
        default: "Boost turns off during sleep or when a safety limit is reached."
        }
    }
}
