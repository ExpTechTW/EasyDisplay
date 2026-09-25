// Minimal test of "direct upscaling" on the built-in XDR display: switch to the
// "Apple Display (P3-600 nits)" preset, disable auto-brightness, then write the
// backlight caps and level straight to the framebuffer's registry properties
// (16.16 fixed-point nits), in the same order BetterDisplay does. Pixels are
// untouched; only the backlight changes.
//
// Build: swiftc -O Experiments/DirectUpscalingTest.swift -o /tmp/direct-upscaling-test
// Run:   /tmp/direct-upscaling-test status
//        /tmp/direct-upscaling-test test <nits> [seconds] [p3-600|xdr]
//        /tmp/direct-upscaling-test ramp <hold-seconds> <p3-600|xdr> <nits>...   (full-white screen, stops on throttle or heat)
//
// Everything is restored on exit, including Ctrl-C and SIGTERM. A second Ctrl-C
// during restore force-quits.

import AppKit
import CoreGraphics
import Foundation
import IOKit

// MARK: - Private framework bindings

private func framework(_ name: String) -> UnsafeMutableRawPointer? {
    dlopen("/System/Library/PrivateFrameworks/\(name).framework/\(name)", RTLD_NOW)
}

private func symbol<T>(_ handle: UnsafeMutableRawPointer?, _ name: String, as _: T.Type) -> T {
    guard let pointer = dlsym(handle, name) else { fatalError("missing symbol \(name)") }
    return unsafeBitCast(pointer, to: T.self)
}

private let displayServices = framework("DisplayServices")
_ = framework("MonitorPanel")
_ = framework("CoreBrightness")

private let getBrightness = symbol(displayServices, "DisplayServicesGetBrightness",
                                   as: (@convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32).self)
private let setBrightness = symbol(displayServices, "DisplayServicesSetBrightness",
                                   as: (@convention(c) (CGDirectDisplayID, Float) -> Int32).self)
private let getAutoBrightness = symbol(displayServices, "DisplayServicesAmbientLightCompensationEnabled",
                                       as: (@convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Bool>) -> Int32).self)
private let setAutoBrightness = symbol(displayServices, "DisplayServicesEnableAmbientLightCompensation",
                                       as: (@convention(c) (CGDirectDisplayID, Bool) -> Int32).self)

private func call<T>(_ object: NSObject, _ selector: String, as _: T.Type) -> T {
    let sel = NSSelectorFromString(selector)
    guard object.responds(to: sel) else { fatalError("\(type(of: object)) does not respond to \(selector)") }
    return unsafeBitCast(object.method(for: sel), to: T.self)
}

/// DisplayServices and CoreBrightness calls are synchronous XPC to corebrightnessd,
/// which can stop replying. Never let that hang the test.
private func withTimeout<T>(_ seconds: Double, _ body: @escaping () -> T) -> T? {
    let semaphore = DispatchSemaphore(value: 0)
    var result: T?
    DispatchQueue.global().async {
        result = body()
        semaphore.signal()
    }
    return semaphore.wait(timeout: .now() + seconds) == .success ? result : nil
}

// MARK: - Built-in display

private let builtInID: CGDirectDisplayID = {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count)
    guard let id = ids.prefix(Int(count)).first(where: { CGDisplayIsBuiltin($0) != 0 }) else {
        fatalError("no built-in display")
    }
    return id
}()

private func readSlider() -> Float? {
    withTimeout(2) { () -> Float? in
        var value: Float = -1
        return getBrightness(builtInID, &value) == 0 ? value : nil
    } ?? nil
}

private func readAutoBrightness() -> Bool? {
    withTimeout(2) { () -> Bool? in
        var value = false
        return getAutoBrightness(builtInID, &value) == 0 ? value : nil
    } ?? nil
}

@discardableResult
private func writeSlider(_ value: Float) -> Bool {
    withTimeout(2) { setBrightness(builtInID, value) == 0 } ?? false
}

@discardableResult
private func writeAutoBrightness(_ enabled: Bool) -> Bool {
    withTimeout(2) { setAutoBrightness(builtInID, enabled) == 0 } ?? false
}

/// The IOMobileFramebufferShim of the built-in panel is the only one without an "external" property.
private let framebuffer: io_service_t = {
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMobileFramebufferShim"), &iterator) == KERN_SUCCESS else {
        fatalError("IOServiceGetMatchingServices failed")
    }
    defer { IOObjectRelease(iterator) }
    while case let service = IOIteratorNext(iterator), service != 0 {
        let external = IORegistryEntryCreateCFProperty(service, "external" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool ?? false
        if !external { return service }
        IOObjectRelease(service)
    }
    fatalError("built-in IOMobileFramebufferShim not found")
}()

// Write order matches BetterDisplay's AppleBuiltInDirectController: caps first, level last.
private let indicatorCapKey = "IOMFBIndicatorNitsCap"
private let backlightCapKey = "BLNitsCap"
private let physicalLimitKey = "limit_max_physical_brightness"
private let levelKey = "IOMFBBrightnessLevel"
private let capKeys = [indicatorCapKey, backlightCapKey, physicalLimitKey]

private func readRaw(_ key: String) -> Int? {
    (IORegistryEntryCreateCFProperty(framebuffer, key as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue() as? NSNumber)?.intValue
}

private func readNits(_ key: String) -> Double? {
    readRaw(key).map { Double($0) / 65536 }
}

private func writeRaw(_ key: String, _ raw: Int) -> kern_return_t {
    IORegistryEntrySetCFProperty(framebuffer, key as CFString, NSNumber(value: raw))
}

private func writeNits(_ key: String, _ nits: Double) -> kern_return_t {
    writeRaw(key, Int((nits * 65536).rounded()))
}

// MARK: - SMC sensors (backlight power and display temperatures)

/// AppleSMC user client, readable without root. The request/response is the classic
/// 80-byte SMCKeyData struct: key @0, keyInfo.dataSize @28, keyInfo.dataType @32,
/// result @40, data8 (command) @42, data32 @44, bytes @48.
private let smcConnection: io_connect_t? = {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }
    var connection: io_connect_t = 0
    return IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS ? connection : nil
}()

private func fourCC(_ string: String) -> UInt32 {
    string.utf8.reduce(0) { $0 << 8 | UInt32($1) }
}

private func smcCall(_ input: [UInt8]) -> [UInt8]? {
    guard let connection = smcConnection else { return nil }
    var output = [UInt8](repeating: 0, count: 80)
    var outputSize = output.count
    let result = input.withUnsafeBytes { inBytes in
        output.withUnsafeMutableBytes { outBytes in
            IOConnectCallStructMethod(connection, 2, inBytes.baseAddress, inBytes.count, outBytes.baseAddress, &outputSize)
        }
    }
    return result == KERN_SUCCESS && output[40] == 0 ? output : nil
}

private func uint32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
    bytes[offset..<offset + 4].reversed().reduce(0) { $0 << 8 | UInt32($1) }
}

private func smcRequest(command: UInt8, key: UInt32 = 0, index: UInt32 = 0, dataSize: UInt32 = 0) -> [UInt8]? {
    var input = [UInt8](repeating: 0, count: 80)
    withUnsafeBytes(of: key) { input.replaceSubrange(0..<4, with: $0) }
    withUnsafeBytes(of: dataSize) { input.replaceSubrange(28..<32, with: $0) }
    input[42] = command
    withUnsafeBytes(of: index) { input.replaceSubrange(44..<48, with: $0) }
    return smcCall(input)
}

private func smcFloat(_ key: UInt32) -> Double? {
    guard let info = smcRequest(command: 9, key: key),
          uint32(info, at: 32) == fourCC("flt "), uint32(info, at: 28) == 4,
          let data = smcRequest(command: 5, key: key, dataSize: 4) else { return nil }
    return Double(Float(bitPattern: uint32(data, at: 48)))
}

/// Every float SMC key whose name starts with `prefix`.
private func smcKeys(prefix: String) -> [String] {
    guard let count = smcRequest(command: 5, key: fourCC("#KEY"), dataSize: 4) else { return [] }
    let total = count[48..<52].reduce(0) { $0 << 8 | UInt32($1) }  // big-endian ui32
    return (0..<total).compactMap { index -> String? in
        guard let entry = smcRequest(command: 8, index: index) else { return nil }
        let key = uint32(entry, at: 0)
        let name = String(bytes: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: key >> $0) }, encoding: .ascii) ?? ""
        return name.hasPrefix(prefix) && smcFloat(key) != nil ? name : nil
    }
}

/// Display backlight power in watts.
private let backlightPowerKey = fourCC("PDBR")
private let displayTemperatureKeys: [(name: String, key: UInt32)] = smcKeys(prefix: "TD").map { ($0, fourCC($0)) }

private func backlightWatts() -> Double? {
    smcFloat(backlightPowerKey)
}

private func displayTemperatures() -> [String: Double] {
    var result: [String: Double] = [:]
    for (name, key) in displayTemperatureKeys { result[name] = smcFloat(key) }
    return result
}

// MARK: - Presets (MonitorPanel) and CoreBrightness state

private let builtInPanelDisplay: NSObject = {
    let managerClass = NSClassFromString("MPDisplayMgr") as! NSObject.Type
    let displays = managerClass.init().value(forKey: "displays") as! [NSObject]
    guard let display = displays.first(where: { ($0.value(forKey: "displayName") as? String)?.contains("Built-in") == true })
    else { fatalError("MonitorPanel built-in display not found") }
    return display
}()

private func presets() -> [NSObject] {
    (builtInPanelDisplay.value(forKey: "presets") as! [NSObject]).filter { $0.value(forKey: "isValid") as? Bool == true }
}

private func activePreset() -> NSObject {
    builtInPanelDisplay.value(forKey: "activePreset") as! NSObject
}

private func presetName(_ preset: NSObject) -> String {
    preset.value(forKey: "presetName") as? String ?? "?"
}

@discardableResult
private func activate(_ preset: NSObject) -> Bool {
    let setActive = call(builtInPanelDisplay, "setActivePreset:",
                         as: (@convention(c) (NSObject, Selector, NSObject) -> Bool).self)
    return setActive(builtInPanelDisplay, NSSelectorFromString("setActivePreset:"), preset)
}

private let brightnessClient: NSObject = (NSClassFromString("BrightnessSystemClient") as! NSObject.Type).init()

private func coreBrightness(_ key: String) -> String {
    let copy = call(brightnessClient, "copyPropertyForKey:",
                    as: (@convention(c) (NSObject, Selector, NSString) -> Unmanaged<AnyObject>?).self)
    let value = withTimeout(2) {
        copy(brightnessClient, NSSelectorFromString("copyPropertyForKey:"), key as NSString)?.takeRetainedValue()
    }
    guard let value else { return "timeout" }
    guard let value else { return "nil" }
    if let number = value as? NSNumber { return String(format: "%.1f", number.doubleValue) }
    return "\(value)"
}

private func format(_ value: Double?, _ decimals: Int = 1) -> String {
    value.map { String(format: "%.\(decimals)f", $0) } ?? "nil"
}

private func status(_ tag: String) {
    let slider = readSlider().map { String(format: "%.3f", $0) } ?? "timeout"
    let auto = readAutoBrightness().map { "\($0)" } ?? "timeout"
    print("[\(tag)] preset=\"\(presetName(activePreset()))\" auto=\(auto) slider=\(slider) "
        + "Level=\(format(readNits(levelKey))) BLNitsCap=\(format(readNits(backlightCapKey))) "
        + "PhysLimit=\(format(readNits(physicalLimitKey))) IndicatorCap=\(format(readNits(indicatorCapKey))) "
        + "NitsPhysical=\(coreBrightness("NitsPhysical")) EDRHeadroom=\(coreBrightness("EDRHeadroom")) "
        + "BacklightW=\(format(backlightWatts(), 2))")
}

// MARK: - Preflight

/// These apps drive the same backlight properties and fight the test.
private let conflictingApps = ["BetterDisplay", "Lunar", "BrightIntosh", "MonitorControl"]

private func preflight() -> Bool {
    let running = NSWorkspace.shared.runningApplications.compactMap(\.localizedName).filter(conflictingApps.contains)
    if !running.isEmpty {
        print("quit these first, they also control brightness: \(running.joined(separator: ", "))")
        return false
    }
    if readSlider() == nil {
        print("corebrightnessd is not responding; restart it with: sudo killall corebrightnessd")
        return false
    }
    return true
}

// MARK: - Restore

private struct SavedState {
    let preset: NSObject
    let slider: Float
    let autoBrightness: Bool
    let caps: [String: Int]
}

private var saved: SavedState?
private let restoreLock = NSLock()

/// Returns false if another restore is already running.
@discardableResult
private func restore() -> Bool {
    guard restoreLock.try() else { return false }
    defer { restoreLock.unlock() }
    guard let state = saved else { return true }
    saved = nil
    print("restoring…")
    // Caps in reverse write order, before the preset switch rewrites the level.
    for key in capKeys.reversed() {
        if let raw = state.caps[key] { _ = writeRaw(key, raw) }
    }
    // Switching presets resets the slider, so the slider must be restored last.
    activate(state.preset)
    Thread.sleep(forTimeInterval: 3)
    writeAutoBrightness(state.autoBrightness)
    // Nudging the slider makes corebrightnessd recompute and rewrite the backlight level.
    writeSlider(max(0, state.slider - 0.05))
    Thread.sleep(forTimeInterval: 0.5)
    writeSlider(state.slider)
    Thread.sleep(forTimeInterval: 3)
    status("restored")
    return true
}

private var signalSources: [DispatchSourceSignal] = []

private func installSignalHandlers() {
    for sig in [SIGINT, SIGTERM, SIGHUP, SIGPIPE] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
        source.setEventHandler {
            guard restore() else {
                print("restore already in progress; forcing exit")
                _exit(130)
            }
            exit(130)
        }
        source.resume()
        signalSources.append(source)
    }
}

// MARK: - Test

private let presetPrefixes = ["p3-600": "Apple Display (P3-600", "xdr": "Apple XDR Display (P3-1600"]

private func runTest(targetNits: Double, seconds: Int, presetKey: String) {
    guard (100...1600).contains(targetNits) else { fatalError("target must be within 100–1600 nits") }
    guard let prefix = presetPrefixes[presetKey] else { fatalError("preset must be one of \(presetPrefixes.keys.sorted())") }
    guard let testPreset = presets().first(where: { presetName($0).hasPrefix(prefix) }) else {
        fatalError("\"\(prefix)…\" preset not found")
    }
    guard preflight(), let slider = readSlider(), let auto = readAutoBrightness() else { exit(1) }

    var caps: [String: Int] = [:]
    for key in capKeys { caps[key] = readRaw(key) }
    saved = SavedState(preset: activePreset(), slider: slider, autoBrightness: auto, caps: caps)
    installSignalHandlers()
    atexit { restore() }
    status("before")

    writeAutoBrightness(false)
    print("activate \"\(presetName(testPreset))\" -> \(activate(testPreset))")
    Thread.sleep(forTimeInterval: 3)
    writeSlider(1)
    Thread.sleep(forTimeInterval: 2)
    status("baseline")
    // Hold the 600-nit baseline long enough to see (and measure) the jump.
    Thread.sleep(forTimeInterval: 3)

    let writes: [(String, Double)] = [
        (indicatorCapKey, max(readNits(indicatorCapKey) ?? 0, targetNits)),
        (backlightCapKey, targetNits),
        (physicalLimitKey, max(readNits(physicalLimitKey) ?? 0, targetNits)),
        (levelKey, targetNits),
    ]
    for (key, nits) in writes {
        let result = writeNits(key, nits)
        print("set \(key) = \(format(nits)) nits -> 0x\(String(result, radix: 16)), reads back \(format(readNits(key)))")
        guard result == KERN_SUCCESS else { return }
    }

    for second in 1...seconds {
        Thread.sleep(forTimeInterval: 1)
        status("t=\(second)s")
        // Something else changed the backlight: stop instead of fighting corebrightnessd.
        let drifted = writes.filter { key, nits in abs((readNits(key) ?? 0) - nits) > 1 }
        if !drifted.isEmpty {
            print("\(drifted.map(\.0).joined(separator: ", ")) changed by someone else, stopping test")
            return
        }
    }
}

// MARK: - Ramp: find the highest level the backlight holds on a full-white screen

/// Worst-case content for backlight power: a borderless white window over the whole built-in screen.
private var whiteWindow: NSWindow?

private func showWhiteWindow() {
    NSApplication.shared.setActivationPolicy(.accessory)
    guard let screen = NSScreen.screens.first(where: {
        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == builtInID
    }) else { return }
    let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
    window.backgroundColor = .white
    window.level = .screenSaver
    window.ignoresMouseEvents = true
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    window.setFrame(screen.frame, display: true)
    window.orderFrontRegardless()
    whiteWindow = window
}

private struct RampLimits {
    static let maxTemperatureRise = 15.0  // °C above the starting reading of any TD* sensor
    static let maxTemperature = 60.0      // °C absolute, any TD* sensor
    static let throttleDrop = 0.90        // late backlight power below 90% of early power = throttled
}

private func rampLevels(_ levels: [Double], hold: Int) {
    let startTemperatures = displayTemperatures()
    print("display temperature sensors: \(displayTemperatureKeys.map(\.name).joined(separator: " "))")
    var summary: [String] = []

    for target in levels {
        let writes: [(String, Double)] = [
            (indicatorCapKey, max(readNits(indicatorCapKey) ?? 0, target)),
            (backlightCapKey, target),
            (physicalLimitKey, max(readNits(physicalLimitKey) ?? 0, target)),
            (levelKey, target),
        ]
        for (key, nits) in writes where writeNits(key, nits) != KERN_SUCCESS {
            print("write \(key) failed, stopping")
            return
        }

        var watts: [Double] = []
        for second in 1...hold {
            Thread.sleep(forTimeInterval: 1)
            let power = backlightWatts() ?? .nan
            watts.append(power)
            let temperatures = displayTemperatures()
            let hottest = temperatures.max { $0.value < $1.value }
            let biggestRise = temperatures.map { ($0.key, $0.value - (startTemperatures[$0.key] ?? $0.value)) }
                .max { $0.1 < $1.1 }
            print(String(format: "[%4.0f nit t=%2ds] BacklightW=%5.2f hottest %@=%.1f°C biggest rise %@ +%.1f°C Level=%@ BLNitsCap=%@",
                         target, second, power, hottest?.key ?? "-", hottest?.value ?? .nan,
                         biggestRise?.0 ?? "-", biggestRise?.1 ?? .nan,
                         format(readNits(levelKey)), format(readNits(backlightCapKey))))

            if let (key, _) = writes.first(where: { abs((readNits($0.0) ?? 0) - $0.1) > 1 }) {
                print("\(key) changed by someone else, stopping")
                return
            }
            if let hottest, hottest.value > RampLimits.maxTemperature {
                print("\(hottest.key) above \(RampLimits.maxTemperature)°C, stopping")
                return
            }
            if let biggestRise, biggestRise.1 > RampLimits.maxTemperatureRise {
                print("\(biggestRise.0) rose more than \(RampLimits.maxTemperatureRise)°C, stopping")
                return
            }
        }

        // Skip the first 2 s while the backlight settles.
        let early = watts.dropFirst(2).prefix(5)
        let late = watts.suffix(min(10, max(1, hold / 3)))
        let earlyAverage = early.reduce(0, +) / Double(max(early.count, 1))
        let lateAverage = late.reduce(0, +) / Double(max(late.count, 1))
        let throttled = lateAverage < earlyAverage * RampLimits.throttleDrop
        let line = String(format: "%4.0f nit: backlight early %.2f W, late %.2f W (%.0f%%)%@",
                          target, earlyAverage, lateAverage, lateAverage / earlyAverage * 100,
                          throttled ? "  ← THROTTLED" : "")
        print("== " + line)
        summary.append(line)
        if throttled { break }
    }
    print("\n==== ramp summary")
    summary.forEach { print($0) }
}

private func runRamp(levels: [Double], hold: Int, presetKey: String) {
    guard levels.allSatisfy({ (100...1600).contains($0) }) else { fatalError("levels must be within 100–1600 nits") }
    guard let prefix = presetPrefixes[presetKey],
          let testPreset = presets().first(where: { presetName($0).hasPrefix(prefix) }) else {
        fatalError("preset must be one of \(presetPrefixes.keys.sorted())")
    }
    guard backlightWatts() != nil else { fatalError("cannot read SMC PDBR (backlight power)") }
    guard preflight(), let slider = readSlider(), let auto = readAutoBrightness() else { exit(1) }

    var caps: [String: Int] = [:]
    for key in capKeys { caps[key] = readRaw(key) }
    saved = SavedState(preset: activePreset(), slider: slider, autoBrightness: auto, caps: caps)
    installSignalHandlers()
    atexit { restore() }
    status("before")

    writeAutoBrightness(false)
    print("activate \"\(presetName(testPreset))\" -> \(activate(testPreset))")
    Thread.sleep(forTimeInterval: 3)
    writeSlider(1)
    showWhiteWindow()
    // The ramp runs off the main thread so the white window keeps drawing.
    Thread.detachNewThread {
        Thread.sleep(forTimeInterval: 5)
        status("baseline (white)")
        rampLevels(levels, hold: hold)
        DispatchQueue.main.async {
            whiteWindow?.orderOut(nil)
            exit(0)
        }
    }
    NSApplication.shared.run()
}

// MARK: - Main

setvbuf(stdout, nil, _IOLBF, 0)
let arguments = CommandLine.arguments
switch arguments.count > 1 ? arguments[1] : "status" {
case "status":
    status("status")
case "test":
    guard arguments.count > 2, let nits = Double(arguments[2]) else {
        print("usage: test <nits> [seconds] [p3-600|xdr]")
        exit(2)
    }
    runTest(targetNits: nits,
            seconds: arguments.count > 3 ? Int(arguments[3]) ?? 8 : 8,
            presetKey: arguments.count > 4 ? arguments[4] : "p3-600")
case "ramp":
    // ramp <hold-seconds> <p3-600|xdr> <nits>...
    guard arguments.count > 4, let hold = Int(arguments[2]) else {
        print("usage: ramp <hold-seconds> <p3-600|xdr> <nits>...")
        exit(2)
    }
    runRamp(levels: arguments[4...].compactMap(Double.init), hold: hold, presetKey: arguments[3])
default:
    print("usage: status | test <nits> [seconds] [p3-600|xdr] | ramp <hold-seconds> <p3-600|xdr> <nits>...")
    exit(2)
}
