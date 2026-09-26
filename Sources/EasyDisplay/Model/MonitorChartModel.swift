import Foundation
import Observation

/// How far back the monitor's charts look, and where the data comes from.
enum MonitorRange: String, CaseIterable, Identifiable, Sendable {
    case fiveMinutes, hour, day, week, month

    enum Source {
        /// The seconds in memory.
        case recent
        /// Seconds from the raw blocks, averaged into buckets of this many seconds.
        case raw(bucket: Int)
        /// Five-minute rollups, combined into buckets of this many seconds.
        case rollup(bucket: Int)
    }

    var id: Self { self }

    var seconds: TimeInterval {
        switch self {
        case .fiveMinutes: 5 * 60
        case .hour: 60 * 60
        case .day: 24 * 60 * 60
        case .week: 7 * 24 * 60 * 60
        case .month: 30 * 24 * 60 * 60
        }
    }

    /// At most about 360 points, however long the range.
    var source: Source {
        switch self {
        case .fiveMinutes: .recent
        case .hour: .raw(bucket: 10)
        case .day: .rollup(bucket: 300)
        case .week: .rollup(bucket: 1800)
        case .month: .rollup(bucket: 7200)
        }
    }

    /// Seconds per point.
    var bucket: Int {
        switch source {
        case .recent: 1
        case .raw(let bucket), .rollup(let bucket): bucket
        }
    }

    /// A longer range changes slowly; no need to query it every second.
    var refreshInterval: TimeInterval {
        switch self {
        case .fiveMinutes: 1
        case .hour: 5
        case .day: 60
        case .week: 300
        case .month: 600
        }
    }

    var label: String { L("monitor.range.\(rawValue)") }
    /// "Last 5 minutes", above the charts.
    var span: String { L("monitor.span.\(rawValue)") }
}

/// One metric's readings over a range, and their low, high and average.
struct MetricSeries {
    struct Reading: Identifiable {
        let time: Date
        let stat: SeriesPoint.Stat
        /// Readings in consecutive buckets share a segment, which is one line. A missing bucket (EasyDisplay wasn't
        /// running, the Mac slept, the display was off) starts a new one: a line across it would show readings that
        /// were never taken.
        let segment: Int
        /// Alone in its segment, so drawn as a dot: a line needs two points.
        var isolated = false
        var id: Date { time }
    }

    private(set) var readings: [Reading] = []
    private(set) var low = Double.infinity
    private(set) var high = -Double.infinity
    private(set) var average = 0.0

    /// Whether `next` follows `previous` without a missing bucket. Samples come once a second and one can land a
    /// second late, skipping a one-second bucket without any time going unrecorded.
    static func continues(from previous: Date, to next: Date, bucket: Int) -> Bool {
        next.timeIntervalSince(previous) <= Double(bucket) + 1.5
    }

    init(metric: Metric, points: [SeriesPoint], bucket: Int) {
        readings.reserveCapacity(points.count)
        var segment = 0, previous: Date?, sum = 0.0
        for point in points {
            guard var stat = metric.stat(point) else { continue }
            if metric.isLogarithmic {
                // A log axis has no zero; a pitch-dark room reads as 0.1 lux.
                stat = SeriesPoint.Stat(average: max(stat.average, 0.1), minimum: max(stat.minimum, 0.1), maximum: max(stat.maximum, 0.1))
            }
            if let previous, !Self.continues(from: previous, to: point.time, bucket: bucket) { segment += 1 }
            previous = point.time
            readings.append(Reading(time: point.time, stat: stat, segment: segment))
            low = min(low, stat.minimum)
            high = max(high, stat.maximum)
            sum += stat.average
        }
        if !readings.isEmpty { average = sum / Double(readings.count) }
        for i in readings.indices {
            let segment = readings[i].segment
            readings[i].isolated = (i == 0 || readings[i - 1].segment != segment)
                && (i == readings.count - 1 || readings[i + 1].segment != segment)
        }
    }
}

/// The monitor's history for one set of charts.
@MainActor
@Observable
final class MonitorChartModel {
    var range: MonitorRange {
        didSet {
            guard range != oldValue else { return }
            UserDefaults.standard.set(range.rawValue, forKey: storageKey)
            show([])
            lastRefresh = .distantPast
            Task { await refreshIfDue() }
        }
    }

    /// The time pointed at in any of the charts.
    var selection: Date?
    private(set) var points: [SeriesPoint] = []
    /// Each metric's part of `points`, worked out once per refresh rather than by every chart.
    private(set) var series: [Metric: MetricSeries] = [:]
    /// Consecutive boosted points as one stretch each.
    private(set) var boostRuns: [ClosedRange<Date>] = []
    /// The right edge of the charts.
    private(set) var end = Date.now

    @ObservationIgnored let ranges: [MonitorRange]
    @ObservationIgnored private let monitor: SensorMonitor
    @ObservationIgnored private let storageKey: String
    @ObservationIgnored private var lastRefresh = Date.distantPast
    @ObservationIgnored private var inFlight = false
    @ObservationIgnored private var historyVersion = 0

    /// `place` keeps the tray's and Settings' ranges apart. Both start at five minutes.
    init(monitor: SensorMonitor, place: String, ranges: [MonitorRange] = MonitorRange.allCases) {
        self.monitor = monitor
        self.ranges = ranges
        storageKey = "monitor.range.\(place)"
        let stored = UserDefaults.standard.string(forKey: storageKey).flatMap(MonitorRange.init(rawValue:))
        range = stored.flatMap { ranges.contains($0) ? $0 : nil } ?? .fiveMinutes
    }

    var start: Date { end.addingTimeInterval(-range.seconds) }

    /// The point nearest the selection.
    var pointed: SeriesPoint? {
        guard let selection, !points.isEmpty else { return nil }
        // Points are in time order: the first at or after the selection, or the one before it.
        var lower = 0, upper = points.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if points[middle].time < selection { lower = middle + 1 } else { upper = middle }
        }
        guard lower > 0 else { return points[0] }
        guard lower < points.count else { return points[lower - 1] }
        let before = points[lower - 1], after = points[lower]
        return abs(after.time.timeIntervalSince(selection)) < abs(before.time.timeIntervalSince(selection)) ? after : before
    }

    func refreshIfDue(now: Date = .now) async {
        // History that was cleared is gone from the charts at once, not at the range's next refresh.
        if monitor.historyVersion != historyVersion {
            historyVersion = monitor.historyVersion
            show([])
            lastRefresh = .distantPast
        }
        guard !inFlight, now.timeIntervalSince(lastRefresh) >= range.refreshInterval - 0.05 else { return }
        inFlight = true
        defer { inFlight = false }
        lastRefresh = now
        let range = range
        let from = now.addingTimeInterval(-range.seconds)
        let recent = monitor.recent.drop { $0.time < from }
        do {
            let points: [SeriesPoint]
            switch range.source {
            case .recent:
                points = SeriesPoint.bucketed(recent, seconds: 1)
            case .raw(let bucket):
                var samples = try await monitor.database?.reader.samples(from: from, to: now) ?? []
                // The seconds not written yet.
                let newest = samples.last?.time ?? .distantPast
                samples += recent.drop { $0.time <= newest }
                points = SeriesPoint.bucketed(samples, seconds: bucket)
            case .rollup(let bucket):
                points = try await monitor.database?.reader.series(from: from, to: now, bucket: bucket) ?? []
            }
            // The range may have changed while reading.
            guard range == self.range else { return }
            end = now
            show(points)
        } catch {
            log.error("chart query failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func show(_ points: [SeriesPoint]) {
        self.points = points
        let bucket = range.bucket
        series = Dictionary(uniqueKeysWithValues: Metric.allCases.map { ($0, MetricSeries(metric: $0, points: points, bucket: bucket)) })
        let step = TimeInterval(bucket)
        var runs: [ClosedRange<Date>] = []
        var open: (start: Date, last: Date)?
        for point in points {
            if point.boosted, let run = open, MetricSeries.continues(from: run.last, to: point.time, bucket: bucket) {
                open = (run.start, point.time)
            } else {
                if let run = open { runs.append(run.start...run.last.addingTimeInterval(step)) }
                open = point.boosted ? (point.time, point.time) : nil
            }
        }
        if let run = open { runs.append(run.start...run.last.addingTimeInterval(step)) }
        boostRuns = runs
    }
}
