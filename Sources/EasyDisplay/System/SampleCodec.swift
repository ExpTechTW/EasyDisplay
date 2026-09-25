import Foundation

/// One second of readings.
struct SensorSample: Sendable, Equatable {
    var time: Date
    /// SDR white of the built-in display.
    var nits: Double?
    /// Built-in display backlight power (SMC PDBR).
    var backlightWatts: Double?
    /// Whole-system power (SMC PSTR).
    var systemWatts: Double?
    /// Hottest display temperature sensor (SMC TD*).
    var displayCelsius: Double?
    /// Ambient light, as corebrightnessd aggregates it.
    var lux: Double?
    /// EDR headroom of the built-in display: above 1 while HDR content is on screen.
    var headroom: Double?
    var boosted = false
    /// Boost was held below its target by the thermal limit.
    var thermalLimited = false
    var autoBrightness = false
    var onBattery = false
}

/// Five minutes of samples as one compact binary block.
///
/// Each reading is a Float16: 3 significant digits, far finer than the sensors are accurate, at a quarter of a
/// Double's size. A field's 300 values are stored as zigzag deltas of their bit patterns, split into a low-byte plane
/// and a high-byte plane, so steady and slowly drifting readings turn into long runs of zeros; then the whole block is
/// LZMA-compressed (7% smaller than zlib on a day of noisy readings; the extra CPU is about 0.3 ms per write).
/// A missing reading is a NaN, a missing second has no `present` flag.
///
///     [version 1] lzma( for each field: 300 low bytes, 300 high bytes · then 300 flag bytes )
enum SampleCodec {
    static let slots = 300
    private static let version: UInt8 = 1
    private static let fieldCount = 6
    private static let payloadSize = slots * (fieldCount * 2 + 1)

    private struct Flag {
        static let present: UInt8 = 1 << 0
        static let boosted: UInt8 = 1 << 1
        static let thermalLimited: UInt8 = 1 << 2
        static let autoBrightness: UInt8 = 1 << 3
        static let onBattery: UInt8 = 1 << 4
    }

    enum Failure: Error {
        case unknownVersion, damaged
    }

    private static func fields(_ sample: SensorSample) -> [Double?] {
        [sample.nits, sample.backlightWatts, sample.systemWatts, sample.displayCelsius, sample.lux, sample.headroom]
    }

    /// `slots` has one entry per second of the period, nil where nothing was recorded.
    static func encode(_ slots: [SensorSample?]) throws -> Data {
        precondition(slots.count == Self.slots)
        let values = slots.map { $0.map(fields) }
        var payload = [UInt8](repeating: 0, count: payloadSize)
        for field in 0..<fieldCount {
            let low = field * 2 * Self.slots, high = low + Self.slots
            var previous: UInt16 = 0
            for index in 0..<Self.slots {
                let bits = half(values[index]?[field]).bitPattern
                let delta = Int16(bitPattern: bits &- previous)
                previous = bits
                let zigzag = UInt16(bitPattern: (delta &<< 1) ^ (delta >> 15))
                payload[low + index] = UInt8(truncatingIfNeeded: zigzag)
                payload[high + index] = UInt8(truncatingIfNeeded: zigzag >> 8)
            }
        }
        let flags = fieldCount * 2 * Self.slots
        for (index, slot) in slots.enumerated() {
            guard let slot else { continue }
            var flag = Flag.present
            if slot.boosted { flag |= Flag.boosted }
            if slot.thermalLimited { flag |= Flag.thermalLimited }
            if slot.autoBrightness { flag |= Flag.autoBrightness }
            if slot.onBattery { flag |= Flag.onBattery }
            payload[flags + index] = flag
        }
        let compressed = try (Data(payload) as NSData).compressed(using: .lzma) as Data
        return Data([version]) + compressed
    }

    /// The period's seconds, nil where nothing was recorded. `start` is the period's first second.
    static func decodeSlots(_ data: Data, start: Date) throws -> [SensorSample?] {
        guard data.first == version else { throw Failure.unknownVersion }
        let payload = [UInt8](try (Data(data.dropFirst()) as NSData).decompressed(using: .lzma) as Data)
        guard payload.count == payloadSize else { throw Failure.damaged }

        var values = [[Double?]](repeating: [Double?](repeating: nil, count: fieldCount), count: Self.slots)
        for field in 0..<fieldCount {
            let low = field * 2 * Self.slots, high = low + Self.slots
            var previous: UInt16 = 0
            for index in 0..<Self.slots {
                let zigzag = UInt16(payload[low + index]) | UInt16(payload[high + index]) << 8
                let delta = (zigzag >> 1) ^ (0 &- (zigzag & 1))
                previous = previous &+ delta
                let value = Float16(bitPattern: previous)
                values[index][field] = value.isNaN ? nil : Double(value)
            }
        }
        let flags = fieldCount * 2 * Self.slots
        return (0..<Self.slots).map { index in
            let flag = payload[flags + index]
            guard flag & Flag.present != 0 else { return nil }
            let v = values[index]
            return SensorSample(
                time: start.addingTimeInterval(TimeInterval(index)),
                nits: v[0], backlightWatts: v[1], systemWatts: v[2], displayCelsius: v[3], lux: v[4], headroom: v[5],
                boosted: flag & Flag.boosted != 0,
                thermalLimited: flag & Flag.thermalLimited != 0,
                autoBrightness: flag & Flag.autoBrightness != 0,
                onBattery: flag & Flag.onBattery != 0
            )
        }
    }

    private static func half(_ value: Double?) -> Float16 {
        guard let value, value.isFinite else { return .nan }
        return Float16(min(max(value, -65504), 65504))
    }
}

/// A period's totals, kept after its seconds are pruned: what the long-range charts and the analysis read.
struct PeriodRollup {
    struct Accumulator {
        private(set) var count = 0
        private(set) var sum = 0.0
        private(set) var minimum = Double.infinity
        private(set) var maximum = -Double.infinity

        mutating func add(_ value: Double?) {
            guard let value, value.isFinite else { return }
            count += 1
            sum += value
            minimum = min(minimum, value)
            maximum = max(maximum, value)
        }

        var average: Double? { count > 0 ? sum / Double(count) : nil }
        var lowest: Double? { count > 0 ? minimum : nil }
        var highest: Double? { count > 0 ? maximum : nil }
    }

    var seconds = 0
    var boostedSeconds = 0
    var limitedSeconds = 0
    var autoSeconds = 0
    var batterySeconds = 0
    var nits = Accumulator()
    var backlight = Accumulator()
    var system = Accumulator()
    var celsius = Accumulator()
    var lux = Accumulator()
    var headroom = Accumulator()
    /// Backlight energy, in joules (a watt for a second each sample), while boosted.
    var boostEnergy = 0.0

    init(_ slots: [SensorSample?]) {
        for case let sample? in slots {
            seconds += 1
            if sample.boosted {
                boostedSeconds += 1
                boostEnergy += sample.backlightWatts ?? 0
            }
            if sample.thermalLimited { limitedSeconds += 1 }
            if sample.autoBrightness { autoSeconds += 1 }
            if sample.onBattery { batterySeconds += 1 }
            nits.add(sample.nits)
            backlight.add(sample.backlightWatts)
            system.add(sample.systemWatts)
            celsius.add(sample.displayCelsius)
            lux.add(sample.lux)
            headroom.add(sample.headroom)
        }
    }
}
