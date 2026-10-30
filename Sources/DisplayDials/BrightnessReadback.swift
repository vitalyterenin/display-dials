import AppKit
import Darwin

/// Read-only diagnostic values. These private API values are NOT photometer readings.
/// Signatures are documented in Lunar's Lunar-Bridging-Header.h.
@MainActor
enum BrightnessReadback {
    private static let library = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY | RTLD_LOCAL)
    static func values(for display: CGDirectDisplayID) -> [String: Double] {
        guard let library else { return [:] }
        typealias Getter = @convention(c) (UInt32) -> Double
        var values: [String: Double] = [:]
        for (key, name) in [
            ("user", "CoreDisplay_Display_GetUserBrightness"),
            ("linear", "CoreDisplay_Display_GetLinearBrightness"),
            ("dynamicLinear", "CoreDisplay_Display_GetDynamicLinearBrightness")
        ] {
            guard let symbol = dlsym(library, name) else { continue }
            let value = unsafeBitCast(symbol, to: Getter.self)(display)
            if value.isFinite { values[key] = value }
        }
        return values
    }
}
