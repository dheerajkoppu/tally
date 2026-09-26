import SwiftUI
import TallyCore

/// Every metric on one screen, then the busiest apps.
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
                    cpuCard(snapshot)
                    memoryCard(snapshot)
                }
                HStack(spacing: 8) {
                    networkCard(snapshot)
                    diskCard(snapshot)
                }
                HStack(spacing: 8) {
                    gpuCard(snapshot)
                    if snapshot.battery.hasBattery {
                        batteryCard(snapshot.battery)
                    } else {
                        temperatureCard(snapshot.sensors)
                    }
                }
                BusiestCard(apps: store.topApps(by: .cpu, limit: 3))
            }
            .padding(.top, 9)
        }
    }

    private func cpuCard(_ snapshot: SystemSnapshot) -> some View {
        let values = store.live.cpu.suffix(PanelMetrics.chartSamples)
        return MiniCard(tab: .cpu, title: "CPU", onSelect: onSelect) {
            FigureLine(Format.percent(snapshot.cpu.totalPercent)) {
                Text(verbatim: "load \(String(format: "%.2f", snapshot.cpu.loadAverage.first ?? 0))")
            }
        } footer: {
            PanelAreaChart(values, tint: Palette.cpu, maxValue: 100, summary: PanelChartSummary.text("CPU", current: Format.percent(snapshot.cpu.totalPercent).text, values: values) { Format.percent($0).text })
                .frame(height: PanelMetrics.miniChartHeight)
        }
    }

    private func memoryCard(_ snapshot: SystemSnapshot) -> some View {
        let memory = snapshot.memory
        return MiniCard(tab: .memory, title: "Memory", onSelect: onSelect) {
            FigureLine(Format.memory(memory.usedBytes)) {
                Text(verbatim: "of \(PanelFormat.memoryCapacity(memory.totalBytes))")
            }
        } footer: {
            let values = store.live.memoryUsed.suffix(PanelMetrics.chartSamples)
            PanelAreaChart(values, tint: Palette.memory, maxValue: Double(max(memory.totalBytes, 1)), summary: PanelChartSummary.text("Memory", current: Format.memory(memory.usedBytes).text, values: values) { Format.memory(UInt64(max($0, 0))).text })
                .frame(height: PanelMetrics.miniChartHeight)
        }
    }

    private func networkCard(_ snapshot: SystemSnapshot) -> some View {
        let network = snapshot.network
        let values = store.live.networkIn.suffix(PanelMetrics.chartSamples)
        return MiniCard(tab: .network, title: "Network", onSelect: onSelect) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Image(systemName: Symbols.download)
                    .font(.system(size: 10, weight: .medium))
                    .panelSecondaryText()
                    .accessibilityLabel("Download")
                PanelFigure(Format.rate(network.downloadBytesPerSecond), size: 21)
                    .padding(.leading, 6)
                    .layoutPriority(1)
                Spacer(minLength: 4)
                HStack(spacing: 3) {
                    Image(systemName: Symbols.upload)
                        .font(.system(size: 9.5, weight: .medium))
                        .accessibilityLabel("Upload")
                    Text(Format.rate(network.uploadBytesPerSecond).text)
                        .truncationMode(.tail)
                }
                .font(.system(size: 11))
                .panelSecondaryText()
                .lineLimit(1)
            }
        } footer: {
            PanelAreaChart(values, tint: Palette.network, maxValue: PanelAreaChart.scale(values, floor: 10_000), summary: PanelChartSummary.text("Download", current: Format.rate(network.downloadBytesPerSecond).text, values: values) { Format.rate($0).text })
                .frame(height: PanelMetrics.miniChartHeight)
        }
    }

    private func diskCard(_ snapshot: SystemSnapshot) -> some View {
        let disk = snapshot.disk
        let usedFraction = disk.totalBytes == 0 ? 0 : Double(disk.usedBytes) / Double(disk.totalBytes)
        return MiniCard(tab: .disk, title: "Disk", onSelect: onSelect) {
            FigureLine(Format.storage(disk.freeBytes)) {
                Text("free")
            }
        } footer: {
            PanelMeter(usedFraction, tint: Palette.disk, height: 6)
        }
    }

    private func gpuCard(_ snapshot: SystemSnapshot) -> some View {
        let values = store.live.gpu.suffix(PanelMetrics.chartSamples)
        return MiniCard(tab: .gpu, title: "GPU", onSelect: onSelect) {
            FigureLine(Format.percent(snapshot.gpu.utilizationPercent)) {
                EmptyView()
            }
        } footer: {
            PanelAreaChart(values, tint: Palette.gpu, maxValue: 100, summary: PanelChartSummary.text("GPU", current: Format.percent(snapshot.gpu.utilizationPercent).text, values: values) { Format.percent($0).text })
                .frame(height: PanelMetrics.miniChartHeight)
        }
    }

    private func batteryCard(_ battery: BatteryStats) -> some View {
        MiniCard(tab: .battery, title: "Battery", onSelect: onSelect) {
            FigureLine(Format.percent(battery.percent)) {
                Text(BatteryText.remaining(battery))
            }
        } footer: {
            PanelMeter(battery.percent / 100, tint: battery.percent <= 10 && !battery.isCharging ? Palette.red : Palette.battery, height: 6)
        }
    }

    /// Macs without a battery show the CPU temperature in the battery's place, or the power draw without a sensor.
    @ViewBuilder
    private func temperatureCard(_ sensors: SensorStats) -> some View {
        if let celsius = sensors.cpuTemperatureCelsius {
            let values = store.live.cpuTemperature.suffix(PanelMetrics.chartSamples)
            let unit = settings.temperatureUnit
            let current = Format.temperature(celsius, unit: unit).text
            MiniCard(tab: .battery, title: "Temperature", symbol: Symbols.temperature, tint: Palette.red, onSelect: onSelect) {
                FigureLine(Figure(current, "")) {
                    Text("CPU")
                }
            } footer: {
                PanelAreaChart(values, tint: Palette.red, maxValue: PanelAreaChart.scale(values, floor: 100), summary: PanelChartSummary.text("CPU temperature", current: current, values: values) { Format.temperature($0, unit: unit).text })
                    .frame(height: PanelMetrics.miniChartHeight)
            }
        } else {
            let values = store.live.power.suffix(PanelMetrics.chartSamples)
            MiniCard(tab: .battery, title: "Power", symbol: Symbols.power, tint: Palette.battery, onSelect: onSelect) {
                FigureLine(Format.power(store.snapshot.battery.powerDrawWatts)) {
                    Text("whole Mac")
                }
            } footer: {
                PanelAreaChart(values, tint: Palette.battery, maxValue: PanelAreaChart.scale(values, floor: 10), summary: PanelChartSummary.text("Power", current: Format.power(store.snapshot.battery.powerDrawWatts).text, values: values) { Format.power($0).text })
                    .frame(height: PanelMetrics.miniChartHeight)
            }
        }
    }
}

/// A big figure with a caption aligned to its baseline on the right.
private struct FigureLine<Trailing: View>: View {
    private let figure: Figure
    private let trailing: Trailing

    init(_ figure: Figure, @ViewBuilder trailing: () -> Trailing) {
        self.figure = figure
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            PanelFigure(figure, size: 21)
                .layoutPriority(1)
            Spacer(minLength: 4)
            trailing
                .font(.system(size: 11))
                .panelSecondaryText()
                .lineLimit(1)
        }
    }
}

/// One of the six small cards. Clicking it opens that metric's tab in the panel.
private struct MiniCard<FigureContent: View, Footer: View>: View {
    let tab: TallyTab
    let title: String
    let symbol: String
    let tint: Color
    let onSelect: (TallyTab) -> Void
    let figure: FigureContent
    let footer: Footer

    @State private var isHovered = false
    @Environment(\.colorSchemeContrast) private var contrast

    init(tab: TallyTab, title: String, symbol: String? = nil, tint: Color? = nil, onSelect: @escaping (TallyTab) -> Void, @ViewBuilder figure: () -> FigureContent, @ViewBuilder footer: () -> Footer) {
        self.tab = tab
        self.title = title
        self.symbol = symbol ?? tab.symbol
        self.tint = tint ?? tab.tint
        self.onSelect = onSelect
        self.figure = figure()
        self.footer = footer()
    }

    var body: some View {
        Button {
            onSelect(tab)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 7) {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(tint)
                        .frame(width: 14)
                    Text(title)
                        .font(.system(size: 11, weight: .medium))
                        .panelSecondaryText()
                }
                .frame(height: 15)
                figure
                    .padding(.top, 3)
                Spacer(minLength: 0)
                footer
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 9.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 86)
            .background(isHovered ? Palette.cardHighlight : Palette.card, in: RoundedRectangle(cornerRadius: PanelMetrics.cardRadius, style: .continuous))
            .overlay {
                if contrast == .increased {
                    RoundedRectangle(cornerRadius: PanelMetrics.cardRadius, style: .continuous).strokeBorder(Palette.ink3, lineWidth: 1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: PanelMetrics.cardRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Show \(title)")
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows the \(tab.title) section")
    }
}

/// The three apps using the most CPU right now, with their figures in bold and no meters.
private struct BusiestCard: View {
    let apps: [AppUsage]

    var body: some View {
        if !apps.isEmpty {
            PanelCard(horizontal: 16, top: 6, bottom: 9) {
                PanelListTitle(title: "Busiest Apps", height: 25)
                ForEach(apps.indices, id: \.self) { rank in
                    let app = apps[rank]
                    PanelAppRow(app: app, fraction: 0, value: Format.precisePercent(app.cpuPercent), tint: Palette.cpu, valueWidth: 66, showsMeter: false) {
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
        PanelCard(horizontal: 14, top: 10, bottom: 10) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.projects)
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
