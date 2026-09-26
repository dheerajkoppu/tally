import SwiftUI
import TallyCore

/// Temperatures, fans and peripheral batteries as small tiles, two per card column. Fan tiles open Fan Control.
struct OverviewSensorTiles: View, Equatable {
    let tiles: [OverviewSensorContent]

    var body: some View {
        OverviewTileGrid(spacing: Metrics.gridSpacing, minimumTileWidth: 110, maximumColumns: 6) {
            ForEach(tiles) { tile in
                if tile.opensFanControl {
                    Button {
                        AppRouter.shared.isFanControlPresented = true
                    } label: {
                        OverviewSensorTile(tile, showsChevron: true)
                    }
                    .buttonStyle(OverviewCardButtonStyle(cornerRadius: Metrics.tileRadius))
                    .help("Adjust fan speeds")
                    .accessibilityLabel(tile.accessibilityLabel)
                    .accessibilityValue("\(tile.value) rpm")
                    .accessibilityHint("Opens Fan Control")
                } else {
                    OverviewSensorTile(tile, showsChevron: false)
                        .help(tile.caption)
                        .accessibilityReading(tile.accessibilityLabel, value: tile.value)
                }
            }
        }
    }
}

private struct OverviewSensorTile: View {
    private let content: OverviewSensorContent
    private let showsChevron: Bool

    init(_ content: OverviewSensorContent, showsChevron: Bool) {
        self.content = content
        self.showsChevron = showsChevron
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                IconBadge(content.symbol, tint: content.tint)
                Spacer(minLength: 0)
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(Typography.chevron)
                        .foregroundStyle(Palette.ink3)
                        .padding(.top, 7)
                        .padding(.trailing, 1.5)
                        .accessibilityHidden(true)
                }
            }
            Text(content.value)
                .font(Typography.figure(Typography.tileFigureSize))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.top, 14)
            Text(content.caption)
                .font(Typography.caption)
                .foregroundStyle(Palette.ink2)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.top, 2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: Metrics.tileRadius, style: .continuous))
        .surfaceOutline(RoundedRectangle(cornerRadius: Metrics.tileRadius, style: .continuous))
    }
}

/// Equal-width tiles. Up to six share a row, two per card column above; more are spread over balanced rows.
private struct OverviewTileGrid: Layout {
    var spacing: CGFloat
    var minimumTileWidth: CGFloat
    var maximumColumns: Int

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? minimumTileWidth * CGFloat(maximumColumns) + spacing * CGFloat(maximumColumns - 1)
        let rows = rowHeights(width: width, subviews: subviews)
        return CGSize(width: width, height: rows.reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let columns = columnCount(for: bounds.width, tiles: subviews.count)
        let tileWidth = self.tileWidth(for: bounds.width, columns: columns)
        let rows = rowHeights(width: bounds.width, subviews: subviews)
        var y = bounds.minY
        for (row, rowHeight) in rows.enumerated() {
            for column in 0..<columns {
                let index = row * columns + column
                guard index < subviews.count else { break }
                let x = bounds.minX + CGFloat(column) * (tileWidth + spacing)
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: tileWidth, height: rowHeight))
            }
            y += rowHeight + spacing
        }
    }

    private func columnCount(for width: CGFloat, tiles: Int) -> Int {
        let fitting = max(1, Int((width + spacing) / (minimumTileWidth + spacing)))
        let slots = min(maximumColumns, fitting)
        guard tiles > slots else { return slots }
        let rows = Int((Double(tiles) / Double(fitting)).rounded(.up))
        return Int((Double(tiles) / Double(rows)).rounded(.up))
    }

    private func tileWidth(for width: CGFloat, columns: Int) -> CGFloat {
        max(0, (width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
    }

    private func rowHeights(width: CGFloat, subviews: Subviews) -> [CGFloat] {
        let columns = columnCount(for: width, tiles: subviews.count)
        let proposal = ProposedViewSize(width: tileWidth(for: width, columns: columns), height: nil)
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
