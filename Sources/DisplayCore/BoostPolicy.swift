/// A gate for a future renderer, not a statement of panel safety or a nits calibration.
public struct BoostPolicy: Sendable {
    public enum Thermal: Sendable { case nominal, fair, serious, critical, unknown }
    public enum Block: String, Sendable {
        case disabled, unvalidatedRenderer, unsupportedDisplay, sleeping, thermalPressure, noHeadroom, invalidInput
    }
    public struct Decision: Equatable, Sendable {
        public let multiplier: Double
        public let block: Block?
    }

    public init() {}

    public func evaluate(requested: Double, enabled: Bool, rendererValidated: Bool,
                         builtIn: Bool, awake: Bool, thermal: Thermal,
                         currentHeadroom: Double) -> Decision {
        func off(_ reason: Block) -> Decision { Decision(multiplier: 1, block: reason) }
        guard enabled else { return off(.disabled) }
        guard requested.isFinite, currentHeadroom.isFinite else { return off(.invalidInput) }
        guard awake else { return off(.sleeping) }
        guard builtIn else { return off(.unsupportedDisplay) }
        guard thermal == .nominal else { return off(.thermalPressure) }
        guard rendererValidated else { return off(.unvalidatedRenderer) }
        guard currentHeadroom > 1 else { return off(.noHeadroom) }
        // An initial experimental ceiling, NOT a proven hardware-safe value.
        return Decision(multiplier: min(max(1, requested), 1.25, currentHeadroom), block: nil)
    }
}
