import SwiftUI
import TallyCore

/// The shape and colors of the app icon (Resources/AppIcon.icon), shared by `TallyLogoMark` and scripts/make-icon.swift.
/// Positions and sizes are in unit coordinates of the icon body (0,0 top left). Colours are sampled from the icon as
/// the system renders it (docs/images/icon.png), so the flat mark matches the glass one.
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
    static let backgroundTop = color(0x35363A)
    static let backgroundBottom = color(0x2B2C31)

    /// The pile of app tiles, back to front: GPU pink, Disk amber and Network green from the app's palette.
    static let tiles = [
        Tile(center: CGPoint(x: 0.4339, y: 0.4339), side: 0.5160, degrees: -16, top: color(0xFD74A7), bottom: color(0xE35F91)),
        Tile(center: CGPoint(x: 0.4996, y: 0.4996), side: 0.5160, degrees: -8, top: color(0xFFC244), bottom: color(0xF2B63A)),
        Tile(center: CGPoint(x: 0.5833, y: 0.5833), side: 0.5404, degrees: 0, top: color(0x32B281), bottom: color(0x19A070)),
    ]
    static let tileCornerRatio: CGFloat = 0.25
    /// The 2×2 grid on the front tile, in the proportions of the SF Symbol square.grid.2x2: each cell a share of the
    /// tile side, gaps and corners a fifth of a cell.
    static let cellRatio: CGFloat = 0.228
    static let cellGapRatio: CGFloat = 0.195
    static let cellCornerRatio: CGFloat = 0.2

    private static func color(_ hex: UInt32) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
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

/// The Tally app icon: a graphite squircle with a pile of three app tiles, drawn in one pass.
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
            // An offset shade stands in for the icon's glass shadow, without a blur.
            tileContext.fill(shape.offsetBy(dx: tileSide * 0.012, dy: tileSide * 0.03), with: .color(.black.opacity(0.32)))
            tileContext.fill(shape, with: .linearGradient(
                Gradient(colors: [tile.top, tile.bottom]),
                startPoint: CGPoint(x: 0, y: frame.minY),
                endPoint: CGPoint(x: 0, y: frame.maxY)
            ))
            tileContext.stroke(shape, with: .linearGradient(
                Gradient(colors: [.white.opacity(0.55), .white.opacity(0)]),
                startPoint: CGPoint(x: 0, y: frame.minY),
                endPoint: CGPoint(x: 0, y: frame.midY)
            ), lineWidth: max(tileSide * 0.01, 0.5))

            if index == LogoGeometry.tiles.count - 1 {
                let cell = tileSide * LogoGeometry.cellRatio
                let pitch = cell * (1 + LogoGeometry.cellGapRatio)
                for row in 0..<2 {
                    for column in 0..<2 {
                        let cellFrame = CGRect(
                            x: (CGFloat(column) - 0.5) * pitch - cell / 2,
                            y: (CGFloat(row) - 0.5) * pitch - cell / 2,
                            width: cell,
                            height: cell
                        )
                        let cellShape = RoundedRectangle(cornerRadius: cell * LogoGeometry.cellCornerRatio, style: .continuous).path(in: cellFrame)
                        tileContext.fill(cellShape, with: .color(.white))
                    }
                }
            }
        }
    }
}
