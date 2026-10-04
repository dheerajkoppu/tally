import SwiftUI
import TallyCore

/// "Memory by Type", "Memory by App" and "Power by App": a donut and its legend. Clicking the card opens its tab;
/// clicking an app row opens that app in the inspector. VoiceOver sees a group: the header opens the tab, the donut is
/// a chart, and each legend row reads its label and value.
struct OverviewBreakdownCard: View, Equatable {
    let content: OverviewBreakdownContent

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiatesWithoutColor

    static func == (lhs: OverviewBreakdownCard, rhs: OverviewBreakdownCard) -> Bool {
        lhs.content == rhs.content
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                CardHeader(content.title, symbol: content.symbol)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Opens the \(content.tab.title) tab")
                    .accessibilityAction { AppRouter.shared.tab = content.tab }
                OverviewDonutLegendLayout(sideBySideWidth: Self.sideBySideWidth) {
                    donut
                    legend
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .contentShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
        .onTapGesture { AppRouter.shared.tab = content.tab }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(content.title)
        .accessibilityAction(named: "Open \(content.tab.title)") { AppRouter.shared.tab = content.tab }
    }

    /// Below this width the legend would squeeze app names too far, so the donut moves above it.
    private static let sideBySideWidth: CGFloat = 290
    private static let donutDiameter: CGFloat = 86

    private var donut: some View {
        DonutChart(
            content.entries.enumerated().map { index, entry in
                DonutChart.Slice(id: index, value: entry.share, color: entry.color, label: entry.label)
            },
            title: content.centerTitle,
            subtitle: content.centerSubtitle,
            lineWidth: 13,
            accessibilityTitle: content.title
        )
        .frame(width: Self.donutDiameter, height: Self.donutDiameter)
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 8) {
            if content.entries.isEmpty {
                ForEach(0..<OverviewContent.appSliceCount + 1, id: \.self) { index in
                    OverviewLegendPlaceholderRow(labelWidth: [78, 52, 66, 44, 40][index % 5])
                }
            } else {
                // By position, so a new top app updates a row in place instead of replacing it.
                ForEach(Array(content.entries.enumerated()), id: \.offset) { _, entry in
                    legendRow(entry)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func legendRow(_ entry: OverviewBreakdownEntry) -> some View {
        let value = legendValue(entry)
        if let appID = entry.appID {
            Button {
                AppRouter.shared.open(content.tab, inspecting: appID)
            } label: {
                LegendRow(color: entry.color, label: entry.label, value: value) {
                    AppIconView(appID: appID, bundlePath: entry.bundlePath, size: 15)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show \(entry.label)")
            .accessibilityHint("Shows the processes of \(entry.label)")
        } else {
            LegendRow(color: entry.color, label: entry.label, value: value)
        }
    }

    /// With Differentiate Without Colour, each row also gives its share, so rows match slices by size, not tint.
    private func legendValue(_ entry: OverviewBreakdownEntry) -> String {
        guard differentiatesWithoutColor, entry.valueText != OverviewContent.placeholder else { return entry.valueText }
        return "\(entry.valueText) · \(Int((entry.share * 100).rounded()))%"
    }
}

/// Puts the donut beside its legend, or above it when the card is narrower than `sideBySideWidth`.
/// A plain layout rather than `ViewThatFits`, which sized both arrangements on every update.
private struct OverviewDonutLegendLayout: Layout {
    var sideBySideWidth: CGFloat
    var donutInset: CGFloat = 3
    var sideSpacing: CGFloat = 23
    var stackedSpacing: CGFloat = 16

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let width = proposal.width ?? sideBySideWidth
        let donut = subviews[0].sizeThatFits(.unspecified)
        if width >= sideBySideWidth {
            let legend = subviews[1].sizeThatFits(ProposedViewSize(width: legendWidth(in: width, donut: donut), height: nil))
            return CGSize(width: width, height: max(donut.height, legend.height))
        }
        let legend = subviews[1].sizeThatFits(ProposedViewSize(width: width, height: nil))
        return CGSize(width: width, height: donut.height + stackedSpacing + legend.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let donut = subviews[0].sizeThatFits(.unspecified)
        if bounds.width >= sideBySideWidth {
            let legendProposal = ProposedViewSize(width: legendWidth(in: bounds.width, donut: donut), height: nil)
            let legend = subviews[1].sizeThatFits(legendProposal)
            subviews[0].place(at: CGPoint(x: bounds.minX + donutInset, y: bounds.midY - donut.height / 2), anchor: .topLeading, proposal: ProposedViewSize(donut))
            subviews[1].place(at: CGPoint(x: bounds.minX + donutInset + donut.width + sideSpacing, y: bounds.midY - legend.height / 2), anchor: .topLeading, proposal: legendProposal)
        } else {
            subviews[0].place(at: CGPoint(x: bounds.midX - donut.width / 2, y: bounds.minY), anchor: .topLeading, proposal: ProposedViewSize(donut))
            subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + donut.height + stackedSpacing), anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: nil))
        }
    }

    private func legendWidth(in width: CGFloat, donut: CGSize) -> CGFloat {
        max(0, width - donutInset - donut.width - sideSpacing)
    }
}

/// A legend row waiting for its first sample: a grey dot, a short bar and a dash.
private struct OverviewLegendPlaceholderRow: View {
    let labelWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Circle().fill(Palette.memoryFree).frame(width: 6, height: 6)
            Capsule()
                .fill(Palette.cardHighlight)
                .frame(width: labelWidth, height: 7)
                .padding(.leading, 6)
            Spacer(minLength: 8)
            Text(OverviewContent.placeholder)
                .font(Typography.legend)
                .foregroundStyle(Palette.ink2)
        }
        .frame(height: LegendRow<EmptyView>.height)
        .accessibilityHidden(true)
    }
}
