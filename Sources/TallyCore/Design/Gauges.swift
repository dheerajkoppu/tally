import SwiftUI

/// One arc of a ring, from `start` to `end` (fractions of the sweep, clockwise), shortened by `gap` points
/// so neighbouring arcs stay apart. A full ring sweeps the whole circle from twelve o'clock.
struct GaugeArc: Shape {
    var start: Double
    var end: Double
    var lineWidth: CGFloat
    var gap: CGFloat = 0
    /// Degrees the gauge covers, centred on twelve o'clock: 360 for a ring, 270 for a dial open at the bottom.
    var sweep: Double = 360

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let radius = min(rect.width, rect.height) / 2 - lineWidth / 2
        guard radius > 0 else { return path }
        let gapDegrees = Double(gap / (2 * .pi * radius)) * 360
        let origin = sweep >= 360 ? -90 : -90 - sweep / 2
        let from = origin + start * sweep + gapDegrees / 2
        let to = origin + end * sweep - gapDegrees / 2
        guard to > from else { return path }
        path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: radius, startAngle: .degrees(from), endAngle: .degrees(to), clockwise: false)
        return path
    }
}

/// A thick ring over a faint track: one value, or a few segments such as app, wired and compressed memory.
public struct RingGauge: View, Equatable {
    public struct Segment: Equatable {
        public var fraction: Double
        public var color: Color

        public init(_ fraction: Double, color: Color = Palette.accent) {
            self.fraction = fraction
            self.color = color
        }
    }

    private struct Arc: Identifiable, Equatable {
        var id: Int
        var start: Double
        var end: Double
        var color: Color
    }

    private let arcs: [Arc]
    private let lineWidth: CGFloat?

    /// - Parameters:
    ///   - segments: shares of the whole ring, drawn clockwise from twelve o'clock.
    ///   - lineWidth: nil makes the ring a fifth of its diameter thick.
    public init(_ segments: [Segment], lineWidth: CGFloat? = nil) {
        var arcs: [Arc] = []
        var start = 0.0
        for (index, segment) in segments.enumerated() where segment.fraction > 0 && segment.fraction.isFinite {
            let end = min(1, quantizedFraction(start + segment.fraction, steps: 400))
            if end > start { arcs.append(Arc(id: index, start: start, end: end, color: segment.color)) }
            start = end
        }
        self.arcs = arcs
        self.lineWidth = lineWidth
    }

    public init(_ fraction: Double, color: Color = Palette.accent, lineWidth: CGFloat? = nil) {
        self.init([Segment(fraction, color: color)], lineWidth: lineWidth)
    }

    public var body: some View {
        GeometryReader { proxy in
            let width = lineWidth ?? min(proxy.size.width, proxy.size.height) * 0.2
            ZStack {
                Circle()
                    .inset(by: width / 2)
                    .stroke(Palette.track, lineWidth: width)
                ForEach(arcs) { arc in
                    GaugeArc(start: arc.start, end: arc.end, lineWidth: width, gap: arcs.count > 1 ? 1.5 : 0)
                        .stroke(arc.color, style: StrokeStyle(lineWidth: width, lineCap: .butt))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// An upright battery that fills from the bottom, with a bolt while charging.
public struct BatteryGlyph: View, Equatable {
    private let level: Double
    private let isCharging: Bool
    private let tint: Color

    public init(level: Double, isCharging: Bool, tint: Color = Palette.accent) {
        self.level = quantizedFraction(level, steps: 100)
        self.isCharging = isCharging
        self.tint = tint
    }

    public var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let capHeight = size.height * 0.08
            let radius = size.width * 0.2
            VStack(spacing: capHeight * 0.4) {
                Capsule()
                    .fill(level >= 0.995 ? tint : Palette.track)
                    .frame(width: size.width * 0.38, height: capHeight)
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(Palette.track)
                    Rectangle()
                        .fill(tint)
                        .frame(height: max(0, (size.height - capHeight * 1.4) * level))
                }
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay {
                    if isCharging {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: size.width * 0.38, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// A thermometer whose stem fills with the reading, beside three tick marks.
public struct ThermometerGlyph: View, Equatable {
    private let level: Double
    private let tint: Color

    /// - Parameter level: how far up the stem the reading sits, 0...1.
    public init(level: Double, tint: Color = Palette.accent) {
        self.level = quantizedFraction(level, steps: 100)
        self.tint = tint
    }

    public var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let bulb = min(size.width * 0.62, size.height * 0.42)
            let stem = bulb * 0.42
            let stemHeight = size.height - bulb * 0.8
            HStack(alignment: .top, spacing: bulb * 0.2) {
                ZStack(alignment: .bottom) {
                    Capsule()
                        .fill(Palette.track)
                        .frame(width: stem, height: stemHeight)
                        .frame(maxHeight: .infinity, alignment: .top)
                    Capsule()
                        .fill(tint)
                        .frame(width: stem, height: max(stem, (stemHeight - bulb * 0.2) * level + bulb * 0.6))
                        .padding(.bottom, bulb * 0.4)
                    Circle()
                        .fill(tint)
                        .frame(width: bulb, height: bulb)
                }
                .frame(width: bulb)
                VStack(alignment: .leading, spacing: stemHeight * 0.14) {
                    ForEach(0..<3, id: \.self) { index in
                        Capsule()
                            .fill(index == 2 - min(2, Int(level * 3)) ? tint : Palette.track)
                            .frame(width: bulb * (index == 1 ? 0.3 : 0.44), height: max(2, bulb * 0.1))
                    }
                }
                .padding(.top, stemHeight * 0.1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityHidden(true)
    }
}

/// A dial open at the bottom with a fan in the middle: how fast a fan spins between its slowest and fastest.
public struct FanGauge: View, Equatable {
    private let fraction: Double
    private let isManual: Bool

    /// - Parameter isManual: a filled fan marks a fixed speed, so the state does not rely on colour.
    public init(fraction: Double, isManual: Bool = false) {
        self.fraction = quantizedFraction(fraction, steps: 200)
        self.isManual = isManual
    }

    public var body: some View {
        GeometryReader { proxy in
            let diameter = min(proxy.size.width, proxy.size.height)
            let width = diameter * 0.16
            ZStack {
                GaugeArc(start: 0, end: 1, lineWidth: width, sweep: 270)
                    .stroke(Palette.track, style: StrokeStyle(lineWidth: width, lineCap: .round))
                if fraction > 0 {
                    GaugeArc(start: 0, end: fraction, lineWidth: width, sweep: 270)
                        .stroke(Palette.accent, style: StrokeStyle(lineWidth: width, lineCap: .round))
                }
                Image(systemName: isManual ? "fan.fill" : "fan")
                    .font(.system(size: diameter * 0.32, weight: .medium))
                    .foregroundStyle(Palette.ink2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityHidden(true)
    }
}

/// A tile that fills from the bottom with a device's battery level, under its symbol.
public struct LevelTile: View, Equatable {
    private let level: Double
    private let symbol: String
    private let tint: Color

    public init(level: Double, symbol: String, tint: Color = Palette.accent) {
        self.level = quantizedFraction(level, steps: 100)
        self.symbol = symbol
        self.tint = tint
    }

    public var body: some View {
        GeometryReader { proxy in
            let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
            ZStack(alignment: .bottom) {
                shape.fill(Palette.track)
                Rectangle()
                    .fill(tint)
                    .frame(height: proxy.size.height * level)
            }
            .clipShape(shape)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: min(proxy.size.width, proxy.size.height) * 0.36, weight: .medium))
                    .foregroundStyle(Palette.ink)
            }
        }
        .accessibilityHidden(true)
    }
}
