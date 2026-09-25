import Foundation
import Testing
@testable import EasyDisplay

struct AmbientFilterTests {
    private func feed(_ filter: inout AmbientFilter, _ lux: Double, from start: Int, seconds: Int, base: Date) -> [Int] {
        (start..<start + seconds).filter { filter.add(lux, at: base.addingTimeInterval(TimeInterval($0))) }
    }

    @Test func noiseInsideTheBandIsIgnored() {
        var filter = AmbientFilter()
        let base = Date(timeIntervalSince1970: 0)
        let first = filter.add(100, at: base)
        #expect(first)
        // ±8% noise for a minute: never past 10% up or 20% down.
        var changes = 0
        for second in 1...60 where filter.add(second.isMultiple(of: 2) ? 108 : 93, at: base.addingTimeInterval(TimeInterval(second))) {
            changes += 1
        }
        #expect(changes == 0)
        #expect(filter.ambient == 100)
    }

    @Test func aBriefChangeIsIgnoredAndARealOneFollowed() {
        var filter = AmbientFilter()
        let base = Date(timeIntervalSince1970: 0)
        _ = filter.add(100, at: base)
        // A hand over the sensor for two seconds.
        let covered = feed(&filter, 10, from: 1, seconds: 2, base: base)
        let uncovered = feed(&filter, 100, from: 3, seconds: 20, base: base)
        #expect(covered.isEmpty && uncovered.isEmpty)
        // A lamp switched on: followed once it has lasted the brightening debounce, not before.
        let brightened = feed(&filter, 400, from: 23, seconds: 20, base: base)
        #expect(brightened.count == 1)
        #expect(brightened.first.map { $0 - 23 } ?? 0 >= Int(AmbientFilter.brightenDebounce))
        #expect(abs((filter.ambient ?? 0) - 400) < 0.01)
    }

    @Test func darkeningWaitsLongerThanBrightening() {
        var filter = AmbientFilter()
        let base = Date(timeIntervalSince1970: 0)
        _ = filter.add(400, at: base)
        let darkened = feed(&filter, 50, from: 1, seconds: 30, base: base)
        #expect(darkened.count == 1)
        #expect(darkened.first.map { $0 - 1 } ?? 0 >= Int(AmbientFilter.darkenDebounce))
    }

    @Test func aDarkRoomNeedsMoreThanARatio() {
        var filter = AmbientFilter()
        let base = Date(timeIntervalSince1970: 0)
        _ = filter.add(0.8, at: base)
        // 0.8 → 1.2 lux is +50%, but under the 1-lux minimum step: the sensor's floor noise.
        let changes = feed(&filter, 1.2, from: 1, seconds: 30, base: base)
        #expect(changes.isEmpty)
    }
}

struct AutoBrightnessCurveTests {
    @Test func withoutChoicesItIsTheDefault() {
        let curve = AutoBrightnessCurve()
        for lux in [0.5, 5, 50, 500, 5000] {
            #expect(abs(curve.nits(forLux: lux) / AutoBrightnessCurve.defaultNits(forLux: lux) - 1) < 0.02)
        }
    }

    @Test func aChoiceIsMetWhereItWasMadeAndFadesAway() {
        var curve = AutoBrightnessCurve()
        curve.learn(lux: 1, nits: 400)
        #expect(abs(curve.nits(forLux: 1) / 400 - 1) < 0.05)
        // Brighter in a dark room doesn't mean brighter in daylight.
        #expect(abs(curve.nits(forLux: 5000) / AutoBrightnessCurve.defaultNits(forLux: 5000) - 1) < 0.02)
        // A brighter room than the one it was chosen in is at least as bright as the choice.
        #expect(curve.nits(forLux: 30) >= 400 * 0.99)
        // A darker one fades back towards the default.
        #expect(curve.nits(forLux: 0.1) < 200)
    }

    @Test func aBrighterRoomIsNeverDimmer() {
        var curve = AutoBrightnessCurve()
        // Contradictory choices: very bright in a dim room, then dim in a bright one. The newer one is met exactly;
        // the older gives way.
        curve.learn(lux: 5, nits: 900)
        curve.learn(lux: 500, nits: 150, at: .now.addingTimeInterval(1))
        #expect(abs(curve.nits(forLux: 500) / 150 - 1) < 0.05)
        let levels = stride(from: -1.0, through: 4.2, by: 0.1).map { curve.nits(forLux: pow(10, $0)) }
        #expect(zip(levels, levels.dropFirst()).allSatisfy { $1 >= $0 - 0.001 })
        #expect(levels.allSatisfy { $0 >= BuiltInDisplay.minBoostNits && $0 <= BuiltInDisplay.maxBoostNits })
    }

    @Test func aNewChoiceReplacesTheOldOneForTheSameLight() {
        var curve = AutoBrightnessCurve()
        curve.learn(lux: 100, nits: 300)
        curve.learn(lux: 150, nits: 500)
        #expect(curve.points.count == 1)
        #expect(abs(curve.nits(forLux: 150) / 500 - 1) < 0.05)
        curve.learn(lux: 2000, nits: 800)
        #expect(curve.points.count == 2)
        for lux in [0.2, 0.5, 2, 5, 20, 50, 200, 500, 5000, 10000] { curve.learn(lux: lux, nits: 300) }
        #expect(curve.points.count == AutoBrightnessCurve.maximumPoints)
    }
}
