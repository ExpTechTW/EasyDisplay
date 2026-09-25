import CoreGraphics
import Foundation

/// Looks up a symbol in a system framework. Returns nil when this macOS doesn't export it.
func systemSymbol<T>(_ path: String, _ name: String, as _: T.Type) -> T? {
    guard let handle = dlopen(path, RTLD_NOW), let pointer = dlsym(handle, name) else { return nil }
    return unsafeBitCast(pointer, to: T.self)
}

/// Private DisplayServices API: the brightness slider and auto-brightness that System Settings uses.
///
/// Every call is synchronous XPC to corebrightnessd, which can stop replying. Call these
/// through `withTimeout`, never directly on the main thread.
enum DisplayServices {
    private static let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"

    private typealias GetFloat = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFloat = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias GetBool = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Bool>) -> Int32
    private typealias SetBool = @convention(c) (CGDirectDisplayID, Bool) -> Int32
    private typealias Query = @convention(c) (CGDirectDisplayID) -> Bool

    private static let canChange = systemSymbol(path, "DisplayServicesCanChangeBrightness", as: Query.self)
    private static let getBrightness = systemSymbol(path, "DisplayServicesGetBrightness", as: GetFloat.self)
    private static let setBrightness = systemSymbol(path, "DisplayServicesSetBrightness", as: SetFloat.self)
    private static let getAuto = systemSymbol(path, "DisplayServicesAmbientLightCompensationEnabled", as: GetBool.self)
    private static let setAuto = systemSymbol(path, "DisplayServicesEnableAmbientLightCompensation", as: SetBool.self)

    static func canChangeBrightness(_ display: CGDirectDisplayID) -> Bool {
        canChange?(display) ?? false
    }

    /// Slider position, 0…1.
    static func brightness(_ display: CGDirectDisplayID) -> Double? {
        var value: Float = 0
        guard let getBrightness, getBrightness(display, &value) == 0 else { return nil }
        return Double(value)
    }

    @discardableResult
    static func setBrightness(_ display: CGDirectDisplayID, _ value: Double) -> Bool {
        setBrightness?(display, Float(min(max(value, 0), 1))) == 0
    }

    static func autoBrightness(_ display: CGDirectDisplayID) -> Bool? {
        var value = false
        guard let getAuto, getAuto(display, &value) == 0 else { return nil }
        return value
    }

    @discardableResult
    static func setAutoBrightness(_ display: CGDirectDisplayID, _ enabled: Bool) -> Bool {
        setAuto?(display, enabled) == 0
    }
}

// MARK: - Timeouts

/// Ensures a continuation is resumed exactly once when two callbacks race.
private final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func claim() -> Bool {
        lock.withLock {
            defer { resumed = true }
            return !resumed
        }
    }
}

/// Runs a blocking call on a background queue and gives up after `seconds`.
/// The call itself keeps running if it hangs; only the caller stops waiting.
func withTimeout<T: Sendable>(_ seconds: Double = 2, _ body: @escaping @Sendable () -> T) async -> T? {
    await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
        let gate = ResumeGate()
        DispatchQueue.global(qos: .userInitiated).async {
            let value = body()
            if gate.claim() { continuation.resume(returning: value) }
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds) {
            if gate.claim() { continuation.resume(returning: nil) }
        }
    }
}
