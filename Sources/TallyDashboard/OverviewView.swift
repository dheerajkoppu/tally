import SwiftUI
import TallyCore

/// The Overview tab: a card per subsystem.
/// Each card is Equatable and built from values already rounded for display, so a sample only redraws what changed.
public struct OverviewView: View {
    @ObservedObject private var store = TallyStore.shared
    @ObservedObject private var settings = AppSettings.shared

    public init() {}

    public var body: some View {
        let content = OverviewContent(store: store, temperatureUnit: settings.temperatureUnit)
        VStack(alignment: .leading, spacing: Metrics.gridSpacing) {
            if !content.alerts.isEmpty {
                OverviewAlertsCard(alerts: content.alerts).equatable()
            }
            OverviewCardGrid(spacing: Metrics.gridSpacing, minimumColumnWidth: 250, maximumColumns: 3) {
                OverviewMetricCard(content: content.cpu).equatable()
                OverviewMetricCard(content: content.memory).equatable()
                OverviewMetricCard(content: content.gpu).equatable()
                OverviewMetricCard(content: content.disk).equatable()
                OverviewMetricCard(content: content.network).equatable()
                OverviewMetricCard(content: content.battery).equatable()
                OverviewBreakdownCard(content: content.memoryByType).equatable()
                OverviewBreakdownCard(content: content.memoryByApp).equatable()
                OverviewBreakdownCard(content: content.powerByApp).equatable()
            }
            if !content.sensors.isEmpty {
                OverviewSensorTiles(tiles: content.sensors).equatable()
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .announcesMemoryPressure(store.snapshot.memory.pressure)
    }
}

/// Lays cards out in equal columns, as many as fit (up to `maximumColumns`), with every card in a row as tall as the tallest.
struct OverviewCardGrid: Layout {
    var spacing: CGFloat
    var minimumColumnWidth: CGFloat
    var maximumColumns: Int

    /// No alignment guides of its own. The default implementation places every card on each update to look for one.
    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? {
        nil
    }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? {
        nil
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = resolvedWidth(proposal)
        let rows = rowHeights(width: width, subviews: subviews)
        return CGSize(width: width, height: rows.reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let columns = columnCount(for: bounds.width)
        let columnWidth = self.columnWidth(for: bounds.width, columns: columns)
        var y = bounds.minY
        for (row, rowHeight) in rowHeights(width: bounds.width, subviews: subviews).enumerated() {
            for column in 0..<columns {
                let index = row * columns + column
                guard index < subviews.count else { break }
                let x = bounds.minX + CGFloat(column) * (columnWidth + spacing)
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: columnWidth, height: rowHeight))
            }
            y += rowHeight + spacing
        }
    }

    private func resolvedWidth(_ proposal: ProposedViewSize) -> CGFloat {
        guard let width = proposal.width, width.isFinite else {
            return minimumColumnWidth * CGFloat(maximumColumns) + spacing * CGFloat(maximumColumns - 1)
        }
        return width
    }

    private func columnCount(for width: CGFloat) -> Int {
        var count = max(maximumColumns, 1)
        while count > 1 && columnWidth(for: width, columns: count) < minimumColumnWidth {
            count -= 1
        }
        return count
    }

    private func columnWidth(for width: CGFloat, columns: Int) -> CGFloat {
        max(0, (width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
    }

    private func rowHeights(width: CGFloat, subviews: Subviews) -> [CGFloat] {
        let columns = columnCount(for: width)
        let proposal = ProposedViewSize(width: columnWidth(for: width, columns: columns), height: nil)
        var heights: [CGFloat] = []
        var start = 0
        while start < subviews.count {
            let end = min(start + columns, subviews.count)
            heights.append(subviews[start..<end].map { $0.sizeThatFits(proposal).height }.max() ?? 0)
            start = end
        }
        return heights
    }
}
