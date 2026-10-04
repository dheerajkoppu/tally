import SwiftUI
import Accessibility

/// Clamps to 0...1 and rounds to `steps`, so a change far below a pixel does not redraw.
func quantizedFraction(_ value: Double, steps: Double = 1000) -> Double {
    guard value.isFinite else { return 0 }
    return (min(max(value, 0), 1) * steps).rounded() / steps
}

extension View {
    /// Makes a chart one VoiceOver element with a spoken summary ("CPU, 12 percent, last 20 minutes"),
    /// or hides it when it only repeats figures shown beside it.
    @ViewBuilder
    public func chartAccessibility(_ summary: String?) -> some View {
        if let summary {
            accessibilityElement(children: .ignore)
                .accessibilityLabel(summary)
                .accessibilityAddTraits(.isImage)
        } else {
            accessibilityHidden(true)
        }
    }
}

/// How VoiceOver speaks a chart's values.
public enum ChartUnit: Hashable, Sendable {
    case percent
    case memory
    case rate
    case power
    /// Celsius values, spoken in the chosen unit.
    case temperature(TemperatureUnit)

    public func text(_ value: Double) -> String {
        let safe = value.isFinite ? value : 0
        return switch self {
        case .percent: Format.percent(safe).text
        case .memory: Format.memory(safe > 0 ? UInt64(min(safe, 1e18)) : 0).text
        case .rate: Format.rate(safe).text
        case .power: Format.power(safe).text
        case .temperature(let unit): Format.temperature(safe, unit: unit).text
        }
    }

    /// "now", "40 seconds ago", "12 min ago", for a point `seconds` before the latest.
    public static func timeAgo(_ seconds: Double) -> String {
        let elapsed = abs(seconds)
        if elapsed < 1 { return "now" }
        if elapsed < 60 { return "\(Int(elapsed)) seconds ago" }
        return "\(Format.span(elapsed)) ago"
    }
}

/// Evenly spaced samples of one figure over time, as VoiceOver's chart description and audio graph see them.
/// Holds only what the chart already has; the descriptor is built when an assistive app asks for it, never per sample.
public struct SeriesChartDescriptor: AXChartDescriptorRepresentable, Equatable {
    public var title: String
    public var summary: String
    public var seriesName: String
    /// Values as fractions of `scale`, oldest first.
    public var fractions: [Double]
    public var scale: Double
    /// Seconds between neighbouring values.
    public var spacing: Double
    public var unit: ChartUnit

    public init(title: String, summary: String, seriesName: String, fractions: [Double], scale: Double, spacing: Double, unit: ChartUnit) {
        self.title = title
        self.summary = summary
        self.seriesName = seriesName
        self.fractions = fractions
        self.scale = scale
        self.spacing = spacing
        self.unit = unit
    }

    public func makeChartDescriptor() -> AXChartDescriptor {
        let count = fractions.count
        let span = Double(max(count - 1, 1)) * spacing
        let unit = unit
        let xAxis = AXNumericDataAxisDescriptor(title: "Time", range: -span...0, gridlinePositions: []) { ChartUnit.timeAgo($0) }
        let yAxis = AXNumericDataAxisDescriptor(title: seriesName, range: 0...max(scale, 0.000_001), gridlinePositions: []) { unit.text($0) }
        let points = fractions.enumerated().map { index, fraction in
            AXDataPoint(x: -Double(count - 1 - index) * spacing, y: fraction * scale)
        }
        let series = AXDataSeriesDescriptor(name: seriesName, isContinuous: true, dataPoints: points)
        return AXChartDescriptor(title: title, summary: summary, xAxis: xAxis, yAxis: yAxis, series: [series])
    }
}

/// How wide a bar chart's columns are.
public enum BarSlot: Equatable, Sendable {
    /// Every value gets a column and the columns share the width, as the cores of a CPU do.
    case fill
    /// Columns about this wide, newest value at the right edge. Older values that do not fit are dropped, and
    /// columns with no value yet stay empty.
    case fixed(CGFloat)
}

/// Bottom-aligned columns, one per fraction of the full height, as one path. As a track every column is full height.
public struct SparklineBars: Shape, Equatable {
    public var fractions: [Double]
    public var isTrack: Bool
    public var slot: BarSlot

    public init(fractions: [Double], isTrack: Bool = false, slot: BarSlot = .fill) {
        self.fractions = fractions
        self.isTrack = isTrack
        self.slot = slot
    }

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        guard rect.width > 0, rect.height > 0 else { return path }
        let columns: Int
        switch slot {
        case .fill: columns = fractions.count
        case .fixed(let width): columns = max(1, Int((rect.width / max(width, 1)).rounded()))
        }
        guard columns > 0 else { return path }
        let slotWidth = rect.width / CGFloat(columns)
        let gap = min(max(slotWidth * 0.26, 1), 3)
        let barWidth = max(1, slotWidth - gap)
        let radius = min(barWidth / 2, 1.5)
        let shown = fractions.suffix(columns)
        let firstColumn = columns - shown.count
        func addBar(column: Int, height: CGFloat) {
            let bar = CGRect(x: rect.minX + CGFloat(column) * slotWidth + gap / 2, y: rect.maxY - height, width: barWidth, height: height)
            path.addRoundedRect(in: bar, cornerSize: CGSize(width: radius, height: radius), style: .continuous)
        }
        if isTrack {
            for column in 0..<columns { addBar(column: column, height: rect.height) }
        } else {
            for (offset, fraction) in shown.enumerated() {
                addBar(column: firstColumn + offset, height: max(radius * 2, rect.height * fraction))
            }
        }
        return path
    }
}

/// A bar chart of recent values: accent columns over a faint full-height track for each.
/// Values are reduced to what a pixel can show, so an unchanged-looking chart is not redrawn.
public struct BarSparkline: View, Equatable {
    private let fractions: [Double]
    private let tint: Color
    private let slot: BarSlot
    private let summary: String?

    /// - Parameters:
    ///   - maxValue: the value a full-height bar stands for; nil scales to the largest value.
    ///   - summary: what VoiceOver reads for the chart, such as "CPU, 12 percent, last 4 minutes"; nil hides it.
    public init<Values: Collection>(_ values: Values, tint: Color = Palette.accent, maxValue: Double? = nil, slot: BarSlot = .fixed(5), summary: String? = nil) where Values.Element == Double {
        let top = max(maxValue ?? (values.max() ?? 1), 0.000_001)
        self.fractions = values.map { quantizedFraction($0 / top, steps: 256) }
        self.tint = tint
        self.slot = slot
        self.summary = summary
    }

    public var body: some View {
        ZStack {
            SparklineBars(fractions: fractions, isTrack: true, slot: slot)
                .fill(Palette.track)
            SparklineBars(fractions: fractions, slot: slot)
                .fill(tint)
        }
        .chartAccessibility(summary)
    }
}

/// Two series stacked in each column, as user and system CPU are, over a faint track.
public struct StackedBarSparkline: View, Equatable {
    private let lower: [Double]
    private let total: [Double]
    private let slot: BarSlot
    private let summary: String?

    /// - Parameter maxValue: the value a full-height bar stands for.
    public init(lower: [Double], upper: [Double], maxValue: Double, slot: BarSlot = .fixed(5), summary: String? = nil) {
        let top = max(maxValue, 0.000_001)
        self.lower = lower.map { quantizedFraction($0 / top, steps: 256) }
        self.total = zip(lower, upper).map { quantizedFraction(($0 + $1) / top, steps: 256) }
        self.slot = slot
        self.summary = summary
    }

    public var body: some View {
        ZStack {
            SparklineBars(fractions: total, isTrack: true, slot: slot)
                .fill(Palette.track)
            SparklineBars(fractions: total, slot: slot)
                .fill(Palette.accentSecond)
            SparklineBars(fractions: lower, slot: slot)
                .fill(Palette.accent)
        }
        .chartAccessibility(summary)
    }
}

/// Three faint horizontal lines at the top, the middle thirds and the bottom of a chart.
private struct ChartGridLines: Shape {
    var inset: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for index in 0..<4 {
            let y = rect.minY + inset + (rect.height - inset * 2) * CGFloat(index) / 3
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        return path
    }
}

/// A line through evenly spaced fractions of the height, optionally closed along the bottom for a fill.
private struct ChartLine: Shape, Equatable {
    var fractions: [Double]
    var inset: CGFloat
    var closed: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard fractions.count > 1 else { return path }
        let step = rect.width / CGFloat(fractions.count - 1)
        func point(_ index: Int) -> CGPoint {
            CGPoint(x: rect.minX + CGFloat(index) * step, y: rect.minY + inset + (rect.height - inset * 2) * (1 - fractions[index]))
        }
        if closed {
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            for index in fractions.indices { path.addLine(to: point(index)) }
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.closeSubpath()
        } else {
            path.move(to: point(0))
            for index in fractions.indices.dropFirst() { path.addLine(to: point(index)) }
        }
        return path
    }
}

/// A line with a gradient fill underneath, optionally over three faint grid lines.
public struct AreaChart: View, Equatable {
    private let fractions: [Double]
    private let tint: Color
    private let showsGrid: Bool
    private let lineWidth: CGFloat
    private let summary: String?

    /// - Parameters:
    ///   - maxValue: the value at the top edge; nil scales to 115% of the largest value.
    ///   - minValue: the value at the bottom edge.
    ///   - summary: what VoiceOver reads for the chart, such as "CPU, 12 percent, last 20 minutes"; nil hides it.
    public init(_ values: [Double], tint: Color, maxValue: Double? = nil, minValue: Double = 0, showsGrid: Bool = true, lineWidth: CGFloat = 2, summary: String? = nil) {
        let top = max(maxValue ?? ((values.max() ?? 1) * 1.15), minValue + 0.000_001)
        self.fractions = values.map { quantizedFraction(($0 - minValue) / (top - minValue)) }
        self.tint = tint
        self.showsGrid = showsGrid
        self.lineWidth = lineWidth
        self.summary = summary
    }

    public var body: some View {
        ZStack {
            if showsGrid {
                ChartGridLines(inset: lineWidth / 2)
                    .stroke(Palette.line, lineWidth: 1)
            }
            if fractions.count > 1 {
                ChartLine(fractions: fractions, inset: lineWidth / 2, closed: true)
                    .fill(LinearGradient(colors: [tint.opacity(0.32), tint.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                ChartLine(fractions: fractions, inset: lineWidth / 2, closed: false)
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            }
        }
        .chartAccessibility(summary)
    }
}

/// One arc of a ring, from `start` to `end` (fractions of a turn clockwise from twelve o'clock),
/// shortened by `gap` points so neighbouring arcs stay apart.
private struct RingSegment: Shape {
    var start: Double
    var end: Double
    var lineWidth: CGFloat
    var gap: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let radius = min(rect.width, rect.height) / 2 - lineWidth / 2
        guard radius > 0 else { return path }
        let gapTurns = Double(gap / (2 * .pi * radius))
        let from = start + gapTurns / 2
        let to = end - gapTurns / 2
        guard to > from else { return path }
        path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: radius, startAngle: .degrees(from * 360 - 90), endAngle: .degrees(to * 360 - 90), clockwise: false)
        return path
    }
}

/// A ring chart with a caption in the middle, as in "Memory by Type".
public struct DonutChart: View, Equatable {
    public struct Slice: Identifiable, Equatable {
        public var id: Int
        public var value: Double
        public var color: Color
        /// What VoiceOver calls this slice.
        public var label: String?

        public init(id: Int, value: Double, color: Color, label: String? = nil) {
            self.id = id
            self.value = value
            self.color = color
            self.label = label
        }
    }

    private struct Arc: Identifiable, Equatable {
        var id: Int
        var start: Double
        var end: Double
        var color: Color
    }

    private let arcs: [Arc]
    private let title: String
    private let subtitle: String
    private let lineWidth: CGFloat
    private let slicesDescription: String
    private let accessibilityTitle: String?
    private let descriptor: DonutChartDescriptor

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiatesWithoutColor

    /// - Parameter accessibilityTitle: what the chart shows, such as "Memory by App"; VoiceOver reads the centre caption after it.
    public init(_ slices: [Slice], title: String, subtitle: String, lineWidth: CGFloat = 14, accessibilityTitle: String? = nil) {
        let visible = slices.filter { $0.value > 0 && $0.value.isFinite }
        let total = visible.reduce(0) { $0 + $1.value }
        var arcs: [Arc] = []
        var start = 0.0
        for slice in visible {
            let end = quantizedFraction(start + slice.value / total)
            arcs.append(Arc(id: slice.id, start: start, end: end, color: slice.color))
            start = end
        }
        self.arcs = arcs
        self.title = title
        self.subtitle = subtitle
        self.lineWidth = lineWidth
        self.slicesDescription = visible.compactMap { slice in
            slice.label.map { "\($0) \(Int((slice.value / total * 100).rounded())) percent" }
        }
        .joined(separator: ", ")
        self.accessibilityTitle = accessibilityTitle
        self.descriptor = DonutChartDescriptor(
            title: accessibilityTitle ?? "\(title) \(subtitle)",
            summary: "\(title) \(subtitle)",
            slices: visible.compactMap { slice in slice.label.map { ($0, slice.value / total * 100) } }
        )
    }

    public static func == (lhs: DonutChart, rhs: DonutChart) -> Bool {
        lhs.arcs == rhs.arcs && lhs.title == rhs.title && lhs.subtitle == rhs.subtitle && lhs.lineWidth == rhs.lineWidth
            && lhs.slicesDescription == rhs.slicesDescription && lhs.accessibilityTitle == rhs.accessibilityTitle
    }

    public var body: some View {
        // Wider gaps with Differentiate Without Colour, so neighbouring slices in similar tints stay apart.
        let gap: CGFloat = arcs.count > 1 ? (differentiatesWithoutColor ? 3.5 : 1.3) : 0
        ZStack {
            if arcs.isEmpty {
                Circle()
                    .inset(by: lineWidth / 2)
                    .stroke(Palette.cardHighlight, lineWidth: lineWidth)
            }
            ForEach(arcs) { arc in
                RingSegment(start: arc.start, end: arc.end, lineWidth: lineWidth, gap: gap)
                    .stroke(arc.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
            }
            VStack(spacing: 1) {
                Text(title)
                    .font(Typography.donutTitle)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(subtitle)
                    .font(Typography.donutSubtitle)
                    .foregroundStyle(Palette.ink2)
                    .lineLimit(1)
            }
            .padding(lineWidth + 3)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityTitle ?? "\(title) \(subtitle)")
        .accessibilityValue(accessibilityTitle == nil ? slicesDescription : "\(title) \(subtitle). \(slicesDescription)")
        .accessibilityAddTraits(.isImage)
        .accessibilityChartDescriptor(descriptor)
    }
}

/// Each slice's share of a donut, as VoiceOver's chart description sees it.
struct DonutChartDescriptor: AXChartDescriptorRepresentable {
    var title: String
    var summary: String
    var slices: [(label: String, percent: Double)]

    func makeChartDescriptor() -> AXChartDescriptor {
        let xAxis = AXCategoricalDataAxisDescriptor(title: "Category", categoryOrder: slices.map(\.label))
        let yAxis = AXNumericDataAxisDescriptor(title: "Share", range: 0...100, gridlinePositions: []) { "\(Int($0.rounded())) percent" }
        let points = slices.map { AXDataPoint(x: $0.label, y: $0.percent) }
        let series = AXDataSeriesDescriptor(name: "Share", isContinuous: false, dataPoints: points)
        return AXChartDescriptor(title: title, summary: summary, xAxis: xAxis, yAxis: yAxis, series: [series])
    }
}
