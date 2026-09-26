import SwiftUI
import TallyCore

/// A subsystem card: header, caption, big figure, three stats and a bar sparkline pinned to the bottom.
/// Equatable, so a sample that leaves every shown value the same skips the card entirely.
/// VoiceOver reads the whole card as one button with a spoken summary and the sparkline as its chart.
struct OverviewMetricCard: View, Equatable {
    let content: OverviewMetricContent

    var body: some View {
        Button {
            AppRouter.shared.tab = content.tab
        } label: {
            Card {
                VStack(alignment: .leading, spacing: 0) {
                    CardHeader(content.title, symbol: content.symbol, tint: content.tint, showsChevron: true)
                    Text(content.caption)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.ink2)
                        .lineLimit(1)
                        .padding(.top, 12)
                    HStack(alignment: .center, spacing: 8) {
                        if let figure = content.figure {
                            BigFigure(figure, size: Typography.cardFigureSize)
                        } else {
                            Text(OverviewContent.placeholder)
                                .font(Typography.figure(Typography.cardFigureSize))
                                .foregroundStyle(Palette.ink3)
                        }
                        Spacer(minLength: 0)
                        if let pill = content.pill {
                            OverviewPill(pill)
                                .padding(.top, 5)
                        }
                    }
                    // Equal columns: a stack gives a long label more room and shrinks the other figures to make up.
                    // Bottom-aligned, so figures stay on one line when a long label is set smaller.
                    OverviewCardGrid(spacing: 12, minimumColumnWidth: 0, maximumColumns: content.stats.count) {
                        ForEach(content.stats) { stat in
                            OverviewStatColumn(label: stat.label, value: stat.value, dot: stat.dot)
                                .frame(maxHeight: .infinity, alignment: .bottomLeading)
                        }
                    }
                    .padding(.top, 8)
                    Spacer(minLength: 12)
                    BarSparkline(content.bars, tint: content.tint, maxValue: 1)
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
}

/// "User" over "19%", set as tight as the Overview in the Tally launch video.
private struct OverviewStatColumn: View, Equatable {
    let label: String
    let value: String
    let dot: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
