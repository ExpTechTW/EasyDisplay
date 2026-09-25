import Foundation
import SQLite3
import Testing
@testable import EazyDisplay

private let period = MonitorDatabase.period

private func sample(_ second: Int, nits: Double? = 400, watts: Double? = 5, system: Double? = 20, celsius: Double? = 38,
                    lux: Double? = 120, boosted: Bool = false, limited: Bool = false, battery: Bool = false) -> SensorSample {
    SensorSample(time: Date(timeIntervalSince1970: TimeInterval(second)), nits: nits, backlightWatts: watts, systemWatts: system,
                 displayCelsius: celsius, lux: lux, headroom: 1, boosted: boosted, thermalLimited: limited, autoBrightness: true,
                 onBattery: battery)
}

@Suite struct SampleCodecTests {
    @Test func aBlockRoundTripsWithinHalfPrecision() throws {
        let start = 1_790_000_100
        var slots = [SensorSample?](repeating: nil, count: period)
        for index in stride(from: 0, to: period, by: 1) where index % 7 != 3 {
            slots[index] = sample(start + index, nits: 300 + Double(index) * 2.3, watts: 2 + Double(index % 13) * 0.37,
                                  celsius: 35 + Double(index) / 50, lux: index == 10 ? nil : Double(index) * 11.1,
                                  boosted: index > 150, limited: index % 50 == 0, battery: index < 20)
        }
        let decoded = try SampleCodec.decodeSlots(try SampleCodec.encode(slots), start: Date(timeIntervalSince1970: TimeInterval(start)))
        #expect(decoded.count == period)
        for (original, copy) in zip(slots, decoded) {
            guard let original else {
                #expect(copy == nil)
                continue
            }
            let copy = try #require(copy)
            #expect(copy.time == original.time)
            #expect(copy.boosted == original.boosted && copy.thermalLimited == original.thermalLimited && copy.onBattery == original.onBattery)
            #expect((copy.lux == nil) == (original.lux == nil))
            // Float16 keeps about three significant digits.
            for (a, b) in [(copy.nits, original.nits), (copy.backlightWatts, original.backlightWatts), (copy.displayCelsius, original.displayCelsius)] {
                let a = try #require(a), b = try #require(b)
                #expect(abs(a - b) <= abs(b) * 0.001 + 0.001)
            }
        }
    }

    @Test func aSteadyFiveMinutesIsSmall() throws {
        let slots: [SensorSample?] = (0..<period).map { sample(1_790_000_100 + $0) }
        // 300 seconds of six readings and flags: 3,900 bytes before compression.
        #expect(try SampleCodec.encode(slots).count < 150)
    }

    @Test func rejectsWhatItDidNotWrite() {
        #expect(throws: (any Error).self) { try SampleCodec.decodeSlots(Data([9, 1, 2]), start: .now) }
    }
}

@Suite struct MonitorDatabaseTests {
    private func database(_ folder: URL? = nil) throws -> (MonitorDatabase, URL) {
        let folder = folder ?? FileManager.default.temporaryDirectory.appendingPathComponent("EazyDisplayTests-\(UUID().uuidString)")
        return (try MonitorDatabase(url: folder.appendingPathComponent("Monitor.sqlite")), folder)
    }

    private func record(_ db: MonitorDatabase, _ samples: [SensorSample]) throws {
        samples.forEach(db.writer.record)
        try db.writer.flush()
    }

    /// On a ten-minute boundary, so a 600-second bucket starts with its first period.
    private let base = 1_790_000_100 / 600 * 600

    @Test func theReaderSeesEverySecondTheWriterTook() async throws {
        let (db, folder) = try database()
        defer { try? FileManager.default.removeItem(at: folder) }
        // Twelve minutes: three periods, the last one partial.
        try record(db, (0..<720).map { sample(base + $0, nits: Double($0)) })
        let samples = try await db.reader.samples(from: Date(timeIntervalSince1970: TimeInterval(base)),
                                                  to: Date(timeIntervalSince1970: TimeInterval(base + 719)))
        #expect(samples.count == 720)
        #expect(samples.first?.nits == 0)
        #expect(samples.last?.nits == 719)
        let info = try await db.reader.info()
        #expect(info.rawSeconds == 720 && info.rollupSeconds == 720)
    }

    @Test func aRelaunchCarriesOnInTheSamePeriod() async throws {
        let (first, folder) = try database()
        defer { try? FileManager.default.removeItem(at: folder) }
        try record(first, (0..<100).map { sample(base + $0) })
        let (second, _) = try database(folder)
        try record(second, (100..<200).map { sample(base + $0) })
        let samples = try await second.reader.samples(from: Date(timeIntervalSince1970: TimeInterval(base)),
                                                      to: Date(timeIntervalSince1970: TimeInterval(base + 299)))
        #expect(samples.count == 200)
    }

    @Test func rollupsAverageWeighByTimeAndKeepTheExtremes() async throws {
        let (db, folder) = try database()
        defer { try? FileManager.default.removeItem(at: folder) }
        // Two periods: 300 s at 400 nit, then 150 s at 800 nit boosted.
        try record(db, (0..<300).map { sample(base + $0, nits: 400, watts: 6) }
            + (300..<450).map { sample(base + $0, nits: 800, watts: 14, boosted: true, limited: $0 < 310) })
        let start = Date(timeIntervalSince1970: TimeInterval(base)), end = Date(timeIntervalSince1970: TimeInterval(base + 599))

        let points = try await db.reader.series(from: start, to: end, bucket: 600)
        #expect(points.count == 1)
        let nits = try #require(points.first?.nits)
        #expect(abs(nits.average - (400 * 300 + 800 * 150) / 450) < 0.1)
        #expect(nits.minimum == 400 && nits.maximum == 800)
        #expect(points.first?.boosted == true)

        let analysis = try await db.reader.analysis(from: start, to: end)
        #expect(analysis.recorded == 450 && analysis.boosted == 150 && analysis.thermalLimited == 10)
        #expect(abs(analysis.backlightWh - (6 * 300 + 14 * 150) / 3600.0) < 0.001)
        #expect(abs(analysis.boostWh - 14 * 150 / 3600.0) < 0.001)
        #expect(abs(analysis.systemWh - 20 * 450 / 3600.0) < 0.001)
        #expect(analysis.peakNits == 800)

        let bands = try await db.reader.distribution(from: start, to: end)
        #expect(bands.count == BrightnessBand.count)
        #expect(bands[2].seconds == 300 && bands[4].seconds == 150)

        let bars = try await db.reader.energy(from: start, to: end, bar: 3600, utcOffset: 0)
        #expect(abs(bars.reduce(0) { $0 + $1.boostWh } - analysis.boostWh) < 0.001)
    }

    @Test func pruningDropsSecondsBeforeSummaries() async throws {
        let (db, folder) = try database()
        defer { try? FileManager.default.removeItem(at: folder) }
        try record(db, (0..<900).map { sample(base + $0) })
        let cut = Date(timeIntervalSince1970: TimeInterval(base + 600))
        #expect(try await db.writer.prune(rawBefore: cut, rollupBefore: .distantPast) == 2)
        let info = try await db.reader.info()
        #expect(info.rawSeconds == 300 && info.rollupSeconds == 900)
        #expect(info.rawOldest == cut)
        try await db.writer.clear()
        #expect(try await db.reader.info().rollupSeconds == 0)
    }

    @Test func aMissingReadingStaysMissing() async throws {
        let (db, folder) = try database()
        defer { try? FileManager.default.removeItem(at: folder) }
        try record(db, [sample(base, nits: nil, watts: nil, celsius: .nan, lux: nil)])
        let point = try #require(try await db.reader.series(from: Date(timeIntervalSince1970: TimeInterval(base)),
                                                             to: Date(timeIntervalSince1970: TimeInterval(base)), bucket: 300).first)
        #expect(point.nits == nil && point.watts == nil && point.celsius == nil && point.lux == nil)
        #expect(point.systemWatts != nil)
    }

    @Test func theFirstVersionsTableIsReplaced() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("EazyDisplayTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Monitor.sqlite")
        var handle: OpaquePointer?
        sqlite3_open(url.path, &handle)
        sqlite3_exec(handle, "CREATE TABLE samples (t INTEGER PRIMARY KEY, nits REAL); INSERT INTO samples VALUES (1, 2)", nil, nil, nil)
        sqlite3_close(handle)

        let db = try MonitorDatabase(url: url)
        try record(db, [sample(base)])
        #expect(try await db.reader.info().rollupSeconds == 1)
        #expect(pragma(url, "SELECT count(*) FROM sqlite_master WHERE name = 'samples'") == "0")
    }

    /// WAL (so the reader never waits on the writer), incremental auto-vacuum (so pruning shrinks the file) and a
    /// 4 MiB page cache.
    @Test func theFileIsSetUpForItsJob() throws {
        let (db, folder) = try database()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(pragma(db.url, "PRAGMA journal_mode") == "wal")
        #expect(pragma(db.url, "PRAGMA auto_vacuum") == "2")
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/EazyDisplay/System/MonitorDatabase.swift"), encoding: .utf8)
        #expect(source.contains("private let cacheKiB = 4096"))
    }

    private func pragma(_ url: URL, _ sql: String) -> String {
        var handle: OpaquePointer?
        sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil)
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        sqlite3_step(statement)
        return String(cString: sqlite3_column_text(statement, 0))
    }
}

@Suite struct SeriesTests {
    @Test func secondsAreBucketedWithTheirExtremes() {
        let samples = (0..<30).map { sample(1000 + $0, nits: Double($0), boosted: $0 == 25) }
        let points = SeriesPoint.bucketed(samples, seconds: 10)
        #expect(points.count == 3)
        #expect(points[0].nits == SeriesPoint.Stat(average: 4.5, minimum: 0, maximum: 9))
        #expect(!points[1].boosted && points[2].boosted)
    }
}
