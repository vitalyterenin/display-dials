import Testing
@testable import DisplayCore

private func environment(headroom: Double = 2) -> BoostSession.Environment {
    var value = BoostSession.Environment(); value.headroom = headroom; return value
}

@Test func preparationNeverBoostsBeforeHeadroomArrives() {
    var s = BoostSession(); s.start(now: 0, factor: 1.2)
    s.tick(now: 0.5, environment: environment(headroom: 1))
    #expect(s.phase == .preparing); #expect(s.effective == 1)
    s.receive(now: 1, factor: 1.2)
    s.tick(now: 1, environment: environment(headroom: 1.1))
    #expect(s.phase == .active); #expect(s.effective == 1.1)
}

@Test func preparationTimesOutAndCannotResume() {
    var s = BoostSession(); s.start(now: 0, factor: 1.1)
    for t in 1...5 { s.receive(now: Double(t), factor: 1.1); s.tick(now: Double(t), environment: environment(headroom: 1)) }
    #expect(s.reason == .noHeadroom)
    s.receive(now: 6, factor: 1.1); s.tick(now: 6, environment: environment())
    #expect(s.phase == .off)
}

@Test func sessionExpiresEvenWithHeartbeatsAndSliderChanges() {
    var s = BoostSession(); s.start(now: 0, factor: 1.1)
    for t in 1...30 { s.receive(now: Double(t), factor: t.isMultiple(of: 2) ? 1.1 : 1.2); s.tick(now: Double(t), environment: environment()) }
    #expect(s.reason == .timeout); #expect(s.effective == 1)
}

@Test func parentFailureAndLateHeartbeatFailClosed() {
    var s = BoostSession(); s.start(now: 0, factor: 1.1)
    s.tick(now: 0.2, environment: environment())
    s.receive(now: 2, factor: 1.2)
    #expect(s.reason == .heartbeat); #expect(s.phase == .off)
    var other = BoostSession(); other.start(now: 0, factor: 1.1)
    other.tick(now: 2, environment: environment())
    #expect(other.reason == .heartbeat)
}

@Test func headroomRecoveryDoesNotAutomaticallyIncreaseGain() {
    var s = BoostSession(); s.start(now: 0, factor: 1.2)
    s.tick(now: 0, environment: environment())
    s.tick(now: 0.2, environment: environment(headroom: 1.05))
    s.receive(now: 0.3, factor: 1.2)
    s.tick(now: 0.3, environment: environment())
    #expect(s.effective == 1.05)
    s.receive(now: 0.4, factor: 1.15)
    s.tick(now: 0.4, environment: environment())
    #expect(s.effective == 1.15)
}

@Test func dangerousConditionsStopAndStayOff() {
    let cases: [(BoostSession.Stop, (inout BoostSession.Environment) -> Void)] = [
        (.thermal, { $0.thermal = .fair }), (.sleeping, { $0.awake = false }),
        (.displayChanged, { $0.displayChanged = true }), (.renderer, { $0.rendererReady = false }),
        (.conflict, { $0.conflictingApp = true }), (.sessionInactive, { $0.sessionActive = false }),
        (.unsupported, { $0.supported = false }), (.invalidInput, { $0.headroom = .nan }),
        (.noHeadroom, { $0.headroom = 1 })
    ]
    for (reason, change) in cases {
        var s = BoostSession(); s.start(now: 0, factor: 1.2); s.tick(now: 0, environment: environment())
        var e = environment(); change(&e); s.tick(now: 0.1, environment: e)
        #expect(s.reason == reason); #expect(s.effective == 1)
        s.tick(now: 0.2, environment: environment()); #expect(s.phase == .off)
    }
}

@Test func requestsAreClampedAndInvalidRequestsStop() {
    var s = BoostSession(); s.start(now: 0, factor: 100); s.tick(now: 0, environment: environment())
    #expect(s.effective == 1.25)
    s.receive(now: 0.1, factor: .nan); #expect(s.reason == .invalidInput)
    s.start(now: 1, factor: 1.1); s.receive(now: 1.1, factor: 1); #expect(s.reason == .manual)
}

@Test func rendererPreparationIsBounded() {
    var s = BoostSession(); s.start(now: 0, factor: 1.1)
    var e = environment(); e.rendererReady = false
    for t in 0...4 {
        s.receive(now: Double(t), factor: 1.1); s.tick(now: Double(t), environment: e)
        #expect(s.phase == .preparing); #expect(s.effective == 1)
    }
    s.receive(now: 5, factor: 1.1); s.tick(now: 5, environment: e)
    #expect(s.reason == .renderer)
}

@Test func diagnosticCountdownCannotOverflow() {
    var s = BoostSession(); s.start(now: 10, factor: 1.1)
    #expect(s.report(now: .greatestFiniteMagnitude).remaining == 0)
    #expect(s.report(now: -.greatestFiniteMagnitude).remaining == 30)
    #expect(s.report(now: .nan).remaining == 0)
}
