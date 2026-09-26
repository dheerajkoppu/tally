import SwiftUI
import TallyCore

/// Sizes measured from the Tally tab screenshots.
enum MetricLayout {
    static let heroHeight: CGFloat = 200
    static let heroColumnWidth: CGFloat = 170
    static let tileHeight: CGFloat = 110
    static let tilePadding: CGFloat = 14
    /// As tight as the app list in the Tally launch video.
    static let rowHeight: CGFloat = 46.5
    static let rowRadius: CGFloat = 12
    static let rowIconSize: CGFloat = 26
    static let meterWidth: CGFloat = 160
    static let liveSlots = 60
    static let visibleApps = 8
}

/// Caption, big figure, pressure pill and key figures on the left of the hero card.
struct MetricHeroSummary: View, Equatable {
    let caption: String
    let figure: Figure
    let isPlaceholder: Bool
    let pressure: MemoryPressure?
    let keyValues: [MetricKeyValue]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(caption)
                .font(Typography.heroCaption)
                .foregroundStyle(Palette.ink2)
                .lineLimit(1)
                .accessibilityHidden(!isPlaceholder)
            Group {
                if isPlaceholder {
                    MetricSkeletonBar(width: 96, height: 34)
                        .frame(height: 52, alignment: .center)
                        .accessibilityHidden(true)
                } else {
                    MetricHeroFigure(figure: figure)
                        .accessibilityReading(figure.text, value: caption)
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }
            .frame(width: MetricLayout.heroColumnWidth, alignment: .leading)
            .padding(.top, 1)
            if let pressure {
                MetricPressurePill(pressure: pressure)
                    .padding(.top, 6)
            }
            Spacer(minLength: 8)
            VStack(spacing: 7.5) {
                ForEach(keyValues) { row in
                    MetricKeyValueRow(label: row.label, value: row.value)
                        .help(row.help ?? "")
                }
            }
        }
        .frame(width: MetricLayout.heroColumnWidth, alignment: .leading)
    }
}

/// The huge hero number with a smaller grey unit: "66 %", "53.42 GB".
struct MetricHeroFigure: View {
    let figure: Figure

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(figure.value)
                .font(Typography.figure(Typography.heroFigureSize))
                .tracking(-1.3)
                .foregroundStyle(Palette.ink)
            if !figure.unit.isEmpty {
                Text(figure.unit)
                    .font(Typography.heroUnit)
                    .foregroundStyle(Palette.ink2)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
}

/// "✓ Normal" under the memory figure. Each level has its own symbol, so it reads without its colour.
struct MetricPressurePill: View {
    let pressure: MemoryPressure

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: pressure.symbol)
                .font(Typography.inlineSymbol)
            Text(pressure.label)
                .font(Typography.pill)
        }
        .foregroundStyle(LegibleTint(pressure.tint, wash: 0.14))
        .padding(.horizontal, 9.5)
        .frame(height: 18)
        .background(pressure.tint.opacity(0.14), in: Capsule())
        .help("Memory pressure: how easily macOS can find memory for what is running.")
        .accessibilityReading("Memory pressure", value: pressure.label)
    }
}

/// Small capsule pills: Live · 12 h · 24 h · 7 d · 30 d. VoiceOver sees a standard segmented control,
/// and with keyboard navigation on, the arrow keys move the selection. Like a system segmented control, the selection
/// turns grey while the window is inactive.
struct MetricRangePicker<Item: Hashable & Identifiable>: View {
    let label: String
    let items: [Item]
    @Binding var selection: Item
    let tint: Color
    let title: (Item) -> String

    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiatesWithoutColor
    @Environment(\.accessibilityReduceTransparency) private var reducesTransparency

    var body: some View {
        HStack(spacing: 1) {
            ForEach(items) { item in
                let isSelected = item == selection
                Button {
                    selection = item
                } label: {
                    Text(title(item))
                        .font(Typography.segment)
                        .fontWeight(isSelected && differentiatesWithoutColor ? .bold : .medium)
                        .foregroundStyle(foreground(isSelected: isSelected))
                        .padding(.horizontal, 8)
                        .frame(height: 18)
                        .background {
                            if isSelected { Capsule().fill(appearsActive ? tint.opacity(0.16) : Palette.cardHighlight) }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .contentShape(.focusEffect, Capsule())
            }
        }
        .padding(2)
        .background(Palette.cardHighlight.opacity(reducesTransparency ? 1 : 0.7), in: Capsule())
        .controlOutline(Capsule())
        .onMoveCommand { direction in
            guard let index = items.firstIndex(of: selection) else { return }
            switch direction {
            case .left where index > 0: selection = items[index - 1]
            case .right where index < items.count - 1: selection = items[index + 1]
            default: break
            }
        }
        .accessibilityRepresentation {
            Picker(label, selection: $selection) {
                ForEach(items) { item in
                    Text(title(item)).tag(item)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private func foreground(isSelected: Bool) -> AnyShapeStyle {
        guard isSelected else { return AnyShapeStyle(Palette.ink2) }
        return appearsActive ? AnyShapeStyle(LegibleTint(tint, on: Palette.cardHighlight, wash: 0.16)) : AnyShapeStyle(Palette.ink)
    }
}

/// A compact tinted capsule for short tags: "8 P", "Macintosh HD".
struct MetricTagPill: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(Typography.tag)
            .lineLimit(1)
            .foregroundStyle(LegibleTint(tint, wash: 0.14))
            .padding(.horizontal, 5.5)
            .frame(height: 15)
            .background(tint.opacity(0.14), in: Capsule())
    }
}

/// Badge and grey label at the top of every stat tile.
struct MetricTileHeader: View {
    let symbol: String
    let label: String
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            IconBadge(symbol, tint: tint)
                .accessibilityHidden(true)
            Text(label)
                .font(Typography.tileTitle)
                .foregroundStyle(Palette.ink2)
                .lineLimit(1)
        }
    }
}

/// One of the four tiles under the hero card.
struct MetricStatTile: View, Equatable {
    let tile: MetricTileModel
    let tint: Color
    var isPlaceholder = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MetricTileHeader(symbol: tile.symbol, label: tile.label, tint: tint)
            if isPlaceholder {
                MetricSkeletonBar(width: 64, height: 16)
                    .frame(height: 24.5, alignment: .center)
                    .padding(.top, 10)
            } else {
                Text(tile.value)
                    .font(Typography.figure(Typography.tileFigureSize))
                    .tracking(-0.3)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.top, 10)
            }
            Spacer(minLength: 0)
            detail
                .frame(height: 16, alignment: .leading)
                .padding(.bottom, 1.5)
        }
        .padding(MetricLayout.tilePadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: MetricLayout.tileHeight)
        .metricSurface()
        .help(tile.help ?? "")
        .accessibilityReading(tile.label, value: accessibilityValue)
    }

    private var accessibilityValue: String {
        if isPlaceholder { return "Loading" }
        switch tile.detail {
        case .none, .meter: return tile.value
        case .text(let text): return "\(tile.value), \(text)"
        case .tags(let tags):
            // The tooltip spells out short tags such as "8 P".
            if let help = tile.help, !help.isEmpty { return "\(tile.value), \(help)" }
            return tags.isEmpty ? tile.value : "\(tile.value), \(tags.joined(separator: ", "))"
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch tile.detail {
        case .none:
            Color.clear
        case .text(let text):
            Text(text)
                .font(Typography.tileSubtitle)
                .foregroundStyle(Palette.ink2)
                .lineLimit(1)
                .truncationMode(.middle)
        case .tags(let tags):
            MetricTagRow(tags: tags, tint: tint)
        case .meter(let fraction):
            Meter(fraction, tint: tint)
        }
    }
}

/// Tags in one line; the ones that do not fit collapse into "+N".
struct MetricTagRow: View {
    let tags: [String]
    let tint: Color

    var body: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(Array(stride(from: tags.count, through: 1, by: -1)), id: \.self) { shown in
                HStack(spacing: 4) {
                    // By position: two volumes can share a name.
                    ForEach(0..<shown, id: \.self) { index in MetricTagPill(text: tags[index], tint: tint) }
                    if shown < tags.count {
                        MetricTagPill(text: "+\(tags.count - shown)", tint: tint)
                    }
                }
                .fixedSize()
            }
        }
    }
}

/// The fourth tile: the app using the most of this tab's metric right now. Opens the inspector.
struct MetricTopAppTile: View, Equatable {
    let appID: String?
    let name: String
    let bundlePath: String?
    let value: String
    let tint: Color
    var isPlaceholder = false

    @State private var isHovered = false

    static func == (lhs: MetricTopAppTile, rhs: MetricTopAppTile) -> Bool {
        lhs.appID == rhs.appID && lhs.name == rhs.name && lhs.bundlePath == rhs.bundlePath && lhs.value == rhs.value
            && lhs.tint == rhs.tint && lhs.isPlaceholder == rhs.isPlaceholder
    }

    var body: some View {
        Button {
            if let appID { AppRouter.shared.inspectedAppID = appID }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                MetricTileHeader(symbol: Symbols.apps, label: "Top App", tint: tint)
                HStack(spacing: 9) {
                    if let appID {
                        AppIconView(appID: appID, bundlePath: bundlePath, size: 20)
                            .padding(.leading, 1)
                        Text(name)
                            .font(Typography.tileName)
                            .foregroundStyle(Palette.ink)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    } else if isPlaceholder {
                        MetricSkeletonBar(width: 120)
                    } else {
                        Text("None right now")
                            .font(Typography.tileName)
                            .foregroundStyle(Palette.ink2)
                    }
                }
                .frame(height: 24)
                .padding(.top, 10)
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Text(appID == nil ? "—" : value)
                        .font(Typography.tileFootnote)
                        .foregroundStyle(appID == nil ? Palette.ink2 : Palette.ink)
                    Spacer(minLength: 0)
                    if appID != nil {
                        Image(systemName: "chevron.right")
                            .font(Typography.chevron)
                            .foregroundStyle(isHovered ? Palette.ink2 : Palette.ink3)
                            .padding(.trailing, 2)
                    }
                }
                .frame(height: 16)
            }
            .padding(MetricLayout.tilePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: MetricLayout.tileHeight)
            .metricSurface(isHovered && appID != nil ? Palette.cardHighlight : Palette.card)
            .contentShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .contentShape(.focusEffect, RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
        .disabled(appID == nil)
        .onHover { isHovered = $0 }
        .help(appID == nil ? "" : "Inspect \(name)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Top app")
        .accessibilityValue(appID == nil ? (isPlaceholder ? "Loading" : "None right now") : "\(name), \(value)")
        .accessibilityHint(appID == nil ? "" : "Shows the app's processes")
        .accessibilityAddTraits(.isButton)
    }
}

/// "Average today   50%" in the hero card.
struct MetricKeyValueRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(Palette.ink2)
            Spacer(minLength: 10)
            Text(value)
                .fontWeight(.semibold)
                .monospacedDigit()
                .foregroundStyle(Palette.ink)
        }
        .font(Typography.label)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }
}

/// A placeholder bar that stands in for text before the first sample.
struct MetricSkeletonBar: View {
    let width: CGFloat
    var height: CGFloat = 9

    var body: some View {
        Capsule()
            .fill(Palette.cardHighlight)
            .frame(width: width, height: height)
    }
}

/// A filled rounded rectangle behind content, outlined when Increase Contrast or Show Borders is on, as Core's Card is.
struct MetricSurface: ViewModifier {
    let fill: Color
    let radius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(fill, in: shape)
            .surfaceOutline(shape)
    }
}

extension View {
    func metricSurface(_ fill: Color = Palette.card, radius: CGFloat = Metrics.cardRadius) -> some View {
        modifier(MetricSurface(fill: fill, radius: radius))
    }
}
