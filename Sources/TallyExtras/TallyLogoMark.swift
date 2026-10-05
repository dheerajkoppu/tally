import SwiftUI
import TallyCore

/// The shape and colors of the app icon (Resources/AppIcon.icon), shared by `TallyLogoMark` and scripts/make-icon.swift.
/// Positions and sizes are in unit coordinates of the icon body (0,0 top left). Colours are sampled from the icon as
/// the system renders it (docs/images/icon.png), so the flat mark matches the glass one.
enum LogoGeometry {
    /// Corner radius as a share of the side, drawn with continuous corners, like the macOS 26 icon mask.
    static let cornerRatio: CGFloat = 0.255
    static let backgroundTop = color(0x27292E)
    static let backgroundBottom = color(0x1F2025)

    /// The turning points of the activity trace. It runs in from beyond the left edge, spikes once, settles and
    /// ends in a dot.
    static let tracePoints = [
        CGPoint(x: -0.0781, y: 0.5820), CGPoint(x: 0.1680, y: 0.5820), CGPoint(x: 0.2422, y: 0.6309),
        CGPoint(x: 0.3301, y: 0.1992), CGPoint(x: 0.4199, y: 0.7930), CGPoint(x: 0.5137, y: 0.4277),
        CGPoint(x: 0.5957, y: 0.6113), CGPoint(x: 0.6719, y: 0.5059), CGPoint(x: 0.7617, y: 0.5527),
    ]
    /// How far each curve's handles reach toward the next turning point; smaller makes sharper peaks.
    static let traceHandleRatio: CGFloat = 0.32
    static let traceWidthRatio: CGFloat = 0.0371
    static let dotRadiusRatio: CGFloat = 0.0371
    static let traceTop = color(0x7977FF)
    static let traceBottom = color(0x6F6DF8)

    /// The graph paper behind the trace: this many cells across and down.
    static let gridDivisions = 5
    static let gridLineRatio: CGFloat = 0.0059
    static let gridColor = color(0x393A41)

    private static func color(_ hex: UInt32) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// The menu bar glyph: a rounded square with an activity trace cut out of it.
/// Laid out on StatusItemArtwork's 14 pt grid, scaled to fill its frame. Fill it.
public struct TallyPulseShape: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / 14
        let body = Path(
            roundedRect: CGRect(x: rect.minX, y: rect.minY, width: 14 * unit, height: 14 * unit),
            cornerRadius: 3.5 * unit,
            style: .circular
        )
        var trace = Path()
        trace.addLines([(3, 8), (4.5, 8), (6, 4), (8, 10), (9.5, 7), (11, 7)].map {
            CGPoint(x: rect.minX + $0.0 * unit, y: rect.minY + $0.1 * unit)
        })
        return body.subtracting(trace.strokedPath(StrokeStyle(lineWidth: 2 * unit, lineCap: .round, lineJoin: .round)))
    }
}

/// The Tally app icon: a graphite squircle of graph paper with an activity trace across it, drawn in one pass.
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

        // The grid and the trace run off the edge of the body.
        var content = context
        content.clip(to: body)
        var grid = Path()
        let gridLine = max(side * LogoGeometry.gridLineRatio, 0.5)
        for line in 1..<LogoGeometry.gridDivisions {
            let offset = side * CGFloat(line) / CGFloat(LogoGeometry.gridDivisions) - gridLine / 2
            grid.addRect(CGRect(x: offset, y: 0, width: gridLine, height: side))
            grid.addRect(CGRect(x: 0, y: offset, width: side, height: gridLine))
        }
        content.fill(grid, with: .color(LogoGeometry.gridColor))

        let points = LogoGeometry.tracePoints.map { CGPoint(x: $0.x * side, y: $0.y * side) }
        var trace = Path()
        trace.move(to: points[0])
        for (start, end) in zip(points, points.dropFirst()) {
            let reach = (end.x - start.x) * LogoGeometry.traceHandleRatio
            trace.addCurve(to: end, control1: CGPoint(x: start.x + reach, y: start.y), control2: CGPoint(x: end.x - reach, y: end.y))
        }
        let shading = GraphicsContext.Shading.linearGradient(
            Gradient(colors: [LogoGeometry.traceTop, LogoGeometry.traceBottom]),
            startPoint: CGPoint(x: 0, y: side * 0.2),
            endPoint: CGPoint(x: 0, y: side * 0.8)
        )
        content.stroke(trace, with: shading, style: StrokeStyle(lineWidth: side * LogoGeometry.traceWidthRatio, lineCap: .round, lineJoin: .round))
        let dotRadius = side * LogoGeometry.dotRadiusRatio
        let end = points[points.count - 1]
        content.fill(Path(ellipseIn: CGRect(x: end.x - dotRadius, y: end.y - dotRadius, width: dotRadius * 2, height: dotRadius * 2)), with: shading)

        // Keeps the graphite body apart from dark window backgrounds.
        context.stroke(body, with: .linearGradient(
            Gradient(colors: [.white.opacity(0.28), .white.opacity(0.06)]),
            startPoint: .zero,
            endPoint: CGPoint(x: 0, y: side)
        ), lineWidth: max(side * 0.012, 0.5))
    }
}
