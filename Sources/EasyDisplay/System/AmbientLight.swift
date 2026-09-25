import Foundation

/// Ambient light in lux, as corebrightnessd aggregates it from the ambient light sensor. It keeps sampling while
/// the system's auto-brightness is off, which is what boosted auto-brightness relies on.
enum AmbientLight {
    nonisolated(unsafe) private static let client: NSObject? = {
        dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW)
        return (NSClassFromString("BrightnessSystemClient") as? NSObject.Type)?.init()
    }()

    static func lux() async -> Double? {
        await withTimeout { () -> Double? in
            let selector = NSSelectorFromString("copyPropertyForKey:")
            guard let client, client.responds(to: selector) else { return nil }
            typealias Copy = @convention(c) (NSObject, Selector, NSString) -> Unmanaged<AnyObject>?
            let copy = unsafeBitCast(client.method(for: selector), to: Copy.self)
            return (copy(client, selector, "AggregatedLux")?.takeRetainedValue() as? NSNumber)?.doubleValue
        } ?? nil
    }

    /// Boosted SDR white for an ambient light level, before the user's preference: dim rooms stay comfortable,
    /// daylight reaches the 1000-nit ceiling (the M4 panel's own outdoor mode saturates at 8000 lux).
    /// Interpolated in log(lux) between these points.
    static let curve: [(lux: Double, nits: Double)] = [
        (0.1, 25), (1, 45), (10, 90), (50, 160), (200, 260), (500, 360),
        (1000, 450), (3000, 650), (6000, 850), (10000, 1000),
    ]

    private static let curveLog10Lux = curve.map { log10($0.lux) }

    static func nits(forLux lux: Double) -> Double {
        nits(atLog10Lux: log10(max(lux, curve[0].lux)))
    }

    /// The same, from log10(lux), which is what the curve is interpolated in.
    static func nits(atLog10Lux x: Double) -> Double {
        guard x > curveLog10Lux[0] else { return curve[0].nits }
        guard let upper = curveLog10Lux.firstIndex(where: { $0 >= x }) else { return curve[curve.count - 1].nits }
        let a = upper - 1
        return curve[a].nits + (curve[upper].nits - curve[a].nits) * (x - curveLog10Lux[a]) / (curveLog10Lux[upper] - curveLog10Lux[a])
    }
}
