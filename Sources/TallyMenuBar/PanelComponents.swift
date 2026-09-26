import SwiftUI
import AppKit
import TallyCore

enum PanelMetrics {
    static let width: CGFloat = 370
    static let padding: CGFloat = 12
    static let cardRadius: CGFloat = 14
    static let cardPadding: CGFloat = 18
    static let appRowHeight: CGFloat = 27
    static let detailRowHeight: CGFloat = 24.5
    static let meterWidth: CGFloat = 56
    static let chartSize = CGSize(width: 112, height: 33)
    /// The line chart along the bottom of an Overview card.
    static let miniChartHeight: CGFloat = 25
    static let rowFont = Font.system(size: 12.5)
    static let valueFont = Font.system(size: 12.5, weight: .medium).monospacedDigit()
    static let emphasizedValueFont = Font.system(size: 13, weight: .semibold).monospacedDigit()
    static let chartSamples = 90
}

/// Actions the panel asks of whoever hosts it. The status item controller installs `dismiss`.
@MainActor
enum PanelActions {
    static var dismiss: () -> Void = {}
    /// The tab the panel opens on: the one shown last, or the one named after --open-panel.
    static var lastTab: TallyTab = {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--open-panel"), index + 1 < arguments.count else { return .overview }
        return TallyTab(rawValue: arguments[index + 1]) ?? .overview
    }()
    /// True while an inline confirmation in the panel handles the Escape key itself.
    static var isConfirming = false

    static func openMainWindow(_ tab: TallyTab, inspecting appID: String? = nil) {
        dismiss()
        AppRouter.shared.open(tab, inspecting: appID)
    }

    static func openSettings() {
        dismiss()
        AppRouter.shared.showSettings()
    }

    static func openFanControl() {
        dismiss()
        AppRouter.shared.showMainWindow()
        AppRouter.shared.isFanControlPresented = true
    }
}

/// Secondary text and hairlines, stronger when Increase Contrast is on.
private struct PanelSecondaryText: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.foregroundStyle(contrast == .increased ? Palette.ink : Palette.ink2)
    }
}

extension View {
    func panelSecondaryText() -> some View {
        modifier(PanelSecondaryText())
    }
}

/// The grey rounded surface every panel section sits on.
struct PanelCard<Content: View>: View {
    private let horizontalPadding: CGFloat
    private let topPadding: CGFloat
    private let bottomPadding: CGFloat
    private let content: Content

    @Environment(\.colorSchemeContrast) private var contrast

    init(horizontal: CGFloat = PanelMetrics.cardPadding, top: CGFloat = 9.5, bottom: CGFloat = 11, @ViewBuilder content: () -> Content) {
        self.horizontalPadding = horizontal
        self.topPadding = top
        self.bottomPadding = bottom
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PanelMetrics.cardRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.horizontal, horizontalPadding)
            .padding(.top, topPadding)
            .padding(.bottom, bottomPadding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(Palette.card, in: shape)
            .overlay {
                if contrast == .increased {
                    shape.strokeBorder(Palette.ink3, lineWidth: 1)
                }
            }
    }
}

/// "OVERVIEW", in spaced caps, with an optional accessory on the right.
struct PanelSectionTitle<Accessory: View>: View {
    private let title: String
    private let accessory: Accessory

    init(_ title: String, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.8)
                .panelSecondaryText()
                .accessibilityLabel(title)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            accessory
        }
        .lineLimit(1)
        .padding(.horizontal, 6)
        .frame(height: 16)
    }
}

extension PanelSectionTitle where Accessory == EmptyView {
    init(_ title: String) {
        self.init(title) { EmptyView() }
    }
}

/// A hairline that reaches a little past the card's content, as in the reference.
struct PanelDivider: View {
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Rectangle()
            .fill(contrast == .increased ? Palette.ink3 : Palette.line)
            .frame(height: 1)
            .padding(.horizontal, -6)
            .accessibilityHidden(true)
    }
}

/// "Top Apps", "Running Now": the grey title over a list inside a card.
struct PanelListTitle<Accessory: View>: View {
    private let title: String
    private let height: CGFloat
    private let accessory: Accessory

    init(title: String, height: CGFloat = PanelMetrics.appRowHeight, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.height = height
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(PanelMetrics.rowFont)
                .panelSecondaryText()
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            accessory
        }
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
    }
}

extension PanelListTitle where Accessory == EmptyView {
    init(title: String, height: CGFloat = PanelMetrics.appRowHeight) {
        self.init(title: title, height: height) { EmptyView() }
    }
}

/// "User ........ 12%", optionally with a colour dot before the label.
struct PanelDetailRow<Value: View>: View {
    private let label: String
    private let dot: Color?
    private let value: Value

    init(_ label: String, dot: Color? = nil, @ViewBuilder value: () -> Value) {
        self.label = label
        self.dot = dot
        self.value = value()
    }

    var body: some View {
        HStack(spacing: 8) {
            if let dot {
                Circle().fill(dot).frame(width: 7.5, height: 7.5)
            }
            Text(label).font(PanelMetrics.rowFont).panelSecondaryText()
            Spacer(minLength: 12)
            value.font(PanelMetrics.valueFont).foregroundStyle(Palette.ink)
        }
        .lineLimit(1)
        .frame(height: PanelMetrics.detailRowHeight)
        .accessibilityElement(children: .combine)
    }
}

extension PanelDetailRow where Value == Text {
    init(_ label: String, value: String, dot: Color? = nil) {
        self.init(label, dot: dot) { Text(value) }
    }
}

/// A small tinted capsule, tighter than `Pill`, for ports and pressure.
struct PanelTag: View {
    let text: String
    let tint: Color
    var fontSize: CGFloat = 11

    var body: some View {
        Text(text)
            .font(.system(size: fontSize, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(tint)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, fontSize * 0.55)
            .padding(.vertical, 0.5)
            .background(tint.opacity(0.16), in: Capsule())
    }
}

/// A large rounded number with a smaller, lighter unit, set as one line of text: "69 %", "53.88 GB".
/// The panel's lighter take on `BigFigure`: one text to lay out, never scaled down, so an update measures it once.
struct PanelFigure: View, Equatable {
    private let figure: Figure
    private let size: CGFloat

    init(_ figure: Figure, size: CGFloat) {
        self.figure = figure
        self.size = size
    }

    var body: some View {
        let value = Text(figure.value)
            .font(Typography.figure(size))
            .tracking(-size * 0.02)
            .foregroundStyle(Palette.ink)
        let text = figure.unit.isEmpty
            ? value
            : value + Text(" " + figure.unit).font(Typography.figureUnit(size * 0.5)).foregroundStyle(Palette.ink2)
        text
            .lineLimit(1)
            .fixedSize()
    }
}

/// A thin capsule meter on a faint track of the same tint. Drawn as two shapes and never animated,
/// so a new sample costs one redraw.
struct PanelMeter: View, Equatable {
    let fraction: Double
    let tint: Color
    let height: CGFloat

    init(_ fraction: Double, tint: Color, height: CGFloat = 6) {
        self.fraction = Self.quantized(fraction)
        self.tint = tint
        self.height = height
    }

    /// Clamped to 0...1 in steps of half a percent, finer than any meter here can show.
    static func quantized(_ fraction: Double) -> Double {
        guard fraction.isFinite else { return 0 }
        return (min(max(fraction, 0), 1) * 200).rounded() / 200
    }

    var body: some View {
        MeterFill(fraction: fraction, minimumWidth: fraction > 0 ? height : 0)
            .fill(tint)
            .background(Capsule().fill(tint.opacity(0.14)))
            .frame(height: height)
            .accessibilityHidden(true)
    }
}

private struct MeterFill: Shape {
    var fraction: Double
    var minimumWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        let width = min(rect.width, max(minimumWidth, rect.width * fraction))
        guard width > 0 else { return Path() }
        return Capsule().path(in: CGRect(x: rect.minX, y: rect.minY, width: width, height: rect.height))
    }
}

/// An app with its icon, a small meter (or none) and a value. Clicking it opens the app in the main window.
/// Equatable on what it shows, so rows whose rounded figures did not change are not redrawn.
struct PanelAppRow: View, Equatable {
    private let appID: String
    private let name: String
    private let icon: AppIconView
    private let fraction: Double
    private let value: String
    private let tint: Color
    private let valueWidth: CGFloat
    private let showsMeter: Bool
    private let action: () -> Void

    @State private var isHovered = false

    init(app: AppUsage, fraction: Double, value: String, tint: Color, valueWidth: CGFloat = 72, showsMeter: Bool = true, action: @escaping () -> Void) {
        self.appID = app.id
        self.name = app.name
        self.icon = AppIconView(app, size: 18)
        self.fraction = PanelMeter.quantized(fraction)
        self.value = value
        self.tint = tint
        self.valueWidth = valueWidth
        self.showsMeter = showsMeter
        self.action = action
    }

    nonisolated static func == (lhs: PanelAppRow, rhs: PanelAppRow) -> Bool {
        lhs.appID == rhs.appID && lhs.name == rhs.name && lhs.fraction == rhs.fraction && lhs.value == rhs.value
            && lhs.tint == rhs.tint && lhs.valueWidth == rhs.valueWidth && lhs.showsMeter == rhs.showsMeter
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                icon
                    .padding(.trailing, 8)
                    .accessibilityHidden(true)
                Text(name)
                    .font(PanelMetrics.rowFont)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 10)
                if showsMeter {
                    PanelMeter(fraction, tint: tint, height: 4)
                        .frame(width: PanelMetrics.meterWidth)
                }
                Text(value)
                    .font(showsMeter ? PanelMetrics.valueFont : PanelMetrics.emphasizedValueFont)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .frame(width: valueWidth, alignment: .trailing)
            }
            .frame(height: PanelMetrics.appRowHeight)
            .background {
                if isHovered {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Palette.raised)
                        .padding(.horizontal, -7)
                        .padding(.vertical, 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Show \(name) in Tally")
        .accessibilityLabel(name)
        .accessibilityValue(value)
        .accessibilityHint("Opens Tally with this app selected")
    }
}

/// Top apps for one metric: a divider, a title and up to five rows.
struct PanelTopApps: View {
    let title: String
    let tab: TallyTab
    let metric: AppMetric
    let apps: [AppUsage]
    let tint: Color
    /// The value a full meter stands for at least, so small figures do not fill the meter.
    var scaleFloor: Double = 0
    let format: (Double) -> String

    var body: some View {
        if !apps.isEmpty {
            let scale = max(apps.first?.value(for: metric) ?? 0, scaleFloor, .leastNonzeroMagnitude)
            VStack(alignment: .leading, spacing: 0) {
                PanelDivider()
                    .padding(.top, 10)
                    .padding(.bottom, 3)
                PanelListTitle(title: title, height: 26)
                // Rows are keyed by rank, so a new order updates them in place instead of inserting and removing rows.
                ForEach(apps.indices, id: \.self) { rank in
                    let app = apps[rank]
                    let value = app.value(for: metric)
                    PanelAppRow(app: app, fraction: value / scale, value: format(value), tint: tint) {
                        PanelActions.openMainWindow(tab, inspecting: app.id)
                    }
                    .equatable()
                }
            }
        }
    }
}

/// A line over a flat tinted fill, sized by its frame. Built from shapes rather than a canvas,
/// so an update redraws a path instead of re-rasterizing a layer.
struct PanelAreaChart: View, Equatable {
    private let fractions: [Double]
    private let tint: Color
    private let lineWidth: CGFloat
    private let summary: String?

    /// - Parameter summary: what VoiceOver reads for the chart; nil hides it.
    init<Values: Collection>(_ values: Values, tint: Color, maxValue: Double, lineWidth: CGFloat = 1.5, summary: String? = nil) where Values.Element == Double {
        let top = max(maxValue, .leastNonzeroMagnitude)
        var fractions = values.map { value in min(max(value.isFinite ? value / top : 0, 0), 1) }
        if fractions.count == 1 { fractions.append(fractions[0]) }
        self.fractions = fractions
        self.tint = tint
        self.lineWidth = lineWidth
        self.summary = summary
    }

    /// 12% of headroom over the largest value, never less than `floor`.
    static func scale<Values: Collection>(_ values: Values, floor: Double) -> Double where Values.Element == Double {
        max((values.max() ?? 0) * 1.12, floor)
    }

    var body: some View {
        ZStack {
            AreaChartShape(fractions: fractions, inset: lineWidth / 2, closed: true)
                .fill(tint.opacity(0.15))
            AreaChartShape(fractions: fractions, inset: lineWidth / 2, closed: false)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
        .accessibilityElement()
        .accessibilityLabel(summary ?? "")
        .accessibilityHidden(summary == nil)
    }
}

private struct AreaChartShape: Shape {
    var fractions: [Double]
    var inset: CGFloat
    var closed: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard fractions.count > 1 else { return path }
        let step = rect.width / CGFloat(fractions.count - 1)
        let usableHeight = rect.height - inset * 2
        let points = fractions.enumerated().map { index, fraction in
            CGPoint(x: rect.minX + CGFloat(index) * step, y: rect.minY + inset + usableHeight * (1 - fraction))
        }
        if closed {
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLines(points)
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.closeSubpath()
        } else {
            path.addLines(points)
        }
        return path
    }
}

/// What VoiceOver reads for a live chart: "CPU, 12% now, peak 31%, last 7 min".
enum PanelChartSummary {
    @MainActor
    static func text<Values: Collection>(_ name: String, current: String, values: Values, format: (Double) -> String) -> String where Values.Element == Double {
        let dates = TallyStore.shared.live.dates.suffix(values.count)
        let span = (dates.last ?? .distantPast).timeIntervalSince(dates.first ?? .distantPast)
        return "\(name), \(current) now, peak \(format(values.max() ?? 0)), last \(Format.span(span))"
    }
}

/// The header of a metric card: a big figure and caption on the left, a chart or meter on the right.
struct PanelMetricHeader<FigureContent: View, Caption: View, Trailing: View>: View {
    private let figure: FigureContent
    private let caption: Caption
    private let trailing: Trailing

    init(@ViewBuilder figure: () -> FigureContent, @ViewBuilder caption: () -> Caption, @ViewBuilder trailing: () -> Trailing) {
        self.figure = figure()
        self.caption = caption()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 5.5) {
                figure
                caption
                    .font(.system(size: 11))
                    .panelSecondaryText()
                    .lineLimit(1)
            }
            .layoutPriority(1)
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            trailing
        }
    }
}

/// The footer's plain text buttons: secondary text that darkens under the pointer, with no button shape.
struct PanelTextButtonStyle: ButtonStyle {
    static let horizontalPadding: CGFloat = 4

    func makeBody(configuration: Configuration) -> some View {
        PanelTextButtonBody(configuration: configuration)
    }

    private struct PanelTextButtonBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var isHovered = false
        @Environment(\.colorSchemeContrast) private var contrast

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
            configuration.label
                .font(PanelMetrics.rowFont)
                .foregroundStyle(isHovered || configuration.isPressed || contrast == .increased ? Palette.ink : Palette.ink2)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, PanelTextButtonStyle.horizontalPadding)
                .frame(maxHeight: .infinity)
                .opacity(configuration.isPressed ? 0.7 : 1)
                .contentShape(shape)
                .contentShape(.focusEffect, shape)
                .onHover { isHovered = $0 }
        }
    }
}

enum PanelFormat {
    /// "64 GB" for whole sizes such as installed RAM, "53.88 GB" otherwise.
    static func memoryCapacity(_ bytes: UInt64) -> String {
        let gibibytes = Double(bytes) / 1_073_741_824
        if gibibytes >= 1, abs(gibibytes - gibibytes.rounded()) < 0.01 {
            return "\(Int(gibibytes.rounded())) GB"
        }
        return Format.memory(bytes).text
    }

    private static let integerFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    /// "3,460", with one formatter kept for the life of the app.
    static func integer(_ value: Double) -> String {
        integerFormatter.string(from: NSNumber(value: value)) ?? String(Int(value))
    }

    /// "2,317 rpm", or "2,317 · 2,290 rpm" for two fans.
    static func fanSpeeds(_ fans: [FanReading]) -> String {
        fans.map { integer($0.rpm) }.joined(separator: " · ") + " rpm"
    }
}
