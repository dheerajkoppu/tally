import SwiftUI
import TallyCore

/// A subsystem card: header, a big figure with its detail line and chips beside a gauge, three stats and a bar chart
/// along the bottom. Equatable, so a sample that leaves every shown value the same skips the card entirely.
/// VoiceOver reads the whole card as one button with a spoken summary and the bar chart as its chart.
struct OverviewMetricCard: View, Equatable {
    let content: OverviewMetricContent

    /// Room for the figure, its detail line and a row of chips, so stats line up across a row of cards.
    private static let summaryHeight: CGFloat = 76

    var body: some View {
        Button {
            AppRouter.shared.tab = content.tab
        } label: {
            Card {
                VStack(alignment: .leading, spacing: 0) {
                    CardHeader(content.title, symbol: content.symbol, showsChevron: true)
                    HStack(alignment: .top, spacing: 10) {
                        summary
                        Spacer(minLength: 0)
                        OverviewVisualView(visual: content.visual)
                            .padding(.top, 3)
                    }
                    .frame(height: Self.summaryHeight, alignment: .top)
                    .padding(.top, 9)
                    // Equal columns: a stack gives a long label more room and shrinks the other figures to make up.
                    OverviewCardGrid(spacing: 12, minimumColumnWidth: 0, maximumColumns: max(content.stats.count, 1)) {
                        ForEach(content.stats) { stat in
                            OverviewStatColumn(label: stat.label, value: stat.value, dot: stat.dot)
                                .frame(maxHeight: .infinity, alignment: .bottomLeading)
                        }
                    }
                    .padding(.top, 8)
                    Spacer(minLength: 12)
                    sparkline
                        .frame(height: Metrics.sparklineHeight)
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .buttonStyle(OverviewCardButtonStyle(cornerRadius: Metrics.cardRadius))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(content.title)
        .accessibilityValue(content.spokenSummary)
        .accessibilityHint("Opens the \(content.tab.title) tab")
        .accessibilityAddTraits([.isButton, .updatesFrequently])
        .accessibilityAction { AppRouter.shared.tab = content.tab }
        .accessibilityChartDescriptor(content.chart)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let figure = content.figure {
                BigFigure(figure, size: Typography.cardFigureSize)
            } else {
                Text(OverviewContent.placeholder)
                    .font(Typography.figure(Typography.cardFigureSize))
                    .foregroundStyle(Palette.ink3)
            }
            Text(content.detail)
                .font(Typography.cardDetail)
                .foregroundStyle(Palette.ink2)
                .lineLimit(1)
            if !content.chips.isEmpty {
                // A narrow card keeps its first chip whole rather than squeezing two.
                ViewThatFits(in: .horizontal) {
                    chipRow(content.chips)
                    chipRow(Array(content.chips.prefix(1)))
                }
                .padding(.top, 7)
            }
        }
        .layoutPriority(1)
    }

    private func chipRow(_ chips: [OverviewChipContent]) -> some View {
        HStack(spacing: 5) {
            // By position: a chip's text changes with every sample.
            ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                Chip(chip.label, value: chip.value, dot: chip.dot)
            }
        }
    }

    @ViewBuilder
    private var sparkline: some View {
        if let stackedBars = content.stackedBars {
            StackedBarSparkline(lower: content.bars, upper: stackedBars, maxValue: 1)
        } else {
            BarSparkline(content.bars, maxValue: 1)
        }
    }
}

/// The gauge on the right of a card.
struct OverviewVisualView: View, Equatable {
    let visual: OverviewVisual

    var body: some View {
        switch visual {
        case .none:
            EmptyView()
        case .cores(let fractions):
            BarSparkline(fractions, maxValue: 1, slot: .fill)
                .frame(width: min(96, max(40, CGFloat(fractions.count) * 7)), height: 44)
        case .ring(let segments):
            RingGauge(segments)
                .frame(width: 52, height: 52)
        case .battery(let level, let isCharging, let isLow):
            BatteryGlyph(level: level, isCharging: isCharging, tint: isLow ? Palette.red : Palette.accent)
                .frame(width: 30, height: 54)
                .padding(.trailing, 6)
        case .thermometer(let level, let isHot):
            ThermometerGlyph(level: level, tint: isHot ? Palette.red : Palette.accent)
                .frame(width: 38, height: 54)
        case .figure(let symbol, let figure, let label):
            VStack(alignment: .trailing, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: symbol)
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Palette.accentSecond)
                    BigFigure(figure, size: 17)
                }
                Text(label.lowercased())
                    .font(Typography.cardDetail)
                    .foregroundStyle(Palette.ink2)
            }
            .fixedSize()
            .padding(.top, 9)
        }
    }
}

/// "User" over "19%".
private struct OverviewStatColumn: View, Equatable {
    let label: String
    let value: String
    let dot: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                if let dot {
                    Circle().fill(dot).frame(width: 6, height: 6)
                }
                Text(label)
                    .font(Typography.statLabel)
                    .foregroundStyle(Palette.ink2)
            }
            Text(value)
                .font(Typography.statValue)
                .foregroundStyle(Palette.ink)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityReading(label, value: value)
    }
}

/// Lets a whole card act as a button, with a faint wash on hover and press.
struct OverviewCardButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        OverviewCardButtonBody(configuration: configuration, cornerRadius: cornerRadius)
    }
}

private struct OverviewCardButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let cornerRadius: CGFloat
    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        configuration.label
            .overlay {
                if configuration.isPressed || isHovered {
                    shape.fill(Palette.ink.opacity(configuration.isPressed ? 0.06 : 0.025))
                        .allowsHitTesting(false)
                }
            }
            .contentShape(shape)
            .onHover { isHovered = $0 }
    }
}
