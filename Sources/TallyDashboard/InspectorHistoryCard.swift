import SwiftUI
import TallyCore

/// The app's CPU, memory or power over a range, from history, with the samples taken while the sheet is open as a fallback.
struct InspectorHistoryCard: View {
    @ObservedObject var model: InspectorChartModel
    @Binding var metric: InspectorMetric
    @Binding var range: MetricRange

    var body: some View {
        let resolved = resolve()
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                MetricRangePicker(label: "Figure", items: InspectorMetric.allCases, selection: $metric, tint: metric.tint, title: \.title)
                Spacer(minLength: 8)
                MetricRangePicker(label: "Range", items: MetricRange.all, selection: $range, tint: metric.tint, title: \.label)
            }
            MetricAreaChart(data: resolved.chart, tint: metric.tint)
                .equatable()
                .frame(height: 130)
                .overlay {
                    if resolved.chart.points.isEmpty {
                        Text("Collecting samples")
                            .font(Typography.label)
                            .foregroundStyle(Palette.ink2)
                    }
                }
            HStack(spacing: 14) {
                Text(resolved.caption)
                    .foregroundStyle(Palette.ink2)
                Spacer(minLength: 8)
                if let average = resolved.average {
                    summary("Average", metric.format.text(average))
                }
                if let peak = resolved.peak {
                    summary("Peak", metric.format.text(peak))
                }
            }
            .font(Typography.rowSubtitle)
            .lineLimit(1)
        }
        .padding(16)
        .metricSurface()
    }

    private func summary(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(Palette.ink2)
            Text(value).fontWeight(.semibold).monospacedDigit().foregroundStyle(Palette.ink)
        }
        .accessibilityElement(children: .combine)
    }

    private struct Resolved {
        var chart: MetricChartData
        var caption: String
        var average: Double?
        var peak: Double?
    }

    private func resolve() -> Resolved {
        let liveValues = model.samples.map { metric.value(of: $0) }
        let liveDates = model.samples.map(\.date)
        let livePoints = MetricAreaChart.livePoints(liveValues, dates: liveDates, slots: InspectorChartModel.liveCapacity)
        let liveSpan = "last \(MetricTabContent.liveSpan(liveDates))"

        func live(_ caption: String) -> Resolved {
            let chart = MetricChartData(points: livePoints, maxValue: scaleMax(liveValues), breakGap: nil, dateStyle: .seconds, format: metric.format, name: metric.title, span: liveSpan, isLive: true)
            return Resolved(chart: chart, caption: caption, average: Self.average(liveValues), peak: liveValues.max())
        }

        guard let historyRange = range.historyRange else {
            return live(model.samples.count < 2 ? "Sampling while this sheet is open" : "Live, \(liveSpan)")
        }
        guard let loaded = model.history, loaded.key == InspectorChartModel.Key(range: historyRange, metric: metric) else {
            return live("Loading the \(historyRange.metricPhrase)")
        }
        if loaded.points.count < 2 {
            return live("No history for the \(historyRange.metricPhrase) yet. Showing live.")
        }
        let values = loaded.points.map(\.value)
        let dateStyle: MetricChartDateStyle = historyRange.duration > 86400 ? .dayAndHour : .weekdayAndTime
        let points = MetricAreaChart.historyPoints(loaded.points, range: historyRange, buckets: historyRange.metricBuckets, now: loaded.loadedAt)
        var caption = historyRange.metricPhrase.prefix(1).uppercased() + historyRange.metricPhrase.dropFirst()
        if let first = points.first, first.position > 0.05, let date = first.date {
            caption = "Recorded since \(MetricAreaChart.dateText(date, style: dateStyle))"
        }
        let chart = MetricChartData(
            points: points,
            maxValue: scaleMax(values),
            breakGap: 2.5 / Double(historyRange.metricBuckets),
            dateStyle: dateStyle,
            format: metric.format,
            name: metric.title,
            span: historyRange.metricPhrase,
            isLive: false
        )
        return Resolved(chart: chart, caption: caption, average: Self.average(values), peak: values.max())
    }

    private func scaleMax(_ values: [Double]) -> Double {
        max((values.max() ?? 0) * 1.15, metric.floor)
    }

    private static func average(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
}
