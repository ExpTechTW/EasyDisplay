import Charts
import SwiftUI

/// What the rollups add up to over today, the last week or the last month: time boosted, backlight energy against the
/// whole system's, brightness, temperature and ambient light, with energy per hour or day and how the brightness was
/// spread.
struct MonitorAnalysisSection: View {
    enum Period: String, CaseIterable, Identifiable {
        case today, week, month

        var id: Self { self }
        var label: String { L("analysis.period.\(rawValue)") }

        func start(now: Date) -> Date {
            switch self {
            case .today: Calendar.current.startOfDay(for: now)
            case .week: now.addingTimeInterval(-7 * 86400)
            case .month: now.addingTimeInterval(-30 * 86400)
            }
        }

        /// Hourly bars for today, daily otherwise.
        var bar: Int { self == .today ? 3600 : 86400 }
    }

    private struct Result: Equatable {
        var summary: MonitorAnalysis
        var energy: [EnergyBar]
        var bands: [BrightnessBand]
        var start: Date
        var end: Date
    }

    let database: MonitorDatabase?
    @Environment(\.locale) private var locale
    @AppStorage("analysis.period") private var period = Period.week
    @State private var result: Result?

    init(database: MonitorDatabase?) {
        self.database = database
    }

    var body: some View {
        Section {
            Picker(L("analysis.period"), selection: $period) {
                ForEach(Period.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if let result, result.summary.recorded > 0 {
                let summary = result.summary
                HStack(spacing: 8) {
                    StatTile(
                        label: L("analysis.boost_time"),
                        value: duration(summary.boosted),
                        detail: LF("analysis.share_of_recorded", share(summary.boosted, of: summary.recorded))
                    )
                    StatTile(
                        label: L("analysis.energy"),
                        value: String(format: "%.1f Wh", summary.backlightWh),
                        detail: summary.systemWh > 0 ? LF("analysis.share_of_system", share(summary.backlightWh, of: summary.systemWh)) : " "
                    )
                    StatTile(
                        label: L("analysis.average_brightness"),
                        value: summary.averageNits.map { "\(Int($0.rounded())) nit" } ?? "—",
                        detail: summary.peakNits.map { LF("analysis.peak", "\(Int($0.rounded())) nit") } ?? " "
                    )
                }
                .padding(.vertical, 2)

                EnergyChart(bars: result.energy, bar: period.bar, start: result.start, end: result.end)
                DistributionChart(bands: result.bands, locale: locale)

                LabeledContent(L("analysis.recorded"), value: duration(summary.recorded))
                LabeledContent(L("analysis.boost_energy")) {
                    Text(String(format: "%.1f Wh", summary.boostWh)).monospacedDigit()
                }
                LabeledContent(L("analysis.average_power")) {
                    Text(summary.averageBacklightWatts.map { String(format: "%.2f W", $0) } ?? "—").monospacedDigit()
                }
                LabeledContent(L("analysis.peak_temperature")) {
                    Text(summary.peakCelsius.map { String(format: "%.1f °C", $0) } ?? "—").monospacedDigit()
                }
                LabeledContent(L("analysis.thermal_time"), value: duration(summary.thermalLimited))
                LabeledContent(L("analysis.average_lux")) {
                    Text(summary.averageLux.map { Metric.ambient.format($0) + " lux" } ?? "—").monospacedDigit()
                }
                LabeledContent(L("analysis.battery_time"), value: duration(summary.onBattery))
            } else if result != nil {
                Text(L("analysis.no_data")).foregroundStyle(.secondary)
            }
        } header: {
            Text(L("analysis.title"))
        } footer: {
            Text(L("analysis.hint"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task(id: period) {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func load() async {
        guard let reader = database?.reader else { return }
        let now = Date.now, start = period.start(now: now)
        let offset = TimeZone.current.secondsFromGMT(for: now)
        do {
            result = Result(
                summary: try await reader.analysis(from: start, to: now),
                energy: try await reader.energy(from: start, to: now, bar: period.bar, utcOffset: offset),
                bands: try await reader.distribution(from: start, to: now),
                start: start,
                end: now
            )
        } catch {
            log.error("analysis failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func duration(_ seconds: TimeInterval) -> String {
        durationText(seconds, locale: locale)
    }

    private func share(_ part: Double, of whole: Double) -> String {
        (whole > 0 ? part / whole : 0).formatted(.percent.precision(.fractionLength(0)).locale(locale))
    }
}

func durationText(_ seconds: TimeInterval, locale: Locale) -> String {
    let fields: Set<Duration.UnitsFormatStyle.Unit> = seconds >= 3600 ? [.hours, .minutes] : [.minutes]
    return Duration.seconds(seconds.rounded()).formatted(.units(allowed: fields, width: .abbreviated).locale(locale))
}

/// A number the analysis leads with: its label, the value, and one line of context.
private struct StatTile: View {
    let label: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 20, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
            Text(detail).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Backlight energy per hour or day, the boosted share stacked on the rest.
private struct EnergyChart: View {
    let bars: [EnergyBar]
    let bar: Int
    let start: Date
    let end: Date

    var body: some View {
        let normal = L("analysis.energy_normal"), boost = L("analysis.energy_boost")
        let unit: Calendar.Component = bar == 3600 ? .hour : .day
        VStack(alignment: .leading, spacing: 6) {
            Text(L("analysis.energy_chart")).font(.caption).foregroundStyle(.secondary)
            Chart {
                ForEach(bars) { bar in
                    BarMark(x: .value("time", bar.start, unit: unit), y: .value("Wh", bar.normalWh), width: .ratio(0.7))
                        .foregroundStyle(by: .value("kind", normal))
                    BarMark(x: .value("time", bar.start, unit: unit), y: .value("Wh", bar.boostWh), width: .ratio(0.7))
                        .foregroundStyle(by: .value("kind", boost))
                }
            }
            .chartForegroundStyleScale([normal: Metric.power.color, boost: Metric.brightness.color])
            .chartLegend(position: .top, alignment: .leading)
            // Whole hours or days, so the current one's bar sits inside the plot instead of running past it.
            .chartXScale(domain: floor(start, unit)...ceiling(end, unit))
            .chartXAxis {
                AxisMarks(values: .stride(by: unit, count: bar == 3600 ? 6 : (end.timeIntervalSince(start) > 8 * 86400 ? 7 : 1))) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    AxisValueLabel(format: bar == 3600 ? .dateTime.hour() : .dateTime.month(.defaultDigits).day(), centered: bar != 3600)
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    AxisValueLabel { Text("\(value.as(Double.self).map { String(format: "%g", $0) } ?? "") Wh") }
                }
            }
            .frame(height: 150)
        }
        .padding(.vertical, 4)
    }

    private func floor(_ date: Date, _ unit: Calendar.Component) -> Date {
        Calendar.current.dateInterval(of: unit, for: date)?.start ?? date
    }

    private func ceiling(_ date: Date, _ unit: Calendar.Component) -> Date {
        Calendar.current.dateInterval(of: unit, for: date)?.end ?? date
    }
}

/// How long the display spent in each 200-nit band, as aligned rows: a band's label, its bar, its time.
private struct DistributionChart: View {
    let bands: [BrightnessBand]
    let locale: Locale

    var body: some View {
        let longest = max(bands.map(\.seconds).max() ?? 0, 1)
        VStack(alignment: .leading, spacing: 6) {
            Text(L("analysis.distribution")).font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                ForEach(bands) { band in
                    GridRow {
                        Text("\(Int(band.lower))–\(Int(band.lower + BrightnessBand.width)) nit")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                        GeometryReader { geometry in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Metric.brightness.color)
                                .frame(width: band.seconds > 0 ? max(geometry.size.width * band.seconds / longest, 3) : 0)
                        }
                        .frame(height: 12)
                        Text(band.seconds > 0 ? durationText(band.seconds, locale: locale) : "—")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 64, alignment: .trailing)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

#if DEBUG
/// Lets layout snapshots show the analysis charts with data of their choosing.
struct AnalysisChartsPreview: View {
    let energy: [EnergyBar]
    let bands: [BrightnessBand]
    let bar: Int
    let start: Date
    let end: Date

    var body: some View {
        Form {
            Section {
                EnergyChart(bars: energy, bar: bar, start: start, end: end)
                DistributionChart(bands: bands, locale: Locale(identifier: "zh-Hant"))
            }
        }
        .formStyle(.grouped)
    }
}
#endif
