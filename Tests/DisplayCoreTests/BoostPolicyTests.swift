import Testing
@testable import DisplayCore

private func decision(_ requested: Double = 1.25, enabled: Bool = true,
                      validated: Bool = true, builtIn: Bool = true, awake: Bool = true,
                      thermal: BoostPolicy.Thermal = .nominal, headroom: Double = 2) -> BoostPolicy.Decision {
    BoostPolicy().evaluate(requested: requested, enabled: enabled, rendererReady: validated,
                           builtIn: builtIn, awake: awake, thermal: thermal, currentHeadroom: headroom)
}

@Test func rendererUnavailableCannotBoost() {
    let result = decision(validated: false)
    #expect(result.multiplier == 1)
    #expect(result.block == .rendererUnavailable)
}

@Test func neverExceedsCurrentHeadroomOrCeiling() {
    #expect(decision(3, headroom: 1.1).multiplier == 1.1)
    #expect(decision(3, headroom: 4).multiplier == 1.25)
    #expect(decision(-4).multiplier == 1)
    #expect(decision(headroom: 1).block == .noHeadroom)
}

@Test func invalidReadingsFailClosed() {
    for invalid in [Double.nan, .infinity, -.infinity] {
        #expect(decision(invalid).multiplier == 1)
        #expect(decision(headroom: invalid).block == .invalidInput)
    }
}

@Test func everyNonNominalThermalStateBlocksBoost() {
    for thermal in [BoostPolicy.Thermal.fair, .serious, .critical, .unknown] {
        #expect(decision(thermal: thermal).block == .thermalPressure)
        #expect(decision(thermal: thermal).multiplier == 1)
    }
}

@Test func inactiveOrUnsupportedDisplayNeverBoosts() {
    #expect(decision(enabled: false).block == .disabled)
    #expect(decision(awake: false).block == .sleeping)
    #expect(decision(builtIn: false).block == .unsupportedDisplay)
}
