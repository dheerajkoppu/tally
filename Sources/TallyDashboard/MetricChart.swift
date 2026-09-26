import SwiftUI
import Accessibility
import TallyCore

/// One chart sample: `position` runs 0 (left edge) to 1 (right edge).
struct MetricChartPoint: Hashable {
    var position: Double
    var value: Double
    var date: Date?
}

enum MetricChartDateStyle: Hashable {
    /// "2:32:05 PM", for the live buffer.
    case seconds
    /// "Mon 2:30 PM", for the 12 and 24 hour ranges.
    case weekdayAndTime
    /// "Sep 21, 2 PM", for the 7 and 30 day ranges.
    case dayAndHour
}

/// Everything a chart draws. Equatable, so a chart only redraws when its data changes.
struct MetricChartData: Equatable {
    var points: [MetricChartPoint]
    var maxValue: Double
    /// The line breaks where neighbouring points are further apart than this.
    var breakGap: Double?
    var dateStyle: MetricChartDateStyle
    var format: MetricValueFormat
    /// Spoken name: "CPU".
    var name: String
    /// "last 5 min", "last 12 hours".
    var span: String
    var isLive: Bool

    /// "12% now, peak 40%, last 5 min", for VoiceOver.
    var accessibilitySummary: String {
        let values = points.map(\.value)
        guard let last = values.last, let peak = values.max() else { return "No data yet" }
        if isLive {
            return "\(format.text(last)) now, peak \(format.text(peak)), \(span)"
        }
        let average = values.reduce(0, +) / Double(values.count)
        return "Average \(format.text(average)), peak \(format.text(peak)), \(span)"
    }

    /// The highest point's distance from the top, 0...1, where the gradient under the line starts.
    var highestUnitY: Double {
        guard let peak = points.map(\.value).max(), maxValue > 0 else { return 0 }
        return 1 - min(max(peak / maxValue, 0), 1)
    }
}

/// A line over a gradient fill, on four faint grid lines, as in the Tally tab hero cards.
/// Drawn with shapes rather than a canvas, so an unchanged chart costs nothing to redraw.
struct MetricAreaChart: View, Equatable {
    let data: MetricChartData
    let tint: Color
    var lineWidth: CGFloat = 2

    @Environment(\.colorScheme) private var colorScheme

    static func == (lhs: MetricAreaChart, rhs: MetricAreaChart) -> Bool {
        lhs.data == rhs.data && lhs.tint == rhs.tint && lhs.lineWidth == rhs.lineWidth
    }

    var body: some View {
        let topOpacity = colorScheme == .dark ? 0.27 : 0.32
        ZStack {
            MetricGridLines()
                .stroke(Palette.line, lineWidth: 1)
            MetricChartPath(points: data.points, maxValue: data.maxValue, breakGap: data.breakGap, inset: lineWidth / 2, isArea: true)
                .fill(LinearGradient(
                    colors: [tint.opacity(topOpacity), tint.opacity(0.02)],
                    startPoint: UnitPoint(x: 0.5, y: data.highestUnitY),
                    endPoint: .bottom
                ))
            MetricChartPath(points: data.points, maxValue: data.maxValue, breakGap: data.breakGap, inset: lineWidth / 2, isArea: false)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
        .overlay { MetricChartHover(data: data, tint: tint, lineWidth: lineWidth) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(data.name) chart")
        .accessibilityValue(data.accessibilitySummary)
        .accessibilityAddTraits(data.isLive ? [.isImage, .updatesFrequently] : .isImage)
        .accessibilityChartDescriptor(MetricChartDescriptor(data: data))
    }

    /// The most recent live values across the full width. Until the buffer holds `slots` samples the points spread
    /// over the width; after that the window scrolls, one slot per sample.
    static func livePoints(_ values: [Double], dates: [Date], slots: Int) -> [MetricChartPoint] {
        let recent = Array(values.suffix(slots))
        let recentDates = Array(dates.suffix(recent.count))
        let span = Double(max(recent.count - 1, 1))
        return recent.indices.map { index in
            MetricChartPoint(
                position: recent.count == 1 ? 1 : Double(index) / span,
                value: recent[index].isFinite ? recent[index] : 0,
                date: index < recentDates.count ? recentDates[index] : nil
            )
        }
    }

    /// History buckets placed by their midpoint within the range that ends at `now`. Bucket dates mark each bucket's start.
    static func historyPoints(_ points: [HistoryPoint], range: HistoryRange, buckets: Int, now: Date) -> [MetricChartPoint] {
        let start = now.addingTimeInterval(-range.duration)
        let halfBucket = range.duration / Double(max(buckets, 1)) / 2
        return points
            .sorted { $0.date < $1.date }
            .map { point in
                let position = (point.date.timeIntervalSince(start) + halfBucket) / range.duration
                return MetricChartPoint(position: min(max(position, 0), 1), value: point.value.isFinite ? point.value : 0, date: point.date)
            }
    }

    private static let secondsFormatter = MetricAreaChart.formatter("jms")
    private static let weekdayFormatter = MetricAreaChart.formatter("EEEjm")
    private static let dayFormatter = MetricAreaChart.formatter("MMMdj")

    private static func formatter(_ template: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }

    static func dateText(_ date: Date, style: MetricChartDateStyle) -> String {
        switch style {
        case .seconds: secondsFormatter.string(from: date)
        case .weekdayAndTime: weekdayFormatter.string(from: date)
        case .dayAndHour: dayFormatter.string(from: date)
        }
    }
}

/// The chart's points for VoiceOver's chart description and audio graph: time before the latest point against the
/// figure, in the chart's own units. Built only when an assistive app asks for it.
struct MetricChartDescriptor: AXChartDescriptorRepresentable {
    let data: MetricChartData

    func makeChartDescriptor() -> AXChartDescriptor {
        let latest = data.points.last?.date ?? Date()
        let offsets = data.points.map { point in point.date.map { $0.timeIntervalSince(latest) } ?? 0 }
        let earliest = min(offsets.min() ?? 0, -1)
        let format = data.format
        let xAxis = AXNumericDataAxisDescriptor(title: "Time", range: earliest...0, gridlinePositions: []) { ChartUnit.timeAgo($0) }
        let yAxis = AXNumericDataAxisDescriptor(title: data.name, range: 0...max(data.maxValue, 0.000_001), gridlinePositions: []) { format.text($0) }
        let points = zip(offsets, data.points).map { offset, point in AXDataPoint(x: offset, y: point.value) }
        let series = AXDataSeriesDescriptor(name: data.name, isContinuous: true, dataPoints: points)
        return AXChartDescriptor(title: "\(data.name), \(data.span)", summary: data.accessibilitySummary, xAxis: xAxis, yAxis: yAxis, series: [series])
    }
}

/// Four evenly spaced horizontal rules.
struct MetricGridLines: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for index in 0..<4 {
            let y = rect.minY + 0.5 + (rect.height - 1) * CGFloat(index) / 3
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        return path
    }
}

/// The chart line, or the area under it, broken into segments across gaps in the data.
struct MetricChartPath: Shape {
    var points: [MetricChartPoint]
    var maxValue: Double
    var breakGap: Double?
    var inset: CGFloat
    var isArea: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let top = max(maxValue, 0.000_001)
        var segmentStart: CGPoint?
        var previous: (position: Double, location: CGPoint)?

        func closeSegment() {
            guard isArea, let start = segmentStart, let last = previous?.location else { return }
            path.addLine(to: CGPoint(x: last.x, y: rect.maxY))
            path.addLine(to: CGPoint(x: start.x, y: rect.maxY))
            path.closeSubpath()
        }

        for point in points {
            let fraction = min(max(point.value / top, 0), 1)
            let location = CGPoint(
                x: rect.minX + CGFloat(point.position) * rect.width,
                y: rect.minY + inset + (rect.height - inset * 2) * CGFloat(1 - fraction)
            )
            if let previous, point.position - previous.position <= (breakGap ?? .infinity) {
                path.addLine(to: location)
            } else {
                closeSegment()
                path.move(to: location)
                // A lone point still shows as a dot through the round line cap.
                if !isArea { path.addLine(to: location) }
                segmentStart = location
            }
            previous = (point.position, location)
        }
        closeSegment()
        return path
    }
}

/// The dashed rule, dot and value label that follow the pointer. Only this view redraws while hovering.
struct MetricChartHover: View {
    let data: MetricChartData
    let tint: Color
    let lineWidth: CGFloat

    @State private var hoveredIndex: Int?
    @State private var size: CGSize = .zero

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    let index = nearestIndex(to: location.x)
                    if index != hoveredIndex { hoveredIndex = index }
                case .ended:
                    hoveredIndex = nil
                }
            }
            .overlay(alignment: .topLeading) {
                if let hoveredIndex, hoveredIndex < data.points.count {
                    marker(for: data.points[hoveredIndex])
                }
            }
    }

    private func location(of point: MetricChartPoint) -> CGPoint {
        let top = max(data.maxValue, 0.000_001)
        let fraction = min(max(point.value / top, 0), 1)
        let inset = lineWidth / 2
        return CGPoint(x: CGFloat(point.position) * size.width, y: inset + (size.height - inset * 2) * CGFloat(1 - fraction))
    }

    private func nearestIndex(to x: CGFloat) -> Int? {
        guard let first = data.points.first, let last = data.points.last, size.width > 0 else { return nil }
        let position = Double(x / size.width)
        let slack = Double(12 / size.width)
        guard position >= first.position - slack, position <= last.position + slack else { return nil }
        return data.points.indices.min { abs(data.points[$0].position - position) < abs(data.points[$1].position - position) }
    }

    private func marker(for point: MetricChartPoint) -> some View {
        let spot = location(of: point)
        return ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: CGPoint(x: spot.x, y: 0))
                path.addLine(to: CGPoint(x: spot.x, y: size.height))
            }
            .stroke(Palette.ink3.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
                .padding(2)
                .background(Palette.card, in: Circle())
                .position(spot)
            MetricChartLabel(point: point, format: data.format, dateStyle: data.dateStyle)
                .fixedSize()
                .alignmentGuide(.leading) { dimensions in
                    let x = spot.x - dimensions.width / 2
                    return -min(max(x, 0), max(size.width - dimensions.width, 0))
                }
                .offset(y: -2)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

/// "44% Mon 2:30 PM" in a capsule above the hovered point.
struct MetricChartLabel: View {
    let point: MetricChartPoint
    let format: MetricValueFormat
    let dateStyle: MetricChartDateStyle

    var body: some View {
        HStack(spacing: 5) {
            Text(format.text(point.value))
                .font(Typography.chartLabel)
                .foregroundStyle(Palette.ink)
            if let date = point.date {
                Text(MetricAreaChart.dateText(date, style: dateStyle))
                    .font(Typography.chartLabelDetail)
                    .foregroundStyle(Palette.ink2)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Palette.background, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.line))
    }
}
