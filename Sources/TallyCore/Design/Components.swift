import SwiftUI
import AppKit

/// The rounded grey surface every section sits on. Outlined when Increase Contrast or Show Borders is on.
public struct Card<Content: View>: View {
    private let padding: CGFloat
    private let content: Content

    public init(padding: CGFloat = Metrics.cardPadding, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(Palette.card, in: shape)
            .surfaceOutline(shape)
    }
}

/// An SF Symbol on a quiet rounded square, used beside row titles and on the welcome tiles.
/// Decorative, so hidden from VoiceOver.
public struct IconBadge: View, Equatable {
    private let symbol: String
    private let tint: Color
    private let size: CGFloat

    public init(_ symbol: String, tint: Color, size: CGFloat = Metrics.badgeSize) {
        self.symbol = symbol
        self.tint = tint
        self.size = size
    }

    public var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .medium))
            .foregroundStyle(LegibleTint(tint, on: Palette.cardHighlight))
            .frame(width: size, height: size)
            .background(Palette.cardHighlight, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A grey symbol and title, with an optional chevron, at the top of every card.
public struct CardHeader: View, Equatable {
    private let title: String
    private let symbol: String
    private let showsChevron: Bool

    public init(_ title: String, symbol: String, showsChevron: Bool = false) {
        self.title = title
        self.symbol = symbol
        self.showsChevron = showsChevron
    }

    public var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(Typography.cardSymbol)
                .accessibilityHidden(true)
            Text(title)
                .font(Typography.cardTitle)
                .lineLimit(1)
            Spacer(minLength: 0)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(Typography.chevron)
                    .foregroundStyle(Palette.ink3)
                    .padding(.trailing, 1.5)
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(Palette.ink2)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A large bold number with its unit: "69%" and "58°" as one figure, "53.88 GB" with a smaller, lighter unit.
/// Changes without animation.
public struct BigFigure: View, Equatable {
    private let figure: Figure
    private let size: CGFloat

    public init(_ figure: Figure, size: CGFloat = 36) {
        self.figure = figure
        self.size = size
    }

    public init(_ value: String, unit: String, size: CGFloat = 36) {
        self.figure = Figure(value, unit)
        self.size = size
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: figure.joinsUnit ? 0 : size * 0.14) {
            Text(figure.joinsUnit ? figure.value + figure.unit : figure.value)
                .font(Typography.figure(size))
                .tracking(-size * 0.015)
                .foregroundStyle(Palette.ink)
            if !figure.unit.isEmpty, !figure.joinsUnit {
                Text(figure.unit)
                    .font(Typography.figureUnit(size * 0.5))
                    .foregroundStyle(Palette.ink2)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .accessibilityReading(figure.text)
    }
}

/// A small grey tag with a quiet label and a bold value: "Charging 58m", or a value alone: "Macintosh HD".
public struct Chip: View, Equatable {
    private let label: String?
    private let value: String
    private let dot: Color?

    /// - Parameter dot: a status colour shown before the text, such as memory pressure.
    public init(_ label: String? = nil, value: String, dot: Color? = nil) {
        self.label = label
        self.value = value
        self.dot = dot
    }

    public var body: some View {
        HStack(spacing: 4) {
            if let dot {
                Circle().fill(dot).frame(width: 6, height: 6)
            }
            if let label {
                Text(label)
                    .font(Typography.chipLabel)
                    .foregroundStyle(Palette.ink2)
            }
            Text(value)
                .font(Typography.chipValue)
                .foregroundStyle(Palette.ink)
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 6)
        .frame(height: 18)
        .background(Palette.cardHighlight, in: RoundedRectangle(cornerRadius: Metrics.chipRadius, style: .continuous))
        .accessibilityReading(label ?? "", value: value)
    }
}

/// A small caption over a value: "User / 48%".
public struct StatColumn: View, Equatable {
    private let label: String
    private let value: String
    private let dot: Color?

    public init(_ label: String, value: String, dot: Color? = nil) {
        self.label = label
        self.value = value
        self.dot = dot
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
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

/// A label on the left and a value on the right: "Average today   50%".
public struct KeyValueRow: View, Equatable {
    private let label: String
    private let value: String

    public init(_ label: String, value: String) {
        self.label = label
        self.value = value
    }

    public var body: some View {
        HStack {
            Text(label).font(Typography.label).foregroundStyle(Palette.ink2)
            Spacer(minLength: 12)
            Text(value).font(Typography.value).foregroundStyle(Palette.ink)
        }
        .lineLimit(1)
        .accessibilityReading(label, value: value)
    }
}

/// Places its one subview at the leading edge, as wide as `fraction` of the space, without a GeometryReader.
private struct LeadingFractionLayout: Layout {
    var fraction: Double
    var minimumWidth: CGFloat

    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? {
        nil
    }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? {
        nil
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 100, height: proposal.height ?? minimumWidth)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let width = fraction > 0 ? max(minimumWidth, bounds.width * fraction) : 0
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: width, height: bounds.height))
    }
}

/// A thin capsule meter on a faint track of the same tint. Updates without animation.
public struct Meter: View, Equatable {
    private let fraction: Double
    private let tint: Color
    private let height: CGFloat
    private let label: String?

    /// - Parameter label: what VoiceOver calls the meter; its value is read as a percentage.
    public init(_ fraction: Double, tint: Color, height: CGFloat = 6, label: String? = nil) {
        self.fraction = quantizedFraction(fraction)
        self.tint = tint
        self.height = height
        self.label = label
    }

    public var body: some View {
        LeadingFractionLayout(fraction: fraction, minimumWidth: height) {
            Capsule().fill(tint)
        }
        .frame(height: height)
        .background(tint.opacity(0.14), in: Capsule())
        .accessibilityReading(label ?? "", value: "\(Int((fraction * 100).rounded())) percent")
    }
}

/// Lays capsules out left to right, each as wide as its share of `total`, 2 pt apart.
private struct ProportionalRowLayout: Layout {
    var values: [Double]
    var total: Double

    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? {
        nil
    }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? {
        nil
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 100, height: proposal.height ?? 6)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (index, subview) in subviews.enumerated() {
            let value = index < values.count ? values[index] : 0
            let width = max(0, bounds.width * value / max(total, 1) - 2)
            subview.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading, proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + 2
        }
    }
}

/// A stacked horizontal bar of segments, as in the memory breakdown.
public struct SegmentedMeter: View, Equatable {
    public struct Segment: Identifiable, Equatable {
        public var id: Int
        public var value: Double
        public var color: Color
        /// What VoiceOver calls this segment.
        public var label: String?

        public init(id: Int, value: Double, color: Color, label: String? = nil) {
            self.id = id
            self.value = value
            self.color = color
            self.label = label
        }
    }

    private let segments: [Segment]
    private let total: Double
    private let height: CGFloat
    private let label: String?

    /// - Parameter label: what VoiceOver calls the bar, such as "Memory"; each labelled segment is read with its share.
    public init(_ segments: [Segment], total: Double, height: CGFloat = 6, label: String? = nil) {
        let safeTotal = max(total, 1)
        self.segments = segments.map { segment in
            var rounded = segment
            rounded.value = quantizedFraction(segment.value / safeTotal) * safeTotal
            return rounded
        }
        self.total = total
        self.height = height
        self.label = label
    }

    public var body: some View {
        ProportionalRowLayout(values: segments.map(\.value), total: total) {
            ForEach(segments) { segment in
                Capsule().fill(segment.color)
            }
        }
        .frame(height: height)
        .background(Palette.cardHighlight, in: Capsule())
        .accessibilityReading(label ?? "", value: accessibilityDescription)
    }

    private var accessibilityDescription: String {
        segments.compactMap { segment in
            guard let label = segment.label else { return nil }
            return "\(label) \(Int((segment.value / max(total, 1) * 100).rounded())) percent"
        }
        .joined(separator: ", ")
    }
}

public enum PillStyle {
    /// Tinted text on a faint tint background ("Normal", ports).
    case tinted
    /// Grey text on a grey background ("idle 45 min").
    case neutral
    /// White text on a solid tint ("Stop All").
    case solid
}

/// A small tag in a status colour, with an optional symbol.
public struct Pill: View, Equatable {
    private let text: String
    private let symbol: String?
    private let tint: Color
    private let style: PillStyle
    private let fontSize: CGFloat

    public init(_ text: String, symbol: String? = nil, tint: Color, style: PillStyle = .tinted, fontSize: CGFloat = 11.5) {
        self.text = text
        self.symbol = symbol
        self.tint = tint
        self.style = style
        self.fontSize = max(fontSize, Typography.minimumSize)
    }

    public var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: fontSize * 0.85, weight: .semibold))
                    .accessibilityHidden(true)
            }
            Text(text).font(.system(size: fontSize, weight: .semibold)).monospacedDigit()
        }
        .lineLimit(1)
        .foregroundStyle(foreground)
        .padding(.horizontal, fontSize * 0.6)
        .padding(.vertical, fontSize * 0.28)
        .background(background, in: RoundedRectangle(cornerRadius: Metrics.chipRadius, style: .continuous))
        .accessibilityReading(text)
    }

    private var foreground: AnyShapeStyle {
        switch style {
        case .tinted: AnyShapeStyle(LegibleTint(tint, wash: 0.14))
        case .neutral: AnyShapeStyle(Palette.ink2)
        case .solid: AnyShapeStyle(Color.white)
        }
    }

    private var background: AnyShapeStyle {
        switch style {
        case .tinted: AnyShapeStyle(tint.opacity(0.14))
        case .neutral: AnyShapeStyle(Palette.cardHighlight)
        case .solid: AnyShapeStyle(LegibleTint(tint, on: .white))
        }
    }
}

/// Scaled copies of app icons at the size they are shown, so a redraw never resamples a 256 px bitmap.
@MainActor
private final class AppIconThumbnails {
    static let shared = AppIconThumbnails()
    private static let capacity = 1024

    private struct Key: Hashable {
        let source: ObjectIdentifier
        let pixels: Int
    }

    private var cache: [Key: (source: NSImage, thumbnail: NSImage)] = [:]

    func thumbnail(of source: NSImage, size: CGFloat) -> NSImage {
        let pixels = Int((size * 2).rounded(.up))
        let key = Key(source: ObjectIdentifier(source), pixels: pixels)
        if let entry = cache[key], entry.source === source { return entry.thumbnail }
        guard pixels < 256,
              let cgImage = source.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return source }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        guard let scaled = context.makeImage() else { return source }
        let thumbnail = NSImage(cgImage: scaled, size: NSSize(width: size, height: size))
        // Every app seen gets a thumbnail per size shown; start over rather than grow for the life of the app.
        if cache.count >= Self.capacity { cache.removeAll(keepingCapacity: true) }
        cache[key] = (source, thumbnail)
        return thumbnail
    }
}

/// An app's icon from the icon cache, pre-scaled to its display size. Decorative, so hidden from VoiceOver.
public struct AppIconView: View {
    private let image: NSImage
    private let size: CGFloat

    @MainActor
    public init(_ app: AppUsage, size: CGFloat = 22) {
        self.image = AppIconThumbnails.shared.thumbnail(of: AppIconCache.shared.icon(for: app), size: size)
        self.size = size
    }

    @MainActor
    public init(bundlePath: String?, size: CGFloat = 22) {
        self.image = AppIconThumbnails.shared.thumbnail(of: AppIconCache.shared.icon(forBundlePath: bundlePath), size: size)
        self.size = size
    }

    /// For an app known only by its ID, such as an alert or history entry: "system", a bundle or a tool path.
    @MainActor
    public init(appID: String, bundlePath: String?, size: CGFloat = 22) {
        self.image = AppIconThumbnails.shared.thumbnail(of: AppIconCache.shared.icon(appID: appID, bundlePath: bundlePath), size: size)
        self.size = size
    }

    public var body: some View {
        Image(nsImage: image)
            .resizable()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// A color dot, an optional icon, a label and a right-aligned value, used beside donut charts.
public struct LegendRow<Icon: View>: View {
    public static var height: CGFloat { 15.25 }

    private let color: Color
    private let label: String
    private let value: String
    private let icon: Icon

    public init(color: Color, label: String, value: String, @ViewBuilder icon: () -> Icon) {
        self.color = color
        self.label = label
        self.value = value
        self.icon = icon()
    }

    public var body: some View {
        HStack(spacing: 0) {
            Circle().fill(color).frame(width: 6, height: 6)
            icon.padding(.leading, 6)
            Text(label)
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, 6)
            Spacer(minLength: 8)
            Text(value)
                .foregroundStyle(Palette.ink2)
                .monospacedDigit()
                .lineLimit(1)
                .layoutPriority(1)
        }
        .font(Typography.legend)
        .frame(height: Self.height)
        .accessibilityReading(label, value: value)
    }
}

extension LegendRow where Icon == EmptyView {
    public init(color: Color, label: String, value: String) {
        self.init(color: color, label: label, value: value) { EmptyView() }
    }
}

/// The capsule tab bar at the top of the main window and the menu bar panel.
/// Each pill is a focusable button; Left and Right arrows move the selection, as in a segmented control.
public struct TabPills<Item: Hashable & Identifiable>: View {
    private let items: [Item]
    @Binding private var selection: Item
    private let title: (Item) -> String?
    private let symbol: (Item) -> String
    private let tint: (Item) -> Color
    private let solidSelection: Bool
    private let accessibilityTitle: ((Item) -> String)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiatesWithoutColor
    @Environment(\.appearsActive) private var appearsActive

    /// - Parameters:
    ///   - solidSelection: fill the selected item with its tint (menu bar panel) instead of a faint tint (main window).
    ///   - accessibilityTitle: the tooltip and VoiceOver name for items shown without a title.
    public init(_ items: [Item], selection: Binding<Item>, solidSelection: Bool = false, title: @escaping (Item) -> String?, symbol: @escaping (Item) -> String, tint: @escaping (Item) -> Color, accessibilityTitle: ((Item) -> String)? = nil) {
        self.items = items
        self._selection = selection
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.solidSelection = solidSelection
        self.accessibilityTitle = accessibilityTitle
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(items) { item in
                pill(item)
            }
        }
        .padding(3)
        .background(Palette.card, in: Capsule())
        .controlOutline(Capsule())
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: selection)
        .onMoveCommand(perform: move)
        .accessibilityElement(children: .contain)
    }

    private func pill(_ item: Item) -> some View {
        let isSelected = item == selection
        let visibleTitle = title(item)
        let name = visibleTitle ?? accessibilityTitle?(item) ?? ""
        // Like a system segmented control, the main window's selection turns grey while the window is inactive.
        let showsTint = solidSelection || appearsActive
        return Button {
            selection = item
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol(item)).font(Typography.tabSymbol)
                if let visibleTitle {
                    Text(visibleTitle)
                        .font(Typography.tabTitle)
                        .fontWeight(isSelected && differentiatesWithoutColor ? .bold : .medium)
                }
            }
            .foregroundStyle(pillForeground(item, isSelected: isSelected, showsTint: showsTint))
            .padding(.horizontal, visibleTitle == nil ? 0 : 12)
            .frame(maxWidth: visibleTitle == nil ? .infinity : nil)
            .frame(height: 28)
            .background {
                if isSelected {
                    if solidSelection {
                        Capsule().fill(LegibleTint(tint(item), on: .white))
                    } else {
                        Capsule().fill(showsTint ? tint(item).opacity(0.16) : Palette.cardHighlight)
                    }
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func pillForeground(_ item: Item, isSelected: Bool, showsTint: Bool) -> AnyShapeStyle {
        guard isSelected else { return AnyShapeStyle(Palette.ink2) }
        if solidSelection { return AnyShapeStyle(Color.white) }
        return showsTint ? AnyShapeStyle(LegibleTint(tint(item), wash: 0.16)) : AnyShapeStyle(Palette.ink)
    }

    private func move(_ direction: MoveCommandDirection) {
        guard let index = items.firstIndex(of: selection) else { return }
        switch direction {
        case .left where index > 0: selection = items[index - 1]
        case .right where index < items.count - 1: selection = items[index + 1]
        default: break
        }
    }
}

/// A plain grey rounded button, as used for "Open Tally" and "Stop".
public struct SoftButtonStyle: ButtonStyle {
    private let tint: Color?
    private let prominent: Bool

    public init(tint: Color? = nil, prominent: Bool = false) {
        self.tint = tint
        self.prominent = prominent
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.button)
            .foregroundStyle(foreground)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background {
                if prominent {
                    Capsule().fill(LegibleTint(tint ?? Palette.accent, on: .white))
                } else {
                    Capsule().fill(Palette.cardHighlight)
                }
            }
            .controlOutline(Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }

    private var foreground: AnyShapeStyle {
        if prominent { return AnyShapeStyle(Color.white) }
        guard let tint else { return AnyShapeStyle(Palette.ink) }
        return AnyShapeStyle(LegibleTint(tint, on: Palette.cardHighlight))
    }
}

/// Presents the standard "Quit X? / N processes will close." confirmation with Quit, Force Quit and Cancel.
/// Quit is the default button (Return) and Escape cancels.
public struct QuitConfirmation: ViewModifier {
    @Binding var request: QuitRequest?
    let onDone: () -> Void

    public func body(content: Content) -> some View {
        content.alert(
            request?.title ?? "",
            isPresented: Binding(get: { request != nil }, set: { if !$0 { request = nil } }),
            presenting: request
        ) { request in
            Button("Quit") { ProcessActions.quit(request); onDone() }
            Button("Force Quit", role: .destructive) { ProcessActions.forceQuit(request); onDone() }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            Text(request.message)
        }
    }
}

extension View {
    /// Ask before quitting. `onDone` runs after Quit or Force Quit, for example to resample.
    public func quitConfirmation(_ request: Binding<QuitRequest?>, onDone: @escaping () -> Void = {}) -> some View {
        modifier(QuitConfirmation(request: request, onDone: onDone))
    }
}
