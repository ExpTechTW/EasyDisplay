import Foundation
import Testing
@testable import EasyDisplay

@MainActor struct BoostTests {
    @Test func theSliderSpansTheBoostRange() {
        #expect(BuiltInDisplay.boostNits(forSlider: 1) == BuiltInDisplay.maxBoostNits)
        #expect(BuiltInDisplay.boostNits(forSlider: 0) == BuiltInDisplay.minBoostNits)
        // 600 nits, the panel's normal SDR maximum, sits about three quarters along.
        #expect(abs(BuiltInDisplay.slider(forBoostNits: 600) - 0.775) < 0.001)
    }

    @Test func sliderAndNitsRoundTrip() {
        for nits in stride(from: 10.0, through: 1000, by: 90) {
            #expect(abs(BuiltInDisplay.boostNits(forSlider: BuiltInDisplay.slider(forBoostNits: nits)) - nits) < 0.001)
        }
    }

    @Test func theThermalCeilingFallsWellBeforeThePanelIsHot() {
        #expect(BuiltInDisplay.thermalCeiling(forCelsius: 38) == BuiltInDisplay.maxBoostNits)
        #expect(BuiltInDisplay.thermalCeiling(forCelsius: 42) == BuiltInDisplay.maxBoostNits)
        #expect(BuiltInDisplay.thermalCeiling(forCelsius: 43.5) == 800)
        #expect(BuiltInDisplay.thermalCeiling(forCelsius: 45) == 600)
        #expect(BuiltInDisplay.thermalCeiling(forCelsius: 48) == 400)
        #expect(BuiltInDisplay.thermalCeiling(forCelsius: 70) == 400)
        let ceilings = stride(from: 30.0, through: 60, by: 0.5).map(BuiltInDisplay.thermalCeiling(forCelsius:))
        #expect(zip(ceilings, ceilings.dropFirst()).allSatisfy { $0 >= $1 })
    }

    @Test func rampsEaseEvenlyAndArrive() {
        func ramp(_ from: Double, _ to: Double, pace: BacklightDriver.Pace, seconds: Double) -> [Double] {
            var nits = from, steps = [from]
            for _ in 0..<Int(seconds * BacklightDriver.ticksPerSecond) {
                nits = BacklightDriver.step(from: nits, toward: to, fraction: pace.fraction)
                steps.append(nits)
            }
            return steps
        }
        // Dimming with the ambient light: after one time constant, 63% of the way on a log scale.
        let dim = ramp(800, 200, pace: .dim, seconds: BacklightDriver.Pace.dim.seconds)
        #expect(abs(Foundation.log(dim.last! / 800) / Foundation.log(200.0 / 800) - (1 - exp(-1))) < 0.01)
        // No step anywhere is a visible jump: under 2% of the brightness per tick.
        #expect(zip(dim, dim.dropFirst()).allSatisfy { abs($1 / $0 - 1) < 0.02 })
        #expect(zip(dim, dim.dropFirst()).allSatisfy { $1 <= $0 })
        // A key press arrives in well under half a second.
        #expect(ramp(400, 460, pace: .quick, seconds: 0.4).last == 460)
    }
}

struct AmbientLightTests {
    @Test func theCurveRisesWithTheLightAndReachesTheCeilingInDaylight() {
        let levels = [0.01, 0.5, 5, 30, 150, 400, 800, 2000, 5000, 8000, 20000].map(AmbientLight.nits(forLux:))
        #expect(zip(levels, levels.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(AmbientLight.nits(forLux: 20000) == 1000)
        #expect(AmbientLight.nits(forLux: 0) == AmbientLight.curve[0].nits)
    }

    @Test func theCurvePassesThroughItsPoints() {
        for point in AmbientLight.curve {
            #expect(abs(AmbientLight.nits(forLux: point.lux) - point.nits) < 0.001)
        }
    }
}
