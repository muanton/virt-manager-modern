import SwiftUI
import Charts

/// A compact area+line chart for a single numeric metric over time, with the
/// latest value shown as a headline. Used for CPU% and memory history.
struct StatChart: View {
    let title: String
    let samples: [ConnectionSession.StatSample]
    /// Fixed y-axis range; when nil the range is derived from the samples.
    let yDomain: ClosedRange<Double>?
    let tint: Color
    /// Formats a y value for the headline and axis labels.
    let format: (Double) -> String
    let value: (ConnectionSession.StatSample) -> Double

    init(title: String,
         samples: [ConnectionSession.StatSample],
         yDomain: ClosedRange<Double>? = nil,
         tint: Color,
         format: @escaping (Double) -> String,
         value: @escaping (ConnectionSession.StatSample) -> Double) {
        self.title = title
        self.samples = samples
        self.yDomain = yDomain
        self.tint = tint
        self.format = format
        self.value = value
    }

    private var domain: ClosedRange<Double> {
        if let yDomain { return yDomain }
        let top = samples.map(value).max() ?? 1
        return 0...max(1, top)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let last = samples.last {
                    Text(format(value(last)))
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            Chart(samples) { sample in
                AreaMark(x: .value("Time", sample.at),
                         y: .value(title, value(sample)))
                    .foregroundStyle(tint.opacity(0.15))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", sample.at),
                         y: .value(title, value(sample)))
                    .foregroundStyle(tint)
                    .interpolationMethod(.monotone)
            }
            .chartYScale(domain: domain)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { v in
                    AxisGridLine()
                    AxisValueLabel {
                        if let d = v.as(Double.self) {
                            Text(format(d)).font(.caption2)
                        }
                    }
                }
            }
            .frame(height: 90)
        }
        .padding(.vertical, 2)
    }
}

/// A compact two-series line chart (e.g. disk read/write, network rx/tx) with a
/// legend and per-series latest rate in the headline. Values are byte rates.
struct DualStatChart: View {
    let title: String
    let samples: [ConnectionSession.StatSample]
    let series: [(label: String, keyPath: KeyPath<ConnectionSession.StatSample, UInt64>)]

    private static let palette: [Color] = [.blue, .orange]

    private struct Point: Identifiable {
        let id = UUID()
        let at: Date
        let series: String
        let value: Double
    }

    private var points: [Point] {
        samples.flatMap { s in
            series.map { Point(at: s.at, series: $0.label,
                               value: Double(s[keyPath: $0.keyPath])) }
        }
    }

    private var colors: [Color] { Array(Self.palette.prefix(series.count)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let last = samples.last {
                    ForEach(Array(series.enumerated()), id: \.offset) { idx, s in
                        Text("\(s.label) \(Format.rate(bytesPerSecond: last[keyPath: s.keyPath]))")
                            .font(.caption2).monospacedDigit()
                            .foregroundStyle(colors[idx])
                    }
                }
            }
            Chart(points) { p in
                LineMark(x: .value("Time", p.at),
                         y: .value("Rate", p.value))
                    .foregroundStyle(by: .value("Series", p.series))
                    .interpolationMethod(.monotone)
            }
            .chartForegroundStyleScale(domain: series.map(\.label), range: colors)
            .chartLegend(.hidden)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { v in
                    AxisGridLine()
                    AxisValueLabel {
                        if let d = v.as(Double.self) {
                            Text(Format.rate(bytesPerSecond: UInt64(max(0, d)))).font(.caption2)
                        }
                    }
                }
            }
            .frame(height: 90)
        }
        .padding(.vertical, 2)
    }
}
