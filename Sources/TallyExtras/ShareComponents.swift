import SwiftUI
import TallyCore

extension Palette {
    /// The warm ground around an exported image, and the glow that lights it from the lower right.
    static let shareGround = Color.dynamic(light: 0xF1F0E7, dark: 0x131315)
    static let shareGlow = Color.dynamic(light: 0xFAAD66, dark: 0x8A4620)
    static let shareGlowSoft = Color.dynamic(light: 0xF9B97A, dark: 0x6B3A1D)
    static let shareGlowDeep = Color.dynamic(light: 0xEE8657, dark: 0x9E4424)
    /// The card an exported image sits on, and the panels inside it.
    static let shareCard = Color.dynamic(light: 0xFFFFFF, dark: 0x1C1C1F)
    static let shareInset = Color.dynamic(light: 0xF8F8FA, dark: 0x252528)
    static let shareTrack = Color.dynamic(light: 0xEBEBEE, dark: 0x333337, increasedContrastLight: 0xDCDCE0, increasedContrastDark: 0x46464B)
    static let shareEdge = Color.dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.07, darkAlpha: 0.09)
    static let shareShadow = Color.dynamic(light: 0x5A4020, dark: 0x000000, lightAlpha: 0.08, darkAlpha: 0.5)
    /// The light unit beside a large figure ("GB").
    static let shareUnit = Color.dynamic(light: 0xA8A8AD, dark: 0x707075, increasedContrastLight: 0x6E6E73, increasedContrastDark: 0xA1A1A6)
    static let pressureElevated = Color.dynamic(light: 0xE8791E, dark: 0xF0913C, increasedContrastLight: 0xB35A0C, increasedContrastDark: 0xF7B477)
}

extension MemoryPressure {
    /// Green, orange and red, as the exported images show the level.
    var shareTint: Color {
        switch self {
        case .normal: Palette.battery
        case .warning: Palette.pressureElevated
        case .critical: Palette.red
        }
    }
}

/// The frame of every exported image: a white card on a warm ground with a soft orange glow.
struct ShareCanvas<Content: View>: View {
    private let size: CGSize
    private let margin: CGFloat
    private let padding: EdgeInsets
    private let content: Content

    init(size: CGSize, margin: CGFloat = 50, padding: EdgeInsets, @ViewBuilder content: () -> Content) {
        self.size = size
        self.margin = margin
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        content
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                shape
                    .fill(Palette.shareCard)
                    .shadow(color: Palette.shareShadow, radius: 18, y: 6)
            }
            .overlay(shape.strokeBorder(Palette.shareEdge, lineWidth: 1))
            .padding(margin)
            .frame(width: size.width, height: size.height)
            .background(ShareGround(size: size))
    }
}

/// The ground behind the card: warm off-white, lit orange along the right edge and the lower middle.
private struct ShareGround: View {
    let size: CGSize

    var body: some View {
        ZStack(alignment: .topLeading) {
            Palette.shareGround
            glow(Palette.shareGlow, center: CGPoint(x: 1.05, y: 0.38), radii: CGSize(width: 0.2, height: 0.62))
            glow(Palette.shareGlowSoft, center: CGPoint(x: 0.62, y: 0.98), radii: CGSize(width: 0.29, height: 0.23))
            glow(Palette.shareGlowDeep, center: CGPoint(x: 0.715, y: 1.0), radii: CGSize(width: 0.14, height: 0.14))
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    /// An elliptical glow, placed and sized as fractions of the image.
    private func glow(_ color: Color, center: CGPoint, radii: CGSize) -> some View {
        EllipticalGradient(
            stops: [
                .init(color: color, location: 0),
                .init(color: color.opacity(0.92), location: 0.5),
                .init(color: color.opacity(0), location: 1),
            ],
            center: .center,
            startRadiusFraction: 0,
            endRadiusFraction: 0.5
        )
        .frame(width: radii.width * 2 * size.width, height: radii.height * 2 * size.height)
        .position(x: center.x * size.width, y: center.y * size.height)
    }
}

/// A light grey panel inside the card.
struct ShareInset<Content: View>: View {
    private let padding: EdgeInsets
    private let content: Content

    init(padding: EdgeInsets, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        content
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Palette.shareInset, in: shape)
            .overlay(shape.strokeBorder(Palette.shareEdge.opacity(0.5), lineWidth: 1))
    }
}

/// A small spaced-out capitals label ("MEMORY IN USE").
struct ShareCapsLabel: View {
    private let text: String
    private let size: CGFloat

    init(_ text: String, size: CGFloat = 10.5) {
        self.text = text
        self.size = size
    }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: size, weight: .semibold))
            .tracking(size * 0.11)
            .foregroundStyle(Palette.ink2)
            .lineLimit(1)
    }
}

/// The memory pressure level as a small tinted tag ("Elevated").
struct SharePressureTag: View {
    let pressure: MemoryPressure
    var size: CGFloat = 10.5

    var body: some View {
        let tint = pressure.shareTint
        Text(pressure.label)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(LegibleTint(tint, on: Palette.shareCard, wash: 0.14))
            .lineLimit(1)
            .padding(.horizontal, size * 0.65)
            .frame(height: size * 1.55)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: size * 0.45, style: .continuous))
    }
}

/// "● App 10.98 GB"
struct ShareLegendItem: View {
    let color: Color
    let label: String
    let value: String
    var size: CGFloat = 12

    var body: some View {
        HStack(spacing: size * 0.45) {
            Circle().fill(color).frame(width: size * 0.5, height: size * 0.5)
            Text(label)
                .font(.system(size: size))
                .foregroundStyle(Palette.ink2)
            Text(value)
                .font(.system(size: size, weight: .semibold).monospacedDigit())
                .foregroundStyle(Palette.ink)
        }
        .lineLimit(1)
    }
}

/// "Now 30%": a grey label and a bold value on one baseline.
struct ShareInlineStat: View {
    let label: String
    let value: String
    var labelSize: CGFloat = 11.5
    var valueSize: CGFloat = 15

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: labelSize * 0.5) {
            Text(label)
                .font(.system(size: labelSize))
                .foregroundStyle(Palette.ink2)
            Text(value)
                .font(.system(size: valueSize, weight: .bold).monospacedDigit())
                .foregroundStyle(Palette.ink)
        }
        .lineLimit(1)
    }
}

/// App, Wired and Compressed memory as one rounded bar on a grey track, with hairline gaps between the parts.
struct ShareMemoryBar: View {
    let memory: MemoryStats

    var body: some View {
        let total = max(Double(memory.totalBytes), 1)
        let parts: [(Double, Color)] = [
            (Double(memory.appBytes), Palette.memoryApp),
            (Double(memory.wiredBytes), Palette.memoryWired),
            (Double(memory.compressedBytes), Palette.memoryCompressed),
        ]
        Canvas { context, size in
            let capsule = Capsule().path(in: CGRect(origin: .zero, size: size))
            context.fill(capsule, with: .color(Palette.shareTrack))
            context.clip(to: capsule)
            let gap: CGFloat = 2
            var x: CGFloat = 0
            let visible = parts.filter { $0.0 > 0 }
            for (index, part) in visible.enumerated() {
                let width = size.width * CGFloat(min(part.0 / total, 1))
                let isLast = index == visible.count - 1
                let drawn = max(width - (isLast ? 0 : gap), 1)
                context.fill(Path(CGRect(x: x, y: 0, width: min(drawn, size.width - x), height: size.height)), with: .color(part.1))
                x += width
            }
        }
    }
}

/// A thin bar on a neutral track, as long as `fraction` of the width.
struct ShareMeter: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        Canvas { context, size in
            context.fill(Capsule().path(in: CGRect(origin: .zero, size: size)), with: .color(Palette.shareTrack))
            let clamped = min(max(fraction, 0), 1)
            guard clamped > 0 else { return }
            let width = max(size.width * clamped, size.height)
            context.fill(Capsule().path(in: CGRect(x: 0, y: 0, width: width, height: size.height)), with: .color(tint))
        }
    }
}

/// Rounded bars over full-height grey tracks, one per slot; empty slots show only their track.
struct ShareBarChart: View {
    let slots: [Double?]
    let maxValue: Double
    let tint: Color
    var barWidth: CGFloat = 8

    var body: some View {
        Canvas { context, size in
            guard !slots.isEmpty else { return }
            let pitch = size.width / CGFloat(slots.count)
            let width = min(barWidth, pitch * 0.8)
            let radius = width / 2
            var tracks = Path()
            var bars = Path()
            for (index, value) in slots.enumerated() {
                let x = pitch * (CGFloat(index) + 0.5) - width / 2
                tracks.addRoundedRect(in: CGRect(x: x, y: 0, width: width, height: size.height), cornerSize: CGSize(width: radius, height: radius), style: .continuous)
                guard let value, maxValue > 0 else { continue }
                let height = size.height * CGFloat(min(max(value / maxValue, 0), 1))
                guard height >= 1 else { continue }
                let barRadius = min(radius, height / 2)
                bars.addRoundedRect(in: CGRect(x: x, y: size.height - height, width: width, height: height), cornerSize: CGSize(width: barRadius, height: barRadius), style: .continuous)
            }
            context.fill(tracks, with: .color(Palette.shareTrack))
            context.fill(bars, with: .color(tint))
        }
    }
}

/// The last few minutes of one live series in equal time slots. A sample stands for the time since the one before it,
/// since that is what it measured, so slower sampling still fills every slot; a slot no sample covers stays empty.
struct RecentSlots {
    static let span: TimeInterval = 300
    /// Longest stretch one sample may stand for, so a gap such as sleep shows as empty slots.
    private static let longestSampleSpan: TimeInterval = 30

    let slots: [Double?]
    let average: Double
    let peak: Double
    /// Seconds of the span the samples cover.
    let covered: TimeInterval

    init(dates: [Date], values: [Double], slotCount: Int) {
        let count = min(dates.count, values.count)
        let dates = Array(dates.suffix(count))
        let values = Array(values.suffix(count))
        let slotLength = Self.span / Double(slotCount)
        var sums = [Double](repeating: 0, count: slotCount)
        var weights = [Double](repeating: 0, count: slotCount)
        var peak = 0.0
        var earliest = Self.span
        if let end = dates.last {
            let start = end.addingTimeInterval(-Self.span)
            let firstGap = count > 1 ? dates[1].timeIntervalSince(dates[0]) : slotLength
            for index in dates.indices {
                let sampleEnd = dates[index].timeIntervalSince(start)
                guard sampleEnd > 0 else { continue }
                let gap = index > 0 ? dates[index].timeIntervalSince(dates[index - 1]) : firstGap
                let sampleStart = max(sampleEnd - min(max(gap, 0), Self.longestSampleSpan), 0)
                let value = values[index]
                peak = max(peak, value)
                earliest = min(earliest, sampleStart)
                var slot = min(Int(sampleStart / slotLength), slotCount - 1)
                while slot < slotCount {
                    let slotStart = Double(slot) * slotLength
                    let overlap = min(sampleEnd, slotStart + slotLength) - max(sampleStart, slotStart)
                    if overlap > 0 {
                        sums[slot] += value * overlap
                        weights[slot] += overlap
                    }
                    if slotStart + slotLength >= sampleEnd { break }
                    slot += 1
                }
            }
        }
        slots = zip(sums, weights).map { $1 > 0 ? $0 / $1 : nil }
        let totalWeight = weights.reduce(0, +)
        average = totalWeight > 0 ? sums.reduce(0, +) / totalWeight : 0
        self.peak = peak
        covered = Self.span - earliest
    }

    init(_ metric: HistoryMetric, in live: LiveSeries, slotCount: Int) {
        self.init(dates: live.dates, values: live.values(for: metric), slotCount: slotCount)
    }

    /// "Last 5 minutes", or "Since launch" while Tally has been sampling for less than that.
    func title(liveCount: Int) -> String {
        if covered >= Self.span - 10 { return "Last 5 minutes" }
        if liveCount < LiveSeries.capacity { return "Since launch" }
        let minutes = max(1, Int((covered / 60).rounded()))
        return minutes == 1 ? "Last minute" : "Last \(minutes) minutes"
    }
}

/// "944 processes, grouped into 65 apps"
enum ShareText {
    static func grouping(processes: Int, apps: Int) -> String {
        let processText = processes == 1 ? "1 process" : "\(Format.integer(Double(processes))) processes"
        let appText = apps == 1 ? "1 app" : "\(Format.integer(Double(apps))) apps"
        return "\(processText), grouped into \(appText)"
    }
}
