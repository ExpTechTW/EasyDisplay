import AppKit
import Charts
import SwiftUI

/// What the monitor charts, one small multiple each: they have different units, so each gets its own y axis rather
/// than sharing one.
enum Metric: CaseIterable, Identifiable {
    case brightness, power, temperature, ambient, systemPower

    var id: Self { self }

    var title: String {
        switch self {
        case .brightness: L("monitor.brightness")
        case .power: L("monitor.power")
        case .temperature: L("monitor.temperature")
        case .ambient: L("monitor.ambient")
        case .systemPower: L("monitor.system_power")
        }
    }

    var unit: String {
        switch self {
        case .brightness: "nit"
        case .power, .systemPower: "W"
        case .temperature: "°C"
        case .ambient: "lux"
        }
    }

    /// Fixed per metric, in this order, from a palette validated for color vision deficiency in light and dark
    /// (dataviz validate_palette.js: orange, blue, red, aqua, violet).
    var color: Color {
        switch self {
        case .brightness: .adaptive(light: 0xEB6834, dark: 0xD95926)
        case .power: .adaptive(light: 0x2A78D6, dark: 0x3987E5)
        case .temperature: .adaptive(light: 0xE34948, dark: 0xE66767)
        case .ambient: .adaptive(light: 0x1BAF7A, dark: 0x199E70)
        case .systemPower: .adaptive(light: 0x4A3AA7, dark: 0x9085E9)
        }
    }

    /// The y axis spans at least this much, so a steady reading doesn't look like noise.
    var minimumSpan: Double {
        switch self {
        case .brightness: 50
        case .power: 1
        case .temperature: 2
        case .ambient: 10
        case .systemPower: 5
        }
    }

    /// Ambient light spans five orders of magnitude, from a dark room to daylight.
    var isLogarithmic: Bool { self == .ambient }

    func stat(_ point: SeriesPoint) -> SeriesPoint.Stat? {
        switch self {
        case .brightness: point.nits
        case .power: point.watts
        case .temperature: point.celsius
        case .ambient: point.lux
        case .systemPower: point.systemWatts
        }
    }

    func current(_ sample: SensorSample?) -> Double? {
        switch self {
        case .brightness: sample?.nits
        case .power: sample?.backlightWatts
        case .temperature: sample?.displayCelsius
        case .ambient: sample?.lux
        case .systemPower: sample?.systemWatts
        }
    }

    func format(_ value: Double) -> String {
        switch self {
        case .brightness: "\(Int(value.rounded()))"
        case .ambient: value < 10 ? String(format: "%.1f", value) : "\(Int(value.rounded()))"
        case .power, .systemPower, .temperature: String(format: "%.1f", value)
        }
    }
}

extension Color {
    static func adaptive(light: Int, dark: Int) -> Color {
        func color(_ hex: Int) -> NSColor {
            NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? color(dark) : color(light)
        })
    }
}

/// The chosen metrics over one range, stacked on a shared time axis. Pointing at any of them moves one crosshair
/// through all of them and reads out every value at that time.
///
/// Each part observes only what it shows: the plots redraw when the data does, while pointing only moves the
/// crosshairs and readouts, and a new second only changes the current values.
struct MonitorCharts: View {
    let monitor: SensorMonitor
    @Bindable var model: MonitorChartModel
    var metrics: [Metric] = Metric.allCases
    var plotHeight: CGFloat = 56

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(L("monitor.range"), selection: $model.range) {
                ForEach(model.ranges) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)

            switch monitor.status {
            case .starting:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L("monitor.starting")).foregroundStyle(.secondary)
                }
            case .unavailable:
                Text(L("monitor.unavailable")).foregroundStyle(.secondary)
            case .running:
                PointedTime(model: model)
                ForEach(metrics) { metric in
                    VStack(alignment: .leading, spacing: 8) {
                        MetricHeader(metric: metric, monitor: monitor, model: model)
                        MetricPlot(metric: metric, model: model, showsTimeAxis: metric == metrics.last, plotHeight: plotHeight)
                    }
                }
                BoostKey(model: model)
            }
        }
        .background { Refresher(monitor: monitor, model: model) }
    }
}

/// Refreshes the model with each new sample.
private struct Refresher: View {
    let monitor: SensorMonitor
    let model: MonitorChartModel

    var body: some View {
        Color.clear
            .task(id: monitor.latest?.time) { await model.refreshIfDue() }
            .task(id: monitor.historyVersion) { await model.refreshIfDue() }
    }
}

/// The time being read, or which span the statistics cover; always there, so nothing below jumps.
private struct PointedTime: View {
    let model: MonitorChartModel

    var body: some View {
        let range = model.range
        Text(model.pointed.map { $0.time.formatted(date: range.seconds > 86400 ? .abbreviated : .omitted, time: range.seconds > 3600 ? .shortened : .standard) } ?? range.span)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
    }
}

/// Stretches where boost was on: a neutral wash behind the data, so it never reads as a series.
private let boostWash = Color.secondary.opacity(0.14)

private struct BoostKey: View {
    let model: MonitorChartModel

    var body: some View {
        if !model.boostRuns.isEmpty {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(boostWash).frame(width: 12, height: 10)
                Text(L("monitor.boosted_key")).font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// The metric's key, its low, high and average over the range, and its value now or where pointed.
private struct MetricHeader: View {
    let metric: Metric
    let monitor: SensorMonitor
    let model: MonitorChartModel

    var body: some View {
        let shown = model.pointed.flatMap(metric.stat)?.average ?? metric.current(monitor.latest)
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            // The line's key: identity comes from the mark, the text stays in text colors.
            Capsule().fill(metric.color).frame(width: 10, height: 3).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 3 }
            Text(metric.title).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(statistics).font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(shown.map(metric.format) ?? "—").font(.system(size: 15, weight: .semibold))
                Text(metric.unit).font(.caption).foregroundStyle(.secondary)
            }
            .frame(minWidth: 64, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private var statistics: String {
        guard let series = model.series[metric], !series.readings.isEmpty else { return "" }
        return LF("monitor.stats", metric.format(series.low), metric.format(series.high), metric.format(series.average))
    }
}

private struct MetricPlot: View {
    let metric: Metric
    @Bindable var model: MonitorChartModel
    let showsTimeAxis: Bool
    let plotHeight: CGFloat

    var body: some View {
        let readings = model.series[metric]?.readings ?? []
        let (low, high) = domain
        let range = model.range
        Chart {
            ForEach(model.boostRuns, id: \.lowerBound) { run in
                RectangleMark(xStart: .value("start", run.lowerBound), xEnd: .value("end", run.upperBound))
                    .foregroundStyle(boostWash)
            }
            if metric == .brightness, high > 600, low < 600 {
                // Where the panel's normal SDR range ends and boost takes over; a threshold, so it's dashed.
                RuleMark(y: .value("SDR", 600))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, alignment: .leading, spacing: 1) {
                        Text("600").font(.caption2).foregroundStyle(.tertiary)
                    }
            }
            ForEach(readings) { reading in
                if range.bucket > 1 {
                    AreaMark(
                        x: .value("time", reading.time),
                        yStart: .value("min", reading.stat.minimum),
                        yEnd: .value("max", reading.stat.maximum),
                        series: .value("segment", reading.segment)
                    )
                    .foregroundStyle(metric.color.opacity(0.14))
                }
                LineMark(
                    x: .value("time", reading.time),
                    y: .value(metric.unit, reading.stat.average),
                    series: .value("segment", reading.segment)
                )
                .foregroundStyle(metric.color)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                if reading.isolated {
                    PointMark(x: .value("time", reading.time), y: .value(metric.unit, reading.stat.average))
                        .foregroundStyle(metric.color)
                        .symbolSize(16)
                }
            }
        }
        .chartXScale(domain: model.start...model.end)
        .chartYScale(domain: low...high, type: metric.isLogarithmic ? .log : .linear)
        .chartXAxis {
            AxisMarks(values: .stride(by: tickUnit.component, count: tickUnit.count)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                if showsTimeAxis {
                    AxisValueLabel(format: tickFormat)
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                AxisValueLabel {
                    // A fixed width, so the three plots line up on the time axis.
                    Text(value.as(Double.self).map(metric.format) ?? "")
                        .frame(width: 30, alignment: .leading)
                }
            }
        }
        .chartXSelection(value: $model.selection)
        .chartOverlay { proxy in
            Crosshair(metric: metric, model: model, proxy: proxy)
        }
        .overlay {
            if readings.isEmpty {
                Text(L("monitor.no_data")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(height: plotHeight + (showsTimeAxis ? 18 : 0))
        .accessibilityLabel(metric.title)
    }

    private var domain: (Double, Double) {
        guard let series = model.series[metric], !series.readings.isEmpty else {
            // A log axis can't reach zero, and Charts traps on one that tries, e.g. before the first data arrives.
            return metric.isLogarithmic ? (1, 1000) : (0, metric.minimumSpan)
        }
        let low = series.low, high = series.high
        if metric.isLogarithmic {
            // At least a decade, with room above and below.
            let bottom = max(0.1, low / 1.6)
            return (bottom, max(high * 1.6, bottom * 10))
        }
        let padding = max((high - low) * 0.12, (metric.minimumSpan - (high - low)) / 2)
        let bottom = low - padding
        // Brightness, light and power never go below zero.
        return metric == .temperature ? (bottom, high + padding) : (max(0, bottom), high + padding)
    }

    private var tickUnit: (component: Calendar.Component, count: Int) {
        switch model.range {
        case .fiveMinutes: (.minute, 1)
        case .hour: (.minute, 15)
        case .day: (.hour, 6)
        case .week: (.day, 1)
        case .month: (.day, 7)
        }
    }

    private var tickFormat: Date.FormatStyle {
        switch model.range {
        case .fiveMinutes, .hour: .dateTime.hour().minute()
        case .day: .dateTime.hour()
        case .week: .dateTime.weekday(.abbreviated)
        case .month: .dateTime.month(.defaultDigits).day()
        }
    }
}

/// The pointed time across the plot, and a marker on the line, drawn over the chart so pointing never redraws it.
private struct Crosshair: View {
    let metric: Metric
    let model: MonitorChartModel
    let proxy: ChartProxy

    var body: some View {
        GeometryReader { geometry in
            if let pointed = model.pointed, let plot = proxy.plotFrame.map({ geometry[$0] }),
               let x = proxy.position(forX: pointed.time) {
                Rectangle()
                    .fill(.secondary.opacity(0.6))
                    .frame(width: 1, height: plot.height)
                    .position(x: plot.minX + x, y: plot.midY)
                if let stat = metric.stat(pointed),
                   let y = proxy.position(forY: metric.isLogarithmic ? max(stat.average, 0.1) : stat.average) {
                    // A ring in the surface color keeps the marker clear of the line it sits on.
                    Circle()
                        .fill(metric.color)
                        .frame(width: 7, height: 7)
                        .padding(2)
                        .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                        .position(x: plot.minX + x, y: plot.minY + y)
                }
            }
        }
        .allowsHitTesting(false)
    }
}
