import AppKit
import IOKit.ps
import Observation

/// What the built-in display is doing, read at each sample.
struct DisplayReading: Sendable {
    /// nil while the display is off: no brightness, rather than the last one.
    var nits: Double?
    /// Whether the display's temperature and the ambient light are measured now. Off (the lid closed, too), and for a
    /// while after, they hold an old reading.
    var sensorsAreCurrent = false
    var headroom: Double?
    var boosted = false
    var thermalLimited = false
    var autoBrightness = false
}

/// Samples the built-in display's brightness, backlight and system power, temperature and the ambient light once per
/// second into the monitor database, and keeps the last five minutes at hand for the live chart.
@MainActor
@Observable
final class SensorMonitor {
    enum Status {
        case starting, running, unavailable
    }

    /// How much the live chart shows, and how much stays in memory.
    static let recentWindow: TimeInterval = 5 * 60

    private(set) var status = Status.starting
    private(set) var latest: SensorSample?
    /// The last five minutes, oldest first.
    private(set) var recent: [SensorSample] = []
    /// Goes up whenever recorded history is removed, so whatever shows it reloads at once.
    private(set) var historyVersion = 0

    @ObservationIgnored let database: MonitorDatabase?
    @ObservationIgnored var reading: @MainActor () -> DisplayReading = { DisplayReading() }
    /// Each new sample, once a second: the heartbeat the rest of the app runs on.
    @ObservationIgnored var onSample: @MainActor (SensorSample) -> Void = { _ in }
    /// How long seconds and rollups are kept.
    @ObservationIgnored private let retention: @MainActor () -> (raw: TimeInterval, rollup: TimeInterval)
    @ObservationIgnored private var sensors: SMCSensors?
    @ObservationIgnored private var lux: Double?
    @ObservationIgnored private var luxInFlight = false
    @ObservationIgnored private var onBattery = false

    init(database: MonitorDatabase?, retention: @escaping @MainActor () -> (raw: TimeInterval, rollup: TimeInterval)) {
        self.database = database
        self.retention = retention
    }

    func start() {
        Task {
            // Key discovery walks every SMC key, so keep it off the main thread.
            sensors = await Task.detached(priority: .utility) { SMCSensors() }.value
            if let sensors {
                status = .running
                Log.info("sensor", "感測器：背光功耗 PDBR \(sensors.backlight != nil ? "有" : "無")、整機功耗 PSTR \(sensors.system != nil ? "有" : "無")、"
                    + "面板溫度 \(sensors.temperatures.map(\.name).joined(separator: " "))")
                if let database {
                    let now = Date.now
                    recent = (try? await database.reader.samples(from: now.addingTimeInterval(-Self.recentWindow), to: now)) ?? []
                }
                await prune()
            } else {
                // No history without the SMC, but the display still needs its ambient light and its once-a-second update.
                status = .unavailable
            }
            let clock = ContinuousClock()
            var next = clock.now
            var seconds = 0
            while !Task.isCancelled {
                if seconds % 10 == 0 { onBattery = Self.isOnBattery() }
                pollLux()
                // Each SMC read waits about 0.2 ms on the SMC, some 5 ms for all of them: not on the main thread.
                let readings = await Task.detached(priority: .utility) { [sensors] in sensors?.read() }.value
                onSample(sample(readings))
                seconds += 1
                if seconds % 3600 == 0 { await prune() }
                next += .seconds(1)
                try? await Task.sleep(until: next, tolerance: .milliseconds(100), clock: clock)
            }
        }
    }

    /// Deletes what's older than the retention settings.
    func prune() async {
        guard let database else { return }
        let now = Date.now, keep = retention()
        do {
            let removed = try await database.writer.prune(rawBefore: now.addingTimeInterval(-keep.raw), rollupBefore: now.addingTimeInterval(-keep.rollup))
            if removed > 0 { Log.info("monitor", "刪除 \(removed) 段超過保留期限的監測資料") }
        } catch {
            Log.error("monitor", "刪除舊監測資料失敗：\(error)")
        }
    }

    /// Removes every recorded second and summary, on disk and in memory.
    func clearHistory() async {
        do {
            try await database?.writer.clear()
            Log.info("monitor", "清除監測資料")
        } catch {
            Log.error("monitor", "清除監測資料失敗：\(error)")
        }
        recent.removeAll()
        historyVersion += 1
    }

    /// Writes the seconds not yet on disk; at quit.
    func flush() {
        do {
            try database?.writer.flush()
        } catch {
            Log.error("monitor", "寫入最後的監測資料失敗：\(error)")
        }
    }

    /// corebrightnessd keeps aggregating the ambient light sensor even while auto-brightness is off.
    private func pollLux() {
        guard !luxInFlight else { return }
        luxInFlight = true
        Task {
            lux = await AmbientLight.lux()
            luxInFlight = false
        }
    }

    private func sample(_ readings: SMCSensors.Readings?) -> SensorSample {
        let display = reading()
        let sample = SensorSample(
            time: .now,
            nits: display.nits,
            backlightWatts: readings?.backlightWatts,
            systemWatts: readings?.systemWatts,
            displayCelsius: display.sensorsAreCurrent ? readings?.displayCelsius : nil,
            lux: display.sensorsAreCurrent ? lux : nil,
            headroom: display.headroom,
            boosted: display.boosted,
            thermalLimited: display.thermalLimited,
            autoBrightness: display.autoBrightness,
            onBattery: onBattery
        )
        guard readings != nil else { return sample }
        latest = sample
        recent.append(sample)
        let cutoff = sample.time.addingTimeInterval(-Self.recentWindow)
        if let firstKept = recent.firstIndex(where: { $0.time >= cutoff }), firstKept > 0 {
            recent.removeFirst(firstKept)
        }
        database?.writer.record(sample)
        return sample
    }

    private static func isOnBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPMBatteryPowerKey
    }
}

/// The SMC keys the monitor reads: backlight and system power, and every display temperature sensor.
private struct SMCSensors: Sendable {
    struct Readings: Sendable {
        var backlightWatts: Double?
        var systemWatts: Double?
        /// The panel's temperature: the hottest of its sensors away from the hinge. The thermal limit follows it.
        var displayCelsius: Double?
    }

    let smc: SMC
    let backlight: SMC.Key?
    let system: SMC.Key?
    /// The panel's temperature grid, TD00 to TD24, rows 0 to 2 from the top, without the bottom row: the processor's
    /// exhaust comes out at the hinge and warms that row and the other display sensors (TDEL, TDER, TDVx…) by 2 to
    /// 2.4 °C at 45 W, while the rows above rise 0.1 to 0.4 °C (measured on a 16" M4 Max). A Mac without the grid
    /// uses every TD sensor.
    let temperatures: [SMC.Key]

    init?() {
        guard let smc = SMC() else { return nil }
        self.smc = smc
        backlight = smc.floatKey(named: "PDBR")
        system = smc.floatKey(named: "PSTR")
        let all = smc.floatKeys(prefix: "TD")
        let panel = all.filter { $0.name.range(of: "^TD[01][0-9]$", options: .regularExpression) != nil }
        temperatures = panel.isEmpty ? all : panel
        guard backlight != nil || !temperatures.isEmpty else { return nil }
    }

    func read() -> Readings {
        var readings = Readings(backlightWatts: backlight.flatMap(smc.read), systemWatts: system.flatMap(smc.read))
        for key in temperatures {
            guard let celsius = smc.read(key), (1...150).contains(celsius), celsius > readings.displayCelsius ?? 0 else { continue }
            readings.displayCelsius = celsius
        }
        return readings
    }
}
