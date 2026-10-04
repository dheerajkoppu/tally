import SwiftUI
import TallyCore

/// Every metric on one screen as a grid of small cards, then the busiest apps.
struct OverviewPanel: View {
    let onSelect: (TallyTab) -> Void

    @ObservedObject private var store = TallyStore.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        let snapshot = store.snapshot
        VStack(spacing: 0) {
            PanelSectionTitle("Overview") {
                if snapshot.uptime > 0 {
                    HStack(spacing: 5) {
                        Image(systemName: Symbols.clock)
                            .font(.system(size: 10.5, weight: .regular))
                        Text(Format.uptime(snapshot.uptime))
                            .font(.system(size: 11))
                            .monospacedDigit()
                    }
                    .panelSecondaryText()
                    .help("Time since this Mac started")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Format.uptime(snapshot.uptime))
                }
            }
            VStack(spacing: 8) {
                if !store.alerts.isEmpty {
                    PanelAlertsCard(alerts: Array(store.alerts.prefix(2)))
                }
                HStack(spacing: 8) {
                    cpuCard(snapshot.cpu)
                    memoryCard(snapshot.memory)
                }
                HStack(spacing: 8) {
                    networkCard(snapshot.network)
                    diskCard(snapshot.disk)
                }
                HStack(spacing: 8) {
                    gpuCard(snapshot)
                    if snapshot.battery.hasBattery {
                        batteryCard(snapshot.battery)
                    } else {
                        powerCard(snapshot.battery)
                    }
                }
                sensorRow(snapshot.sensors)
                BusiestCard(apps: store.topApps(by: .cpu, limit: 3))
            }
            .padding(.top, 9)
        }
    }

    private func cpuCard(_ cpu: CPUStats) -> some View {
        MiniCard(tab: .cpu, title: "CPU", figure: Format.percent(cpu.totalPercent), detail: "load \(String(format: "%.2f", cpu.loadAverage.first ?? 0))", onSelect: onSelect) {
            BarSparkline(cpu.perCorePercent, maxValue: 100, slot: .fill)
        }
    }

    private func memoryCard(_ memory: MemoryStats) -> some View {
        let total = Double(max(memory.totalBytes, 1))
        return MiniCard(tab: .memory, title: "Memory", figure: Format.memory(memory.usedBytes), detail: "of \(PanelFormat.memoryCapacity(memory.totalBytes))", onSelect: onSelect) {
            RingGauge([
                RingGauge.Segment(Double(memory.appBytes) / total, color: Palette.memoryApp),
                RingGauge.Segment(Double(memory.wiredBytes) / total, color: Palette.memoryWired),
                RingGauge.Segment(Double(memory.compressedBytes) / total, color: Palette.memoryCompressed),
            ])
            .frame(width: PanelMetrics.miniVisualSize.height)
        }
    }

    private func networkCard(_ network: NetworkStats) -> some View {
        let values = store.live.networkIn.suffix(PanelMetrics.chartSamples)
        return MiniCard(tab: .network, title: "Network", figure: Format.rate(network.downloadBytesPerSecond), detail: "↑ \(Format.rate(network.uploadBytesPerSecond).text)", accessibilityDetail: "uploading \(Format.rate(network.uploadBytesPerSecond).text)", onSelect: onSelect) {
            PanelBarChart(values, maxValue: PanelBarChart.scale(values, floor: 10_000))
        }
    }

    private func diskCard(_ disk: DiskStats) -> some View {
        let usedFraction = disk.totalBytes == 0 ? 0 : Double(disk.usedBytes) / Double(disk.totalBytes)
        return MiniCard(tab: .disk, title: "Disk", figure: Format.storage(disk.freeBytes), detail: "free", onSelect: onSelect) {
            RingGauge(usedFraction)
                .frame(width: PanelMetrics.miniVisualSize.height)
        }
    }

    private func gpuCard(_ snapshot: SystemSnapshot) -> some View {
        let values = store.live.gpu.suffix(PanelMetrics.chartSamples)
        return MiniCard(tab: .gpu, title: "GPU", figure: Format.percent(snapshot.gpu.utilizationPercent), detail: "\(Format.memory(snapshot.gpu.memoryUsedBytes).text) in use", onSelect: onSelect) {
            PanelBarChart(values, maxValue: 100)
        }
    }

    private func batteryCard(_ battery: BatteryStats) -> some View {
        let isLow = battery.percent <= 10 && !battery.isCharging
        return MiniCard(tab: .battery, title: "Battery", figure: Format.percent(battery.percent), detail: BatteryText.remaining(battery), onSelect: onSelect) {
            BatteryGlyph(level: battery.percent / 100, isCharging: battery.isCharging, tint: isLow ? Palette.red : Palette.accent)
                .frame(width: 24)
        }
    }

    /// Macs without a battery show what the whole Mac draws in the battery's place.
    private func powerCard(_ battery: BatteryStats) -> some View {
        let values = store.live.power.suffix(PanelMetrics.chartSamples)
        return MiniCard(tab: .battery, title: "Power", symbol: Symbols.power, figure: Format.power(battery.powerDrawWatts), detail: "whole Mac", onSelect: onSelect) {
            PanelBarChart(values, maxValue: PanelBarChart.scale(values, floor: 10))
        }
    }

    /// CPU temperature beside the fans, or beside a connected device on a Mac without fans.
    @ViewBuilder
    private func sensorRow(_ sensors: SensorStats) -> some View {
        let temperature = sensors.cpuTemperatureCelsius.flatMap { $0 > 0 ? $0 : nil }
        let fastestFan = sensors.fans.max { $0.rpm < $1.rpm }
        let device = sensors.peripheralBatteries.min { $0.percent < $1.percent }
        if temperature != nil || fastestFan != nil || device != nil {
            HStack(spacing: 8) {
                if let temperature {
                    let range = TemperatureRange(celsius: temperature)
                    MiniCard(tab: .sensors, title: "Temperature", figure: Format.temperature(temperature, unit: settings.temperatureUnit), detail: "CPU, \(range.label.lowercased())", onSelect: onSelect) {
                        ThermometerGlyph(level: TemperatureRange.level(temperature), tint: range.tint)
                            .frame(width: 30)
                    }
                }
                if let fan = fastestFan {
                    let span = fan.maxRPM - fan.minRPM
                    let isSpinning = fan.rpm >= 1
                    MiniCard(
                        tab: .sensors,
                        title: sensors.fans.count == 1 ? "Fan" : "Fans",
                        symbol: Symbols.fan,
                        figure: isSpinning ? Figure(PanelFormat.integer((fan.rpm / 10).rounded() * 10), "rpm") : Figure("Off", ""),
                        detail: sensors.fans.count == 1 ? "fan speed" : "fastest of \(sensors.fans.count)",
                        onSelect: onSelect
                    ) {
                        FanGauge(fraction: isSpinning && span > 0 ? min(max((fan.rpm - fan.minRPM) / span, 0.04), 1) : 0)
                            .frame(width: PanelMetrics.miniVisualSize.height)
                    }
                } else if let device {
                    MiniCard(tab: .sensors, title: "Devices", symbol: device.kind.symbol, figure: Format.percent(device.percent), detail: device.name, onSelect: onSelect) {
                        LevelTile(level: device.percent / 100, symbol: device.kind.symbol, tint: device.percent <= 20 ? Palette.red : Palette.accent)
                            .frame(width: 34)
                    }
                }
            }
        }
    }
}

/// One of the small cards: a grey title, a bold figure over a quiet detail line, and a gauge or chart on the right.
/// Clicking it opens that section in the panel.
private struct MiniCard<Visual: View>: View {
    let tab: TallyTab
    let title: String
    let symbol: String
    let figure: Figure
    let detail: String
    let accessibilityDetail: String
    let onSelect: (TallyTab) -> Void
    let visual: Visual

    @State private var isHovered = false
    @Environment(\.colorSchemeContrast) private var contrast

    init(tab: TallyTab, title: String, symbol: String? = nil, figure: Figure, detail: String, accessibilityDetail: String? = nil, onSelect: @escaping (TallyTab) -> Void, @ViewBuilder visual: () -> Visual) {
        self.tab = tab
        self.title = title
        self.symbol = symbol ?? tab.symbol
        self.figure = figure
        self.detail = detail
        self.accessibilityDetail = accessibilityDetail ?? detail
        self.onSelect = onSelect
        self.visual = visual()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PanelMetrics.cardRadius, style: .continuous)
        Button {
            onSelect(tab)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 5) {
                    Image(systemName: symbol)
                        .font(.system(size: 10.5, weight: .medium))
                        .frame(width: 14, alignment: .leading)
                    Text(title)
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .panelSecondaryText()
                .frame(height: 15)
                Spacer(minLength: 0)
                HStack(alignment: .bottom, spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        PanelFigure(figure, size: 21)
                        Text(detail)
                            .font(.system(size: 11, weight: .medium))
                            .monospacedDigit()
                            .panelSecondaryText()
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .layoutPriority(1)
                    Spacer(minLength: 0)
                    visual
                        .frame(maxWidth: PanelMetrics.miniVisualSize.width)
                        .frame(height: PanelMetrics.miniVisualSize.height)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 11)
            .padding(.top, 9)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 84)
            .background(isHovered ? Palette.cardHighlight : Palette.card, in: shape)
            .overlay {
                if contrast == .increased {
                    shape.strokeBorder(Palette.ink3, lineWidth: 1)
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Show \(title)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(figure.text), \(accessibilityDetail)")
        .accessibilityHint("Shows the \(tab.title) section")
        .accessibilityAddTraits(.isButton)
    }
}

/// The three apps using the most CPU right now, with their figures in bold and no meters.
private struct BusiestCard: View {
    let apps: [AppUsage]

    var body: some View {
        if !apps.isEmpty {
            PanelCard(horizontal: 12, top: 6, bottom: 8) {
                PanelListTitle(title: "Busiest Apps", height: 25)
                ForEach(apps.indices, id: \.self) { rank in
                    let app = apps[rank]
                    PanelAppRow(app: app, fraction: 0, value: Format.precisePercent(app.cpuPercent), tint: Palette.accent, valueWidth: 66, showsMeter: false) {
                        PanelActions.openMainWindow(.cpu, inspecting: app.id)
                    }
                    .equatable()
                }
            }
        }
    }
}

/// "Worth a Look": apps that have been misbehaving, most recent first.
private struct PanelAlertsCard: View {
    let alerts: [AlertItem]

    var body: some View {
        PanelCard(horizontal: 12, top: 10, bottom: 10) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.caution)
                Text("Worth a Look")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Palette.ink)
            }
            .padding(.bottom, 4)
            ForEach(alerts) { alert in
                PanelAlertRow(alert: alert)
            }
        }
    }
}

private struct PanelAlertRow: View {
    let alert: AlertItem

    @State private var isHovered = false

    private var tab: TallyTab {
        switch alert.kind {
        case .highCPU: .cpu
        case .growingMemory: .memory
        case .heavyDisk: .disk
        case .heavyNetwork: .network
        }
    }

    var body: some View {
        HStack(spacing: 9) {
            Button {
                PanelActions.openMainWindow(tab, inspecting: alert.appID)
            } label: {
                HStack(spacing: 9) {
                    AppIconView(bundlePath: alert.bundlePath, size: 22)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(alert.title)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Palette.ink)
                        Text(alert.detail)
                            .font(.system(size: 11.5))
                            .panelSecondaryText()
                    }
                    .lineLimit(1)
                    .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show \(alert.appName) in Tally")
            .accessibilityElement(children: .combine)

            Button {
                TallyStore.shared.dismiss(alert)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(Palette.ink2)
                    .frame(width: 20, height: 20)
                    .background(Palette.cardHighlight.opacity(isHovered ? 1 : 0), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .help("Dismiss")
            .accessibilityLabel("Dismiss \(alert.title)")
        }
        .padding(.vertical, 4)
    }
}

enum BatteryText {
    /// "3h 00m left", "1h 10m to full", "Plugged in".
    static func remaining(_ battery: BatteryStats) -> String {
        if battery.isCharging {
            if let minutes = battery.timeRemainingMinutes, minutes > 0 { return "\(Format.duration(minutes: minutes)) to full" }
            return "Charging"
        }
        if battery.isPluggedIn {
            return battery.percent >= 99.5 ? "Charged" : "Not charging"
        }
        if let minutes = battery.timeRemainingMinutes, minutes > 0 { return "\(Format.duration(minutes: minutes)) left" }
        return "Calculating…"
    }
}
