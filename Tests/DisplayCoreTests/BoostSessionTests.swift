import Testing
@testable import DisplayCore

private func environment(headroom: Double = 2) -> BoostSession.Environment {
    var value = BoostSession.Environment(); value.headroom = headroom; return value
}

private func advance(_ s: inout BoostSession, from: Int, through: Int, factor: Double = 1.2,
                     headroom: Double = 2) {
    for i in from...through {
        let time = Double(i) / 5
        s.receive(now: time, factor: factor)
        s.tick(now: time, environment: environment(headroom: headroom))
    }
}

private func activeSession() -> BoostSession {
    var s = BoostSession(); s.start(now: 0, factor: 1.2)
    advance(&s, from: 0, through: 20)
    return s
}

@Test func preparationRequiresSettledHeadroom() {
    var s = BoostSession(); s.start(now: 0, factor: 1.2)
    advance(&s, from: 0, through: 4, headroom: 1)
    #expect(s.phase == .preparing); #expect(s.effective == 1)
    advance(&s, from: 5, through: 6, headroom: 1.05)
    advance(&s, from: 7, through: 9, headroom: 1.15)
    #expect(s.phase == .preparing); #expect(s.effective == 1)
    advance(&s, from: 10, through: 15)
    #expect(s.phase == .active); #expect(s.effective > 1)
}

@Test func unstableHeadroomNeverStartsBoost() {
    var s = BoostSession(); s.start(now: 0, factor: 1.2)
    for i in 0...25 {
        let t = Double(i) / 5
        s.receive(now: t, factor: 1.2)
        s.tick(now: t, environment: environment(headroom: i.isMultiple(of: 2) ? 1.05 : 1.15))
    }
    #expect(s.reason == .noHeadroom); #expect(s.effective == 1)
}

@Test func risingGainIsSlewLimited() {
    var s = BoostSession(); s.start(now: 0, factor: 1.25)
    var previous = 1.0
    for i in 0...25 {
        let t = Double(i) / 5
        s.receive(now: t, factor: 1.25); s.tick(now: t, environment: environment())
        #expect(s.effective >= previous)
        #expect(s.effective - previous <= BoostSession.risePerSecond * 0.2 + 0.000001)
        previous = s.effective
    }
    #expect(abs(s.effective - 1.25) < 0.000001)
}

@Test func headroomReductionIsImmediateAndRecoveryDoesNotRaiseGain() {
    var s = activeSession()
    #expect(abs(s.effective - 1.2) < 0.000001)
    s.tick(now: 4.1, environment: environment(headroom: 1.05))
    #expect(s.effective == 1.05)
    advance(&s, from: 21, through: 25)
    #expect(s.effective == 1.05)
    s.receive(now: 5.1, factor: 1.15)
    s.tick(now: 5.1, environment: environment())
    #expect(s.effective > 1.05); #expect(s.effective <= 1.075001)
}

@Test func preparationTimesOutAndCannotResume() {
    var s = BoostSession(); s.start(now: 0, factor: 1.1)
    advance(&s, from: 0, through: 25, factor: 1.1, headroom: 1)
    #expect(s.reason == .noHeadroom)
    s.receive(now: 6, factor: 1.1); s.tick(now: 6, environment: environment())
    #expect(s.phase == .off)
}

@Test func sessionExpiresEvenWithHeartbeatsAndSliderChanges() {
    var s = BoostSession(); s.start(now: 0, factor: 1.1)
    for t in 0...150 {
        let now = Double(t) / 5
        let factor = t < 10 || t.isMultiple(of: 2) ? 1.1 : 1.2
        s.receive(now: now, factor: factor); s.tick(now: now, environment: environment())
    }
    #expect(s.reason == .timeout); #expect(s.effective == 1)
}

@Test func parentFailureAndLateHeartbeatFailClosed() {
    var s = activeSession()
    s.receive(now: 6, factor: 1.2)
    #expect(s.reason == .heartbeat); #expect(s.phase == .off)
    var other = activeSession(); other.tick(now: 6, environment: environment())
    #expect(other.reason == .heartbeat)
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
        var s = activeSession(); var e = environment(); change(&e)
        s.tick(now: 4.1, environment: e)
        #expect(s.reason == reason); #expect(s.effective == 1)
        s.tick(now: 4.2, environment: environment()); #expect(s.phase == .off)
    }
}

@Test func requestsAreClampedAndInvalidRequestsStop() {
    var s = BoostSession(); s.start(now: 0, factor: 100)
    advance(&s, from: 0, through: 25, factor: 100)
    #expect(abs(s.effective - 1.25) < 0.000001)
    s.receive(now: 5.1, factor: .nan); #expect(s.reason == .invalidInput)
    s.start(now: 6, factor: 1.1); s.receive(now: 6.1, factor: 1); #expect(s.reason == .manual)
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
