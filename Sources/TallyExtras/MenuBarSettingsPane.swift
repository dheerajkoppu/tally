import SwiftUI
import TallyCore

extension MenuBarMetric {
    var symbol: String {
        switch self {
        case .cpu: TallyTab.cpu.symbol
        case .memory: TallyTab.memory.symbol
        case .gpu: TallyTab.gpu.symbol
        case .network: TallyTab.network.symbol
        case .temperature: Symbols.temperature
        case .battery: TallyTab.battery.symbol
        }
    }

    var tint: Color {
        switch self {
        case .cpu: Palette.accent
        case .memory: Palette.accent
        case .gpu: Palette.accent
        case .network: Palette.accent
        case .temperature: Palette.red
        case .battery: Palette.accent
        }
    }

    /// The short figure shown in the menu bar: "24%", "12.3 GB", "63°", "21 kB/s".
    func reading(_ snapshot: SystemSnapshot, unit: TemperatureUnit, memoryInGB: Bool) -> String {
        switch self {
        case .cpu: Format.percent(snapshot.cpu.totalPercent).text
        case .memory:
            memoryInGB ? Format.shortMemory(snapshot.memory.usedBytes).text : Format.percent(snapshot.memory.usedFraction * 100).text
        case .gpu: Format.percent(snapshot.gpu.utilizationPercent).text
        case .network: Format.rate(snapshot.network.downloadBytesPerSecond).text
        case .temperature: snapshot.sensors.cpuTemperatureCelsius.map { Format.temperature($0, unit: unit).text } ?? "–"
        case .battery: snapshot.battery.hasBattery ? Format.percent(snapshot.battery.percent).text : "AC"
        }
    }

    /// Recent values as fractions of the graph height.
    @MainActor
    func graphFractions(_ store: TallyStore, count: Int) -> [Double] {
        let live = store.live
        switch self {
        case .cpu: return live.recent(.cpu, count: count).map { $0 / 100 }
        case .memory:
            let total = Double(max(store.snapshot.memory.totalBytes, 1))
            return live.recent(.memory, count: count).map { $0 / total }
        case .gpu: return live.recent(.gpu, count: count).map { $0 / 100 }
        case .network:
            let values = live.recent(.networkIn, count: count)
            let top = max(values.max() ?? 0, 100_000)
            return values.map { $0 / top }
        case .temperature: return live.recent(.cpuTemperature, count: count).map { ($0 - 30) / 70 }
        case .battery: return live.recent(.battery, count: count).map { $0 / 100 }
        }
    }
}

public struct MenuBarSettingsPane: View {
    @ObservedObject private var settings = AppSettings.shared

    private static let metricLimit = 3
    private static let positions = ["Shown first", "Shown second", "Shown third"]

    public init() {}

    public var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.showInMenuBar) {
                    Text("Show in Menu Bar")
                    Text("You can also Command-drag the item out of the menu bar.")
                }
            } footer: {
                SettingsFootnote(AppPresenceNote.text)
            }

            Section {
                Picker("Style", selection: $settings.menuBarStyle) {
                    ForEach(MenuBarStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                MenuBarPreview(style: settings.menuBarStyle, metrics: settings.menuBarMetrics)
            } header: {
                Text("Menu Bar Item")
            }
            .disabled(!settings.showInMenuBar)

            Section {
                ForEach(MenuBarMetric.allCases) { metric in
                    let position = settings.menuBarMetrics.firstIndex(of: metric)
                    Toggle(isOn: binding(for: metric)) {
                        Label {
                            Text(metric.label)
                            if let position, position < Self.positions.count {
                                Text(Self.positions[position])
                            }
                        } icon: {
                            Image(systemName: metric.symbol)
                                .foregroundStyle(metric.tint)
                                .frame(width: 20)
                        }
                    }
                    .disabled(position == nil && settings.menuBarMetrics.count >= Self.metricLimit)
                }
            } header: {
                Text("Metrics")
            } footer: {
                SettingsFootnote(metricsHint)
            }
            .disabled(!settings.showInMenuBar)

            Section {
                Picker(selection: $settings.menuBarMemoryInGB) {
                    Text("Percentage").tag(false)
                    Text("Amount Used").tag(true)
                } label: {
                    Text("Show Memory As")
                    Text("Amount Used shows gigabytes, such as 12.3 GB.")
                }
            }
            .disabled(!settings.showInMenuBar || !settings.menuBarMetrics.contains(.memory))

            Section {
                Toggle(isOn: $settings.menuBarWarnings) {
                    Text("Warn When the Mac Is Under Strain")
                    Text("Shows a warning symbol instead while memory, CPU or heat runs high.")
                }
            }
            .disabled(!settings.showInMenuBar)
        }
        .settingsPaneLayout()
    }

    private var metricsHint: String {
        switch settings.menuBarStyle {
        case .icon: "The icon shows no figures. Pick what the other styles show, up to three."
        case .figure: "The figure shows the first metric you pick."
        case .graph: "The graph shows the first metric you pick."
        case .stacked: "Stacked shows up to three, in the order you pick them."
        }
    }

    /// On adds the metric at the end, up to three; off removes it unless it is the last one.
    private func binding(for metric: MenuBarMetric) -> Binding<Bool> {
        Binding(
            get: { settings.menuBarMetrics.contains(metric) },
            set: { isOn in
                var metrics = settings.menuBarMetrics
                if isOn, !metrics.contains(metric), metrics.count < Self.metricLimit {
                    metrics.append(metric)
                } else if !isOn, metrics.count > 1 {
                    metrics.removeAll { $0 == metric }
                }
                if metrics != settings.menuBarMetrics { settings.menuBarMetrics = metrics }
            }
        )
    }
}

/// A slice of the macOS menu bar with the Tally item drawn live in the chosen style.
struct MenuBarPreview: View {
    let style: MenuBarStyle
    let metrics: [MenuBarMetric]
    @ObservedObject private var store = TallyStore.shared
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: "applelogo")
                .font(.system(size: 13.5, weight: .medium))
                .padding(.trailing, 16)
            ViewThatFits(in: .horizontal) {
                appMenus(["File", "Edit", "View"])
                appMenus(["File", "Edit"])
                appMenus(["File"])
                appMenus([])
            }
            Spacer(minLength: 8)
            item
                .fixedSize()
                .padding(.trailing, 14)
            Image(systemName: "wifi")
                .font(.system(size: 12.5, weight: .semibold))
                .padding(.trailing, 13)
            if let battery = batterySymbol {
                Image(systemName: battery)
                    .font(.system(size: 13))
                    .padding(.trailing, 13)
            }
            // Refreshed with each sample, so the preview needs no clock of its own.
            Text(Date(), format: .dateTime.weekday(.abbreviated).hour().minute())
                .font(.system(size: 13).monospacedDigit())
                .fixedSize()
        }
        .foregroundStyle(Palette.ink)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(Palette.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.line, lineWidth: 1))
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: style)
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: metrics)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview of the menu bar item")
        .accessibilityValue(accessibilitySummary)
    }

    private var primary: MenuBarMetric { metrics.first ?? .cpu }

    private func appMenus(_ titles: [String]) -> some View {
        HStack(spacing: 13) {
            Text("Finder")
                .font(.system(size: 13, weight: .bold))
                .padding(.trailing, 1)
            ForEach(titles, id: \.self) { title in
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.ink2)
            }
        }
        .fixedSize()
    }

    private var item: some View {
        HStack(spacing: 6) {
            TallyStackShape()
                .fill(Palette.ink)
                .frame(width: 14, height: 14)
                .padding(.horizontal, 1)
            switch style {
            case .icon:
                EmptyView()
            case .figure:
                reading(primary)
            case .graph:
                MiniBars(fractions: primary.graphFractions(store, count: 9))
                    .fill(Palette.ink)
                    .frame(width: 26, height: 13)
                reading(primary)
            case .stacked:
                HStack(spacing: 7) {
                    ForEach(Array(metrics.prefix(3))) { metric in
                        VStack(spacing: -3) {
                            Text(metric.shortLabel)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Palette.ink2)
                            Text(metric.reading(store.snapshot, unit: settings.temperatureUnit, memoryInGB: settings.menuBarMemoryInGB))
                                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(Palette.cardHighlight, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func reading(_ metric: MenuBarMetric) -> some View {
        Text(metric.reading(store.snapshot, unit: settings.temperatureUnit, memoryInGB: settings.menuBarMemoryInGB))
            .font(.system(size: 13, weight: .medium).monospacedDigit())
    }

    private var accessibilitySummary: String {
        let shown: [MenuBarMetric] = switch style {
        case .icon: []
        case .figure, .graph: [primary]
        case .stacked: Array(metrics.prefix(3))
        }
        let readings = shown.map { "\($0.label) \($0.reading(store.snapshot, unit: settings.temperatureUnit, memoryInGB: settings.menuBarMemoryInGB))" }
        return ([style.label] + readings).joined(separator: ", ")
    }

    private var batterySymbol: String? {
        let battery = store.snapshot.battery
        guard battery.hasBattery else { return nil }
        if battery.isCharging { return "battery.100percent.bolt" }
        switch battery.percent {
        case 88...: return "battery.100percent"
        case 63..<88: return "battery.75percent"
        case 38..<63: return "battery.50percent"
        case 13..<38: return "battery.25percent"
        default: return "battery.0percent"
        }
    }
}

/// The tiny bar graph inside the menu bar item, as one path.
private struct MiniBars: Shape {
    let fractions: [Double]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let count = max(fractions.count, 1)
        let slot = rect.width / CGFloat(count)
        let barWidth = max(1.5, slot - 1)
        for (index, fraction) in fractions.enumerated() {
            let clamped = min(max(fraction.isFinite ? fraction : 0, 0), 1)
            let height = max(2, rect.height * clamped)
            let bar = CGRect(x: rect.minX + CGFloat(index) * slot, y: rect.maxY - height, width: barWidth, height: height)
            path.addRoundedRect(in: bar, cornerSize: CGSize(width: 0.6, height: 0.6))
        }
        return path
    }
}
