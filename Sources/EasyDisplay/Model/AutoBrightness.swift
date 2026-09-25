import Foundation

/// Which ambient light level auto-brightness follows, from the sensor's readings, after AOSP's
/// AutomaticBrightnessController: a fast (2 s) and a slow (10 s) average must both have moved past a hysteresis
/// band around the current level (10% up, 20% down) for a debounce time (4 s up, 8 s down) before the level changes.
/// Brightness then only moves on a real change in the room, never on sensor noise or a hand passing the sensor.
struct AmbientFilter: Sendable {
    static let fastWindow: TimeInterval = 2
    static let slowWindow: TimeInterval = 10
    static let brightenRatio = 1.10
    static let darkenRatio = 0.80
    /// Around a dark room's 1 lux, a ratio alone would react to every flicker of the sensor.
    static let minimumStep = 1.0
    static let brightenDebounce: TimeInterval = 4
    static let darkenDebounce: TimeInterval = 8

    private(set) var ambient: Double?
    /// The last ten seconds, as ln(lux).
    private var samples: [(time: Date, log: Double)] = []
    private var brightenSince: Date?
    private var darkenSince: Date?

    /// Takes a reading; true when the level followed changed.
    mutating func add(_ lux: Double, at time: Date = .now) -> Bool {
        let lux = max(lux, 0)
        samples.append((time, Foundation.log(max(lux, 0.01))))
        samples.removeAll { time.timeIntervalSince($0.time) > Self.slowWindow }
        guard let current = ambient else {
            ambient = lux
            return true
        }
        // Geometric means: light is perceived, and varies, on a log scale. The reading just taken is always in both.
        var fastSum = 0.0, fastCount = 0.0, slowSum = 0.0
        for sample in samples {
            slowSum += sample.log
            if time.timeIntervalSince(sample.time) <= Self.fastWindow {
                fastSum += sample.log
                fastCount += 1
            }
        }
        let fast = exp(fastSum / fastCount), slow = exp(slowSum / Double(samples.count))

        let brighter = min(fast, slow)
        if brighter >= current * Self.brightenRatio, brighter >= current + Self.minimumStep {
            let since = brightenSince ?? time
            brightenSince = since
            darkenSince = nil
            return time.timeIntervalSince(since) >= Self.brightenDebounce && commit(fast)
        }
        let darker = max(fast, slow)
        if darker <= current * Self.darkenRatio, darker <= current - Self.minimumStep {
            let since = darkenSince ?? time
            darkenSince = since
            brightenSince = nil
            return time.timeIntervalSince(since) >= Self.darkenDebounce && commit(fast)
        }
        brightenSince = nil
        darkenSince = nil
        return false
    }

    private mutating func commit(_ lux: Double) -> Bool {
        ambient = lux
        brightenSince = nil
        darkenSince = nil
        return true
    }
}

/// A brightness the user chose at an ambient light level, while boosted auto-brightness was on.
struct LearnedPoint: Codable, Sendable, Equatable {
    var lux: Double
    var nits: Double
    var date: Date
}

/// The lux → nits curve boosted auto-brightness follows: `AmbientLight.curve`, bent towards the brightnesses the user
/// chose, each only near the light level it was chosen at.
///
/// As Android since Pie, an adjustment is a data point for that lighting, not a global offset: turning it up in a dark
/// room doesn't brighten a sunny one. Each point is a control point the curve passes through, as AOSP inserts the
/// user's point into its spline. In log-brightness, how far each point is from the default is interpolated linearly
/// (in decades of lux) between neighbouring points, and past the outermost ones fades back to the default with a
/// Gaussian (σ = 0.6 decades: a point at 100 lux still moves 300 lux by 60%, and 1000 lux by 1%). Then, as AOSP's
/// smoothCurve does from the user's point outward, the curve is made non-decreasing (a brighter room is never dimmer)
/// starting from the newest point, which therefore stays exact: when an older choice contradicts it, the older one
/// gives way.
struct AutoBrightnessCurve: Sendable, Equatable {
    static let spread = 0.6
    static let maximumPoints = 8
    /// A new point replaces an old one within this many decades of lux (about ×2), as a fresh choice for the same
    /// lighting.
    static let replaceWithin = 0.35
    /// Evaluated on this grid of log10(lux), -1…5 in steps of 0.05, so the monotone curve is computed once per
    /// change, not per frame.
    private static let gridStart = -1.0, gridStep = 0.05, gridCount = 121

    private(set) var points: [LearnedPoint]
    /// ln(nits) at each grid point.
    private var table: [Double] = []

    init(points: [LearnedPoint] = []) {
        self.points = Array(points.suffix(Self.maximumPoints))
        table = Self.build(self.points)
    }

    static func defaultNits(forLux lux: Double) -> Double {
        AmbientLight.nits(forLux: lux)
    }

    private static func log10Lux(_ lux: Double) -> Double {
        log10(max(lux, 0.1))
    }

    func nits(forLux lux: Double) -> Double {
        let position = min(max((Self.log10Lux(lux) - Self.gridStart) / Self.gridStep, 0), Double(Self.gridCount - 1))
        let lower = min(Int(position), Self.gridCount - 2)
        return exp(table[lower] + (table[lower + 1] - table[lower]) * (position - Double(lower)))
    }

    /// Whether a choice was made for lighting like `lux`: one a new choice there would replace.
    func hasPoint(near lux: Double) -> Bool {
        let x = Self.log10Lux(lux)
        return points.contains { abs(Self.log10Lux($0.lux) - x) <= Self.replaceWithin }
    }

    /// Takes the brightness the user settled on at `lux`.
    mutating func learn(lux: Double, nits: Double, at date: Date = .now) {
        let x = Self.log10Lux(lux)
        points.removeAll { abs(Self.log10Lux($0.lux) - x) <= Self.replaceWithin }
        points.append(LearnedPoint(lux: lux, nits: min(max(nits, BuiltInDisplay.minBoostNits), BuiltInDisplay.maxBoostNits), date: date))
        if points.count > Self.maximumPoints { points.removeFirst(points.count - Self.maximumPoints) }
        table = Self.build(points)
    }

    mutating func reset() {
        points = []
        table = Self.build(points)
    }

    private static func build(_ points: [LearnedPoint]) -> [Double] {
        let low = Foundation.log(BuiltInDisplay.minBoostNits), high = Foundation.log(BuiltInDisplay.maxBoostNits)
        let pulls = points.map { point in
            let x = log10Lux(point.lux)
            return (x: x, residual: Foundation.log(point.nits) - Foundation.log(AmbientLight.nits(atLog10Lux: x)))
        }.sorted { $0.x < $1.x }
        func residual(at x: Double) -> Double {
            guard let first = pulls.first, let last = pulls.last else { return 0 }
            if x <= first.x { return first.residual * fade(x - first.x) }
            if x >= last.x { return last.residual * fade(x - last.x) }
            let upper = pulls.firstIndex { $0.x >= x } ?? pulls.count - 1
            let a = pulls[upper - 1], b = pulls[upper]
            return a.residual + (b.residual - a.residual) * (x - a.x) / max(b.x - a.x, 1e-9)
        }
        func fade(_ distance: Double) -> Double {
            let z = distance / spread
            return exp(-0.5 * z * z)
        }
        var curve = (0..<gridCount).map { i -> Double in
            let x = gridStart + Double(i) * gridStep
            return min(max(Foundation.log(AmbientLight.nits(atLog10Lux: x)) + residual(at: x), low), high)
        }
        guard let newest = points.max(by: { $0.date < $1.date }) else { return curve }
        let anchor = min(max(Int(((log10Lux(newest.lux) - gridStart) / gridStep).rounded()), 0), gridCount - 1)
        for i in stride(from: anchor + 1, to: gridCount, by: 1) { curve[i] = max(curve[i], curve[i - 1]) }
        for i in stride(from: anchor - 1, through: 0, by: -1) { curve[i] = min(curve[i], curve[i + 1]) }
        return curve
    }
}
