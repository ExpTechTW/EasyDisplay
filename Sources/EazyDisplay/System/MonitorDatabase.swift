import Foundation
import SQLite3

/// A bucket of samples: each metric's average, lowest and highest reading.
struct SeriesPoint: Sendable, Identifiable, Equatable {
    struct Stat: Sendable, Equatable {
        let average: Double
        let minimum: Double
        let maximum: Double

        /// Folds values in one at a time, without collecting them.
        struct Accumulator {
            private var sum = 0.0, count = 0, low = Double.infinity, high = -Double.infinity

            mutating func add(_ value: Double?) {
                guard let value else { return }
                sum += value
                count += 1
                low = min(low, value)
                high = max(high, value)
            }

            var stat: Stat? {
                count == 0 ? nil : Stat(average: sum / Double(count), minimum: low, maximum: high)
            }
        }
    }

    /// The start of the bucket.
    let time: Date
    var nits: Stat?
    var watts: Stat?
    var systemWatts: Stat?
    var celsius: Stat?
    var lux: Stat?
    /// Boost was on for any of the bucket.
    var boosted = false

    var id: Date { time }

    /// Samples grouped into buckets of `seconds`, in one pass.
    static func bucketed(_ samples: some Sequence<SensorSample>, seconds: Int) -> [SeriesPoint] {
        let size = TimeInterval(max(seconds, 1))
        var points: [SeriesPoint] = []
        var bucketStart: TimeInterval?
        var nits = Stat.Accumulator(), watts = Stat.Accumulator(), systemWatts = Stat.Accumulator()
        var celsius = Stat.Accumulator(), lux = Stat.Accumulator(), boosted = false
        func close() {
            guard let bucketStart else { return }
            points.append(SeriesPoint(
                time: Date(timeIntervalSince1970: bucketStart),
                nits: nits.stat, watts: watts.stat, systemWatts: systemWatts.stat, celsius: celsius.stat, lux: lux.stat,
                boosted: boosted
            ))
            nits = .init(); watts = .init(); systemWatts = .init(); celsius = .init(); lux = .init(); boosted = false
        }
        for sample in samples {
            let start = (sample.time.timeIntervalSince1970 / size).rounded(.down) * size
            if start != bucketStart {
                close()
                bucketStart = start
            }
            nits.add(sample.nits)
            watts.add(sample.backlightWatts)
            systemWatts.add(sample.systemWatts)
            celsius.add(sample.displayCelsius)
            lux.add(sample.lux)
            boosted = boosted || sample.boosted
        }
        close()
        return points
    }
}

/// Totals over a stretch of time, from the period rollups.
struct MonitorAnalysis: Sendable, Equatable {
    var recorded: TimeInterval = 0
    var boosted: TimeInterval = 0
    var thermalLimited: TimeInterval = 0
    var onBattery: TimeInterval = 0
    var averageNits: Double?
    var peakNits: Double?
    var backlightWh = 0.0
    var boostWh = 0.0
    var systemWh = 0.0
    var peakCelsius: Double?
    var averageLux: Double?

    var averageBacklightWatts: Double? { recorded > 0 ? backlightWh * 3600 / recorded : nil }
}

/// Backlight energy in one bar of the energy chart.
struct EnergyBar: Sendable, Identifiable, Equatable {
    let start: Date
    let normalWh: Double
    let boostWh: Double
    var id: Date { start }
}

/// Time spent in one 200-nit band of brightness.
struct BrightnessBand: Sendable, Identifiable, Equatable {
    static let width = 200.0
    static let count = 5

    let index: Int
    let seconds: TimeInterval
    var id: Int { index }
    var lower: Double { Double(index) * Self.width }
}

struct MonitorDatabaseInfo: Sendable, Equatable {
    /// Seconds still stored one by one.
    var rawSeconds = 0
    var rawBytes = 0
    var rawOldest: Date?
    /// Seconds summarized in the rollups.
    var rollupSeconds = 0
    var rollupOldest: Date?
    var fileBytes = 0
}

enum MonitorDatabaseError: Error, CustomStringConvertible {
    case sqlite(String)

    var description: String {
        switch self {
        case .sqlite(let message): message
        }
    }
}

/// The monitor's history, in SQLite, in two tables keyed by five-minute period:
///
/// - `raw`: every second of the period as one `SampleCodec` block, about 1.3 KB. The 5-minute and 1-hour charts
///   read it.
/// - `rollup`: the period's counts, averages, extremes and energy, as small integers (0.1 nit, 0.01 W, 0.1 J,
///   0.01 °C, 0.1 lux). The longer charts and the analysis read it.
///
/// Both are kept for the chosen number of days.
///
/// One connection writes and another only reads, both in WAL mode, so reading a chart never waits on a write and a
/// write never waits on a month-long aggregate. Each keeps SQLite's page cache at 4 MiB.
final class MonitorDatabase: Sendable {
    /// Seconds per period, and per raw block.
    static let period = SampleCodec.slots

    let url: URL
    let writer: SampleWriter
    let reader: SampleReader

    /// ~/Library/Application Support/<bundle id>/Monitor.sqlite
    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "io.github.yuyu1015.EazyDisplay", isDirectory: true)
            .appendingPathComponent("Monitor.sqlite")
    }

    init(url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        self.url = url
        // The writer first: it creates or migrates the file and switches it to WAL, which the reader relies on.
        writer = try SampleWriter(url: url)
        reader = try SampleReader(url: url)
    }
}

/// SQLite's page cache per connection, in KiB (a negative cache_size is KiB rather than pages): 4 MiB.
private let cacheKiB = 4096
private let schemaVersion: Int32 = 2

/// Fixed-point scales of the rollup columns.
private enum Scale {
    static let nits = 10.0
    static let watts = 100.0
    static let energy = 10.0
    static let celsius = 100.0
    static let lux = 10.0
    static let headroom = 100.0
}

/// Takes one sample a second and writes the current period every few seconds, on a queue of its own.
final class SampleWriter: @unchecked Sendable {
    /// How often the current period is rewritten: what a crash can lose at most.
    static let writeInterval = 10

    private let queue = DispatchQueue(label: "EazyDisplay.MonitorDatabase.writer", qos: .utility)
    // Everything below is only touched on `queue`.
    private let db: OpaquePointer
    private let insertRaw: OpaquePointer
    private let insertRollup: OpaquePointer
    private let selectRaw: OpaquePointer
    private var current: (period: Int, slots: [SensorSample?])?
    private var lastWrite = 0

    init(url: URL) throws {
        db = try openDatabase(url, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX)
        if try userVersion(db) < schemaVersion {
            // Version 1 stored a row per second; nothing in it is worth converting.
            try execute(db, "DROP TABLE IF EXISTS samples")
            // Pruned pages go back to the file system instead of staying in the file.
            try execute(db, "PRAGMA auto_vacuum = INCREMENTAL")
            try execute(db, "VACUUM")
        }
        try execute(db, "PRAGMA journal_mode = WAL")
        // WAL with NORMAL survives a crash; only the last write could be lost to a power cut.
        try execute(db, "PRAGMA synchronous = NORMAL")
        // Checkpoint every 100 pages (a few minutes of writes) instead of SQLite's 1000, and cut the WAL back to
        // 512 KiB afterwards, so the file on disk stays about the size of the data.
        try execute(db, "PRAGMA wal_autocheckpoint = 100")
        try execute(db, "PRAGMA journal_size_limit = 524288")
        try execute(db, "PRAGMA cache_size = -\(cacheKiB)")
        try execute(db, """
            CREATE TABLE IF NOT EXISTS raw (
                p INTEGER PRIMARY KEY,   -- Unix time / 300
                data BLOB NOT NULL       -- SampleCodec block
            );
            CREATE TABLE IF NOT EXISTS rollup (
                p INTEGER PRIMARY KEY,
                n INTEGER NOT NULL,              -- seconds recorded
                boost_n INTEGER NOT NULL,
                limit_n INTEGER NOT NULL,
                auto_n INTEGER NOT NULL,
                battery_n INTEGER NOT NULL,
                nits_avg INTEGER, nits_min INTEGER, nits_max INTEGER,          -- 0.1 nit
                bl_e INTEGER, bl_boost_e INTEGER,                              -- backlight energy, 0.1 J
                bl_min INTEGER, bl_max INTEGER,                                -- 0.01 W
                sys_e INTEGER, sys_min INTEGER, sys_max INTEGER,               -- 0.1 J, 0.01 W
                temp_avg INTEGER, temp_min INTEGER, temp_max INTEGER,          -- 0.01 °C
                lux_avg INTEGER, lux_min INTEGER, lux_max INTEGER,             -- 0.1 lux
                hr_max INTEGER                                                 -- 0.01
            );
            PRAGMA user_version = \(schemaVersion);
            """)
        insertRaw = try prepare(db, "INSERT OR REPLACE INTO raw (p, data) VALUES (?, ?)")
        insertRollup = try prepare(db, "INSERT OR REPLACE INTO rollup VALUES (\(Array(repeating: "?", count: 23).joined(separator: ", ")))")
        selectRaw = try prepare(db, "SELECT data FROM raw WHERE p = ?")
    }

    /// Queues a sample; it's written with its period within `writeInterval` seconds.
    func record(_ sample: SensorSample) {
        queue.async { [self] in
            do {
                try store(sample)
            } catch {
                log.error("monitor write failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Writes what's queued now; at quit, and in tests.
    func flush() throws {
        try queue.sync { try write() }
    }

    /// Removes raw blocks older than `rawBefore` and rollups older than `rollupBefore`; returns how many periods.
    @discardableResult
    func prune(rawBefore: Date, rollupBefore: Date) async throws -> Int {
        try await run { [self] in
            try execute(db, "DELETE FROM raw WHERE p < \(period(of: rawBefore))")
            var removed = Int(sqlite3_changes(db))
            try execute(db, "DELETE FROM rollup WHERE p < \(period(of: rollupBefore))")
            removed += Int(sqlite3_changes(db))
            try execute(db, "PRAGMA incremental_vacuum")
            return removed
        }
    }

    func clear() async throws {
        try await run { [self] in
            current = nil
            try execute(db, "DELETE FROM raw; DELETE FROM rollup")
            try execute(db, "PRAGMA wal_checkpoint(TRUNCATE)")
            try execute(db, "VACUUM")
        }
    }

    private func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result(catching: body)) }
        }
    }

    // MARK: On the queue

    private func store(_ sample: SensorSample) throws {
        let second = Int(sample.time.timeIntervalSince1970.rounded(.down))
        let period = second / MonitorDatabase.period
        if current?.period != period {
            try write()
            // A period that was started before a relaunch carries on where it was.
            current = (period, try load(period) ?? Array(repeating: nil, count: MonitorDatabase.period))
        }
        current?.slots[second - period * MonitorDatabase.period] = sample
        if second - lastWrite >= Self.writeInterval {
            try write()
            lastWrite = second
        }
    }

    private func load(_ period: Int) throws -> [SensorSample?]? {
        defer { sqlite3_reset(selectRaw) }
        sqlite3_bind_int64(selectRaw, 1, Int64(period))
        guard sqlite3_step(selectRaw) == SQLITE_ROW else { return nil }
        let data = blob(selectRaw, 0)
        return try? SampleCodec.decodeSlots(data, start: Date(timeIntervalSince1970: TimeInterval(period * MonitorDatabase.period)))
    }

    private func write() throws {
        guard let current, current.slots.contains(where: { $0 != nil }) else { return }
        let data = try SampleCodec.encode(current.slots)
        let rollup = PeriodRollup(current.slots)
        try execute(db, "BEGIN")
        do {
            defer {
                sqlite3_reset(insertRaw)
                sqlite3_reset(insertRollup)
            }
            sqlite3_bind_int64(insertRaw, 1, Int64(current.period))
            _ = data.withUnsafeBytes { sqlite3_bind_blob(insertRaw, 2, $0.baseAddress, Int32($0.count), SQLITE_TRANSIENT) }
            guard sqlite3_step(insertRaw) == SQLITE_DONE else { throw error(db) }

            let s = insertRollup
            sqlite3_bind_int64(s, 1, Int64(current.period))
            sqlite3_bind_int64(s, 2, Int64(rollup.seconds))
            sqlite3_bind_int64(s, 3, Int64(rollup.boostedSeconds))
            sqlite3_bind_int64(s, 4, Int64(rollup.limitedSeconds))
            sqlite3_bind_int64(s, 5, Int64(rollup.autoSeconds))
            sqlite3_bind_int64(s, 6, Int64(rollup.batterySeconds))
            bindScaled(s, 7, rollup.nits.average, Scale.nits)
            bindScaled(s, 8, rollup.nits.lowest, Scale.nits)
            bindScaled(s, 9, rollup.nits.highest, Scale.nits)
            bindScaled(s, 10, rollup.backlight.count > 0 ? rollup.backlight.sum : nil, Scale.energy)
            bindScaled(s, 11, rollup.backlight.count > 0 ? rollup.boostEnergy : nil, Scale.energy)
            bindScaled(s, 12, rollup.backlight.lowest, Scale.watts)
            bindScaled(s, 13, rollup.backlight.highest, Scale.watts)
            bindScaled(s, 14, rollup.system.count > 0 ? rollup.system.sum : nil, Scale.energy)
            bindScaled(s, 15, rollup.system.lowest, Scale.watts)
            bindScaled(s, 16, rollup.system.highest, Scale.watts)
            bindScaled(s, 17, rollup.celsius.average, Scale.celsius)
            bindScaled(s, 18, rollup.celsius.lowest, Scale.celsius)
            bindScaled(s, 19, rollup.celsius.highest, Scale.celsius)
            bindScaled(s, 20, rollup.lux.average, Scale.lux)
            bindScaled(s, 21, rollup.lux.lowest, Scale.lux)
            bindScaled(s, 22, rollup.lux.highest, Scale.lux)
            bindScaled(s, 23, rollup.headroom.highest, Scale.headroom)
            guard sqlite3_step(s) == SQLITE_DONE else { throw error(db) }
            try execute(db, "COMMIT")
        } catch {
            try? execute(db, "ROLLBACK")
            throw error
        }
    }
}

actor SampleReader {
    private let db: OpaquePointer
    private let url: URL
    private let selectRaw: OpaquePointer
    private let series: OpaquePointer
    private let analysis: OpaquePointer
    private let energy: OpaquePointer
    private let distribution: OpaquePointer
    private let rawInfo: OpaquePointer
    private let rollupInfo: OpaquePointer

    init(url: URL) throws {
        self.url = url
        db = try openDatabase(url, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX)
        try execute(db, "PRAGMA cache_size = -\(cacheKiB)")
        selectRaw = try prepare(db, "SELECT p, data FROM raw WHERE p >= ?1 AND p <= ?2 ORDER BY p")
        // An average over buckets is weighted by the seconds each period recorded.
        series = try prepare(db, """
            SELECT (p / ?1) * ?1,
                   sum(nits_avg * n) * 1.0 / sum(CASE WHEN nits_avg IS NOT NULL THEN n END), min(nits_min), max(nits_max),
                   sum(bl_e) * 1.0 / sum(CASE WHEN bl_e IS NOT NULL THEN n END), min(bl_min), max(bl_max),
                   sum(sys_e) * 1.0 / sum(CASE WHEN sys_e IS NOT NULL THEN n END), min(sys_min), max(sys_max),
                   sum(temp_avg * n) * 1.0 / sum(CASE WHEN temp_avg IS NOT NULL THEN n END), min(temp_min), max(temp_max),
                   sum(lux_avg * n) * 1.0 / sum(CASE WHEN lux_avg IS NOT NULL THEN n END), min(lux_min), max(lux_max),
                   max(boost_n) > 0
            FROM rollup WHERE p >= ?2 AND p <= ?3
            GROUP BY 1 ORDER BY 1
            """)
        analysis = try prepare(db, """
            SELECT coalesce(sum(n), 0), coalesce(sum(boost_n), 0), coalesce(sum(limit_n), 0), coalesce(sum(battery_n), 0),
                   sum(nits_avg * n) * 1.0 / sum(CASE WHEN nits_avg IS NOT NULL THEN n END), max(nits_max),
                   coalesce(sum(bl_e), 0), coalesce(sum(bl_boost_e), 0), coalesce(sum(sys_e), 0),
                   max(temp_max),
                   sum(lux_avg * n) * 1.0 / sum(CASE WHEN lux_avg IS NOT NULL THEN n END)
            FROM rollup WHERE p >= ?1 AND p < ?2
            """)
        energy = try prepare(db, """
            SELECT (p * 300 + ?1) / ?2, coalesce(sum(bl_e), 0) - coalesce(sum(bl_boost_e), 0), coalesce(sum(bl_boost_e), 0)
            FROM rollup WHERE p >= ?3 AND p < ?4
            GROUP BY 1 ORDER BY 1
            """)
        distribution = try prepare(db, """
            SELECT min(nits_avg / \(Int(BrightnessBand.width * Scale.nits)), \(BrightnessBand.count - 1)), sum(n)
            FROM rollup WHERE nits_avg IS NOT NULL AND p >= ?1 AND p < ?2
            GROUP BY 1
            """)
        rawInfo = try prepare(db, """
            SELECT count(*), min(p), coalesce(sum(length(data)), 0),
                   (SELECT coalesce(sum(n), 0) FROM rollup WHERE p IN (SELECT p FROM raw))
            FROM raw
            """)
        rollupInfo = try prepare(db, "SELECT min(p), coalesce(sum(n), 0) FROM rollup")
    }

    /// Every second recorded from `start` to `end`.
    func samples(from start: Date, to end: Date) throws -> [SensorSample] {
        defer { sqlite3_reset(selectRaw) }
        sqlite3_bind_int64(selectRaw, 1, Int64(period(of: start)))
        sqlite3_bind_int64(selectRaw, 2, Int64(period(of: end)))
        var samples: [SensorSample] = []
        try rows(selectRaw) {
            let start = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(selectRaw, 0)) * TimeInterval(MonitorDatabase.period))
            guard let slots = try? SampleCodec.decodeSlots(blob(selectRaw, 1), start: start) else { return }
            samples += slots.compactMap { $0 }
        }
        return samples.filter { $0.time >= start && $0.time <= end }
    }

    /// Rollups from `start` to `end` in buckets of `bucket` seconds, a multiple of the five-minute period.
    func series(from start: Date, to end: Date, bucket: Int) throws -> [SeriesPoint] {
        defer { sqlite3_reset(series) }
        sqlite3_bind_int64(series, 1, Int64(max(bucket / MonitorDatabase.period, 1)))
        sqlite3_bind_int64(series, 2, Int64(period(of: start)))
        sqlite3_bind_int64(series, 3, Int64(period(of: end)))
        var points: [SeriesPoint] = []
        try rows(series) {
            let s = series
            points.append(SeriesPoint(
                time: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(s, 0) * Int64(MonitorDatabase.period))),
                nits: stat(s, 1, Scale.nits, Scale.nits),
                watts: stat(s, 4, Scale.energy, Scale.watts),
                systemWatts: stat(s, 7, Scale.energy, Scale.watts),
                celsius: stat(s, 10, Scale.celsius, Scale.celsius),
                lux: stat(s, 13, Scale.lux, Scale.lux),
                boosted: sqlite3_column_int(s, 16) != 0
            ))
        }
        return points
    }

    func analysis(from start: Date, to end: Date) throws -> MonitorAnalysis {
        let s = analysis
        defer { sqlite3_reset(s) }
        sqlite3_bind_int64(s, 1, Int64(period(of: start)))
        sqlite3_bind_int64(s, 2, Int64(period(of: end)) + 1)
        guard sqlite3_step(s) == SQLITE_ROW else { throw error(db) }
        return MonitorAnalysis(
            recorded: TimeInterval(sqlite3_column_int64(s, 0)),
            boosted: TimeInterval(sqlite3_column_int64(s, 1)),
            thermalLimited: TimeInterval(sqlite3_column_int64(s, 2)),
            onBattery: TimeInterval(sqlite3_column_int64(s, 3)),
            averageNits: double(s, 4).map { $0 / Scale.nits },
            peakNits: double(s, 5).map { $0 / Scale.nits },
            backlightWh: Double(sqlite3_column_int64(s, 6)) / Scale.energy / 3600,
            boostWh: Double(sqlite3_column_int64(s, 7)) / Scale.energy / 3600,
            systemWh: Double(sqlite3_column_int64(s, 8)) / Scale.energy / 3600,
            peakCelsius: double(s, 9).map { $0 / Scale.celsius },
            averageLux: double(s, 10).map { $0 / Scale.lux }
        )
    }

    /// Backlight energy in bars of `bar` seconds, aligned to local time (`utcOffset` seconds east of UTC).
    func energy(from start: Date, to end: Date, bar: Int, utcOffset: Int) throws -> [EnergyBar] {
        let s = energy
        defer { sqlite3_reset(s) }
        sqlite3_bind_int64(s, 1, Int64(utcOffset))
        sqlite3_bind_int64(s, 2, Int64(bar))
        sqlite3_bind_int64(s, 3, Int64(period(of: start)))
        sqlite3_bind_int64(s, 4, Int64(period(of: end)) + 1)
        var bars: [EnergyBar] = []
        try rows(s) {
            bars.append(EnergyBar(
                start: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(s, 0) * Int64(bar) - Int64(utcOffset))),
                normalWh: Double(sqlite3_column_int64(s, 1)) / Scale.energy / 3600,
                boostWh: Double(sqlite3_column_int64(s, 2)) / Scale.energy / 3600
            ))
        }
        return bars
    }

    /// Time at each 200-nit band of brightness, every band present.
    func distribution(from start: Date, to end: Date) throws -> [BrightnessBand] {
        let s = distribution
        defer { sqlite3_reset(s) }
        sqlite3_bind_int64(s, 1, Int64(period(of: start)))
        sqlite3_bind_int64(s, 2, Int64(period(of: end)) + 1)
        var seconds = [TimeInterval](repeating: 0, count: BrightnessBand.count)
        try rows(s) {
            let index = Int(sqlite3_column_int64(s, 0))
            if seconds.indices.contains(index) { seconds[index] = TimeInterval(sqlite3_column_int64(s, 1)) }
        }
        return seconds.enumerated().map { BrightnessBand(index: $0.offset, seconds: $0.element) }
    }

    func info() throws -> MonitorDatabaseInfo {
        var info = MonitorDatabaseInfo()
        do {
            defer { sqlite3_reset(rawInfo) }
            guard sqlite3_step(rawInfo) == SQLITE_ROW else { throw error(db) }
            info.rawOldest = periodStart(rawInfo, 1)
            info.rawBytes = Int(sqlite3_column_int64(rawInfo, 2))
            info.rawSeconds = Int(sqlite3_column_int64(rawInfo, 3))
        }
        do {
            defer { sqlite3_reset(rollupInfo) }
            guard sqlite3_step(rollupInfo) == SQLITE_ROW else { throw error(db) }
            info.rollupOldest = periodStart(rollupInfo, 0)
            info.rollupSeconds = Int(sqlite3_column_int64(rollupInfo, 1))
        }
        info.fileBytes = [url.path, url.path + "-wal"].reduce(0) { total, path in
            total + ((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0)
        }
        return info
    }

    private func rows(_ statement: OpaquePointer, _ row: () throws -> Void) throws {
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: try row()
            case SQLITE_DONE: return
            default: throw error(db)
            }
        }
    }

    private func periodStart(_ statement: OpaquePointer, _ column: Int32) -> Date? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, column) * Int64(MonitorDatabase.period)))
    }
}

// MARK: - SQLite helpers

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private func period(of date: Date) -> Int {
    Int((date.timeIntervalSince1970 / TimeInterval(MonitorDatabase.period)).rounded(.down))
}

private func openDatabase(_ url: URL, flags: Int32) throws -> OpaquePointer {
    var db: OpaquePointer?
    let result = sqlite3_open_v2(url.path, &db, flags, nil)
    guard result == SQLITE_OK, let db else {
        let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite3_open_v2 \(result)"
        sqlite3_close(db)
        throw MonitorDatabaseError.sqlite(message)
    }
    // The other connection may hold the lock for a moment, e.g. during a checkpoint.
    sqlite3_busy_timeout(db, 2000)
    return db
}

private func userVersion(_ db: OpaquePointer) throws -> Int32 {
    let statement = try prepare(db, "PRAGMA user_version")
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { throw error(db) }
    return sqlite3_column_int(statement, 0)
}

private func execute(_ db: OpaquePointer, _ sql: String) throws {
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error(db) }
}

private func prepare(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v3(db, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &statement, nil) == SQLITE_OK, let statement else {
        throw error(db)
    }
    return statement
}

private func bindScaled(_ statement: OpaquePointer, _ index: Int32, _ value: Double?, _ scale: Double) {
    if let value, value.isFinite {
        sqlite3_bind_int64(statement, index, Int64((value * scale).rounded()))
    } else {
        sqlite3_bind_null(statement, index)
    }
}

private func blob(_ statement: OpaquePointer, _ column: Int32) -> Data {
    guard let bytes = sqlite3_column_blob(statement, column) else { return Data() }
    return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
}

private func double(_ statement: OpaquePointer, _ column: Int32) -> Double? {
    sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : sqlite3_column_double(statement, column)
}

/// Columns `first`, `first + 1`, `first + 2` as average, minimum and maximum; nil when the bucket has no reading.
private func stat(_ statement: OpaquePointer, _ first: Int32, _ averageScale: Double, _ extremeScale: Double) -> SeriesPoint.Stat? {
    guard let average = double(statement, first) else { return nil }
    let low = double(statement, first + 1).map { $0 / extremeScale } ?? average / averageScale
    let high = double(statement, first + 2).map { $0 / extremeScale } ?? average / averageScale
    return SeriesPoint.Stat(average: average / averageScale, minimum: low, maximum: high)
}

private func error(_ db: OpaquePointer) -> MonitorDatabaseError {
    .sqlite(String(cString: sqlite3_errmsg(db)))
}
