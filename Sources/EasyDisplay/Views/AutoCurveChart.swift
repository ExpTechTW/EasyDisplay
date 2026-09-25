import Charts
import SwiftUI

/// Boosted auto-brightness on one chart: the default curve, the curve the user's choices have bent it into, the
/// choices themselves, and where the display is now.
struct AutoCurveChart: View {
    let curve: AutoBrightnessCurve
    /// The light level followed now and the brightness it gives, while boosted.
    let now: (lux: Double, nits: Double)?

    private static let luxRange = 0.1...20_000.0
    /// Where the curves are drawn, with the default curve's brightness there, which never changes.
    private static let samples = stride(from: -1.0, through: log10(20_000), by: 0.05).map { x in
        (lux: pow(10, x), defaultNits: AmbientLight.nits(atLog10Lux: x))
    }

    var body: some View {
        let defaultLabel = L("curve.default"), learnedLabel = L("curve.learned")
        Chart {
            ForEach(Self.samples, id: \.lux) { sample in
                LineMark(x: .value("lux", sample.lux), y: .value("nit", sample.defaultNits), series: .value("curve", defaultLabel))
                    .foregroundStyle(by: .value("curve", defaultLabel))
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                LineMark(x: .value("lux", sample.lux), y: .value("nit", curve.nits(forLux: sample.lux)), series: .value("curve", learnedLabel))
                    .foregroundStyle(by: .value("curve", learnedLabel))
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            ForEach(curve.points, id: \.date) { point in
                // A ring in the surface color keeps each choice clear of the line it sits on.
                PointMark(x: .value("lux", max(point.lux, 0.1)), y: .value("nit", point.nits))
                    .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                    .symbolSize(90)
                PointMark(x: .value("lux", max(point.lux, 0.1)), y: .value("nit", point.nits))
                    .foregroundStyle(Metric.brightness.color)
                    .symbolSize(40)
            }
            if let now {
                RuleMark(x: .value("lux", max(now.lux, 0.1)))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, alignment: .leading, spacing: 2) {
                        Text(LF("curve.now", Metric.ambient.format(now.lux), Int(now.nits.rounded())))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .chartForegroundStyleScale([defaultLabel: Color.secondary.opacity(0.6), learnedLabel: Metric.brightness.color])
        .chartLegend(position: .top, alignment: .leading)
        .chartXScale(domain: Self.luxRange, type: .log)
        .chartYScale(domain: 0...BuiltInDisplay.maxBoostNits)
        .chartXAxis {
            AxisMarks(values: [0.1, 1, 10, 100, 1000, 10000]) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                AxisValueLabel {
                    if let lux = value.as(Double.self) { Text(lux < 1 ? "0.1" : "\(Int(lux)) lux") }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: [0, 250, 500, 750, 1000]) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                AxisValueLabel { Text("\(value.as(Int.self) ?? 0)") }
            }
        }
        .frame(height: 200)
        .accessibilityLabel(L("curve.title"))
    }
}
