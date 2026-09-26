import SwiftUI
import TallyCore

/// The shape and colors of the app icon (Resources/AppIcon.icon), shared by `TallyLogoMark` and scripts/make-icon.swift.
/// Positions and sizes are in unit coordinates of the icon body (0,0 top left).
enum LogoGeometry {
    struct Tile {
        let center: CGPoint
        let side: CGFloat
        let degrees: Double
        let top: Color
        let bottom: Color
    }

    /// Corner radius as a share of the side, drawn with continuous corners, like the macOS 26 icon mask.
    static let cornerRatio: CGFloat = 0.255
    static let backgroundTop = Color(.displayP3, red: 0.27, green: 0.275, blue: 0.30)
    static let backgroundBottom = Color(.displayP3, red: 0.075, green: 0.08, blue: 0.09)

    /// The pile of app tiles, back to front.
    static let tiles = [
        Tile(center: CGPoint(x: 0.3877, y: 0.4297), side: 0.4756, degrees: -16,
             top: Color(.displayP3, red: 1.00, green: 0.46, blue: 0.57), bottom: Color(.displayP3, red: 0.85, green: 0.15, blue: 0.33)),
        Tile(center: CGPoint(x: 0.4482, y: 0.4902), side: 0.4756, degrees: -8,
             top: Color(.displayP3, red: 1.00, green: 0.80, blue: 0.30), bottom: Color(.displayP3, red: 0.96, green: 0.54, blue: 0.04)),
        Tile(center: CGPoint(x: 0.5254, y: 0.5674), side: 0.4980, degrees: 0,
             top: Color(.displayP3, red: 0.28, green: 0.85, blue: 0.53), bottom: Color(.displayP3, red: 0.02, green: 0.55, blue: 0.28)),
    ]
    static let tileCornerRatio: CGFloat = 0.25
    /// The 2×2 grid of app cells on the front tile, as shares of the tile side.
    static let cellRatio: CGFloat = 0.21
    static let cellGapRatio: CGFloat = 0.068

    static let badgeCenter = CGPoint(x: 0.7588, y: 0.3340)
    static let badgeRadius: CGFloat = 0.1182
    static let badgeCount = "5"
    static let badgeTop = Color(.displayP3, red: 1.00, green: 0.45, blue: 0.39)
    static let badgeBottom = Color(.displayP3, red: 0.85, green: 0.12, blue: 0.07)
}

/// The menu bar glyph: three offset rounded squares, the front one cut with a 2×2 grid of app cells.
/// Laid out on StatusItemArtwork's 14 pt grid, scaled to fill its frame. Fill it.
public struct TallyStackShape: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / 14
        func square(_ offset: CGFloat, outset: CGFloat = 0) -> Path {
            let frame = CGRect(
                x: rect.minX + (offset - outset) * unit,
                y: rect.minY + (offset - outset) * unit,
                width: (10 + outset * 2) * unit,
                height: (10 + outset * 2) * unit
            )
            return Path(roundedRect: frame, cornerRadius: (2.5 + outset) * unit, style: .circular)
        }
        var cells = Path()
        for row in 0..<2 {
            for column in 0..<2 {
                let origin = CGPoint(x: rect.minX + (6 + CGFloat(column) * 4) * unit, y: rect.minY + (6 + CGFloat(row) * 4) * unit)
                cells.addRoundedRect(in: CGRect(origin: origin, size: CGSize(width: 2 * unit, height: 2 * unit)), cornerSize: CGSize(width: 0.5 * unit, height: 0.5 * unit), style: .circular)
            }
        }
        // Each square gives up a 1 pt gap around the one in front of it.
        return square(0).subtracting(square(2, outset: 1))
            .union(square(2).subtracting(square(4, outset: 1)))
            .union(square(4).subtracting(cells))
    }
}

/// The Tally app icon: a graphite squircle with a pile of app tiles and a count badge, drawn in one pass.
public struct TallyLogoMark: View {
    private let size: CGFloat

    public init(size: CGFloat = 64) {
        self.size = size
    }

    public var body: some View {
        Canvas { context, canvasSize in
            Self.draw(in: &context, side: min(canvasSize.width, canvasSize.height))
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Tally")
    }

    static func draw(in context: inout GraphicsContext, side: CGFloat) {
        let body = RoundedRectangle(cornerRadius: side * LogoGeometry.cornerRatio, style: .continuous)
            .path(in: CGRect(x: 0, y: 0, width: side, height: side))
        context.fill(body, with: .linearGradient(
            Gradient(colors: [LogoGeometry.backgroundTop, LogoGeometry.backgroundBottom]),
            startPoint: .zero,
            endPoint: CGPoint(x: 0, y: side)
        ))
        // Keeps the graphite body apart from dark window backgrounds.
        context.stroke(body, with: .linearGradient(
            Gradient(colors: [.white.opacity(0.28), .white.opacity(0.06)]),
            startPoint: .zero,
            endPoint: CGPoint(x: 0, y: side)
        ), lineWidth: max(side * 0.012, 0.5))

        for (index, tile) in LogoGeometry.tiles.enumerated() {
            var tileContext = context
            tileContext.translateBy(x: tile.center.x * side, y: tile.center.y * side)
            tileContext.rotate(by: .degrees(tile.degrees))
            let tileSide = tile.side * side
            let frame = CGRect(x: -tileSide / 2, y: -tileSide / 2, width: tileSide, height: tileSide)
            let shape = RoundedRectangle(cornerRadius: tileSide * LogoGeometry.tileCornerRatio, style: .continuous).path(in: frame)
            // An offset shade in the tile's own colour stands in for the icon's layer-colour shadow.
            tileContext.fill(shape.offsetBy(dx: 0, dy: tileSide * 0.04), with: .color(.black.opacity(0.35)))
            tileContext.fill(shape.offsetBy(dx: 0, dy: tileSide * 0.02), with: .color(tile.bottom.opacity(0.6)))
            tileContext.fill(shape, with: .linearGradient(
                Gradient(colors: [tile.top, tile.bottom]),
                startPoint: CGPoint(x: frame.minX + tileSide * 0.2, y: frame.minY),
                endPoint: CGPoint(x: frame.minX + tileSide * 0.55, y: frame.maxY)
            ))
            tileContext.stroke(shape, with: .linearGradient(
                Gradient(colors: [.white.opacity(0.6), .white.opacity(0)]),
                startPoint: CGPoint(x: 0, y: frame.minY),
                endPoint: CGPoint(x: 0, y: frame.midY)
            ), lineWidth: max(tileSide * 0.012, 0.5))

            if index == LogoGeometry.tiles.count - 1 {
                let cell = tileSide * LogoGeometry.cellRatio
                let pitch = cell + tileSide * LogoGeometry.cellGapRatio
                for row in 0..<2 {
                    for column in 0..<2 {
                        let cellFrame = CGRect(
                            x: (CGFloat(column) - 0.5) * pitch - cell / 2,
                            y: (CGFloat(row) - 0.5) * pitch - cell / 2,
                            width: cell,
                            height: cell
                        )
                        tileContext.fill(RoundedRectangle(cornerRadius: cell * 0.28, style: .continuous).path(in: cellFrame), with: .color(.white))
                    }
                }
            }
        }

        let center = CGPoint(x: LogoGeometry.badgeCenter.x * side, y: LogoGeometry.badgeCenter.y * side)
        let radius = LogoGeometry.badgeRadius * side
        let badge = Circle().path(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        context.fill(badge.offsetBy(dx: 0, dy: radius * 0.14), with: .color(.black.opacity(0.3)))
        context.fill(badge, with: .linearGradient(
            Gradient(colors: [LogoGeometry.badgeTop, LogoGeometry.badgeBottom]),
            startPoint: CGPoint(x: 0, y: center.y - radius),
            endPoint: CGPoint(x: 0, y: center.y + radius)
        ))
        context.draw(
            Text(LogoGeometry.badgeCount)
                .font(.system(size: radius * 1.3, weight: .bold, design: .rounded))
                .foregroundStyle(.white),
            at: center
        )
    }
}
