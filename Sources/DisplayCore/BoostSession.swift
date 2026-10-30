public struct BoostCommand: Codable, Sendable {
    public var factor: Double
    public init(factor: Double) { self.factor = factor }
}

public struct BoostReport: Codable, Sendable {
    public var phase: String
    public var factor: Double
    public var remaining: Int
    public var reason: String?
    public var presentedFrames: Int? = nil
    public var headroom: Double? = nil
    public var brightnessReadback: [String: Double]? = nil
    public init(phase: String, factor: Double = 1, remaining: Int = 0, reason: String? = nil) {
        self.phase = phase; self.factor = factor; self.remaining = remaining; self.reason = reason
    }
}

/// One explicit, bounded experiment. An off session can never restart itself.
public struct BoostSession: Sendable {
    public enum Phase: String, Sendable { case off, preparing, active }
    public enum Stop: String, Sendable {
        case manual, timeout, heartbeat, unsupported, sleeping, thermal, noHeadroom
        case invalidInput, displayChanged, renderer, conflict, sessionInactive
    }
    public struct Environment: Sendable {
        public var supported = true
        public var awake = true
        public var thermal: BoostPolicy.Thermal = .nominal
        public var headroom: Double = 1
        public var rendererReady = true
        public var displayChanged = false
        public var conflictingApp = false
        public var sessionActive = true
        public init() {}
    }
    public static let duration: Double = 30
    public static let preparationLimit: Double = 5
    public static let heartbeatLimit: Double = 1.5
    public private(set) var phase: Phase = .off
    public private(set) var reason: Stop?
    public private(set) var effective: Double = 1
    private var requested: Double = 1.1
    private var ceiling: Double = 1.1
    private var started: Double = 0
    private var heartbeat: Double = 0

    public init() {}

    public mutating func start(now: Double, factor: Double) {
        guard now.isFinite, factor.isFinite, factor > 1 else { stop(.invalidInput); return }
        started = now; heartbeat = now
        requested = min(factor, 1.25); ceiling = requested
        effective = 1; reason = nil; phase = .preparing
    }

    public mutating func receive(now: Double, factor: Double) {
        guard phase != .off else { return }
        guard now.isFinite, factor.isFinite, now >= heartbeat else { stop(.invalidInput); return }
        // A delayed heartbeat cannot revive an expired lease, even before the next tick.
        guard now - heartbeat <= Self.heartbeatLimit else { stop(.heartbeat); return }
        heartbeat = now
        guard factor > 1 else { stop(.manual); return }
        let next = min(factor, 1.25)
        if next != requested { requested = next; ceiling = next }
    }

    public mutating func stop(_ cause: Stop) {
        phase = .off; reason = cause; effective = 1
    }

    public mutating func tick(now: Double, environment e: Environment) {
        guard phase != .off else { return }
        guard now.isFinite, e.headroom.isFinite, now >= started else { stop(.invalidInput); return }
        if now - started >= Self.duration { stop(.timeout); return }
        if now - heartbeat > Self.heartbeatLimit { stop(.heartbeat); return }
        if !e.sessionActive { stop(.sessionInactive); return }
        if !e.awake { stop(.sleeping); return }
        if e.displayChanged { stop(.displayChanged); return }
        if e.conflictingApp { stop(.conflict); return }
        if !e.supported { stop(.unsupported); return }
        if e.thermal != .nominal { stop(.thermal); return }
        if !e.rendererReady {
            if phase == .active || now - started >= Self.preparationLimit { stop(.renderer) }
            return
        }
        if phase == .preparing {
            if e.headroom <= 1.01 {
                if now - started >= Self.preparationLimit { stop(.noHeadroom) }
                return
            }
            phase = .active
        }
        let allowed = BoostPolicy().evaluate(requested: requested, enabled: true,
            rendererReady: e.rendererReady, builtIn: e.supported, awake: e.awake,
            thermal: e.thermal, currentHeadroom: e.headroom)
        guard allowed.block == nil, allowed.multiplier > 1 else { stop(.noHeadroom); return }
        // Reductions persist; later headroom recovery alone cannot brighten the desktop.
        ceiling = min(ceiling, allowed.multiplier)
        effective = ceiling
    }

    public func report(now: Double) -> BoostReport {
        let remaining = phase == .off || !now.isFinite ? 0
            : Int(min(Self.duration, max(0, Self.duration - (now - started))).rounded(.up))
        return BoostReport(phase: phase.rawValue, factor: effective, remaining: remaining, reason: reason?.rawValue)
    }
}
