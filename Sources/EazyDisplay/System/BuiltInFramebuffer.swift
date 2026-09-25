import Foundation
import IOKit

/// Backlight properties on the built-in panel's IOMobileFramebufferShim, in 16.16 fixed-point nits.
///
/// Writing them drives the backlight directly and bypasses corebrightnessd. This is the same
/// technique as BetterDisplay's "direct upscaling". Pixels are untouched, so colors stay exact.
struct BuiltInFramebuffer: Sendable {
    static let indicatorCapKey = "IOMFBIndicatorNitsCap"
    static let backlightCapKey = "BLNitsCap"
    static let physicalLimitKey = "limit_max_physical_brightness"
    static let levelKey = "IOMFBBrightnessLevel"
    /// Caps are written before the level, in this order, as BetterDisplay does.
    static let capKeys = [indicatorCapKey, backlightCapKey, physicalLimitKey]

    let service: io_service_t

    /// The built-in panel's shim is the only one without an "external" property.
    /// The service is kept for the lifetime of the app.
    static func find() -> BuiltInFramebuffer? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMobileFramebufferShim"), &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            let external = IORegistryEntryCreateCFProperty(service, "external" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Bool ?? false
            if !external { return BuiltInFramebuffer(service: service) }
            IOObjectRelease(service)
        }
        return nil
    }

    func raw(_ key: String) -> Int? {
        (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber)?.intValue
    }

    func nits(_ key: String) -> Double? {
        raw(key).map { Double($0) / 65536 }
    }

    @discardableResult
    func setRaw(_ key: String, _ value: Int) -> Bool {
        IORegistryEntrySetCFProperty(service, key as CFString, NSNumber(value: value)) == KERN_SUCCESS
    }

    @discardableResult
    func setNits(_ key: String, _ nits: Double) -> Bool {
        setRaw(key, Int((nits * 65536).rounded()))
    }

    /// Raises the two outer caps to `nits` where they're lower. They normally sit at the panel's 1600 nits, so this is
    /// only needed once, and again after something else rewrote the backlight.
    func raiseOuterCaps(to nits: Double) {
        for key in [Self.indicatorCapKey, Self.physicalLimitKey] where (self.nits(key) ?? 0) < nits {
            setNits(key, nits)
        }
    }

    /// Drives the backlight to `nits`, under outer caps already raised: the backlight cap, then the level.
    @discardableResult
    func drive(nits: Double) -> Bool {
        setNits(Self.backlightCapKey, nits) && setNits(Self.levelKey, nits)
    }
}
