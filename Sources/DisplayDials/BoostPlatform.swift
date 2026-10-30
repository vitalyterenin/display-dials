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
        case "timeout": "Тест завершён. Буст выключен."
        case "heartbeat": "Связь с панелью прервалась. Буст отключён."
        case "unsupported": "Нужен встроенный XDR-экран без зеркалирования."
        case "sleeping", "sessionInactive": "Сеанс приостановлен. Включите буст заново."
        case "thermal": "Система нагрелась. Буст отключён."
        case "noHeadroom": "macOS не предоставила запас HDR-яркости."
        case "displayChanged": "Конфигурация экранов изменилась. Буст отключён."
        case "conflict": "Закройте BetterDisplay, BrightIntosh и Vivid перед тестом."
        case "renderer": "Не удалось вывести HDR-слой. Буст отключён."
        case "workerUnresponsive": "Процесс усиления перестал отвечать. Буст отключён."
        case "invalidInput": "Получены некорректные данные. Буст отключён."
        default: "Буст отключается при сне или срабатывании защиты."
        }
    }
}
