import SwiftUI
import TallyCore

struct CPUPanel: View {
    @ObservedObject private var store = TallyStore.shared

    var body: some View {
        let cpu = store.snapshot.cpu
        let values = store.live.cpu.suffix(PanelMetrics.chartSamples)
        VStack(spacing: 0) {
            PanelSectionTitle("CPU")
            PanelCard {
                PanelMetricHeader {
                    PanelFigure(Format.percent(cpu.totalPercent), size: 29)
                } caption: {
                    Text(cpu.chipName)
                } trailing: {
                    PanelBarChart(values, maxValue: PanelBarChart.scale(values, floor: 10), summary: PanelChartSummary.text("CPU", current: Format.percent(cpu.totalPercent).text, values: values) { Format.percent($0).text })
                        .frame(width: PanelMetrics.chartSize.width, height: PanelMetrics.chartSize.height)
                }
                VStack(spacing: 0) {
                    PanelDetailRow("User", value: Format.percent(cpu.userPercent).text)
                    PanelDetailRow("System", value: Format.percent(cpu.systemPercent).text)
                    PanelDetailRow("Load Average", value: String(format: "%.2f", cpu.loadAverage.first ?? 0))
                    if cpu.logicalCores > 0 {
                        PanelDetailRow("Cores") {
                            HStack(spacing: 5) {
                                if cpu.performanceCores > 0, cpu.efficiencyCores > 0 {
                                    PanelTag(text: "\(cpu.performanceCores) P", tint: Palette.accent, fontSize: 11)
                                    PanelTag(text: "\(cpu.efficiencyCores) E", tint: Palette.accent, fontSize: 11)
                                }
                                Text(verbatim: "\(cpu.logicalCores)")
                            }
                        }
                    }
                }
                .padding(.top, 9)
                PanelTopApps(title: "Top Apps", tab: .cpu, metric: .cpu, apps: store.topApps(by: .cpu, limit: 5), tint: Palette.accent, scaleFloor: 50) {
                    Format.precisePercent($0)
                }
            }
            .padding(.top, 10)
        }
    }
}

struct MemoryPanel: View {
    @ObservedObject private var store = TallyStore.shared

    var body: some View {
        let memory = store.snapshot.memory
        VStack(spacing: 0) {
            PanelSectionTitle("Memory")
            PanelCard {
                PanelMetricHeader {
                    PanelFigure(Format.memory(memory.usedBytes), size: 29)
                } caption: {
                    HStack(spacing: 8) {
                        Text(verbatim: "of \(PanelFormat.memoryCapacity(memory.totalBytes))")
                        PanelTag(text: memory.pressure.label, tint: pressureTint(memory.pressure))
                            .help("Memory pressure")
                    }
                } trailing: {
                    let values = store.live.memoryUsed.suffix(PanelMetrics.chartSamples)
                    PanelBarChart(values, maxValue: Double(max(memory.totalBytes, 1)), summary: PanelChartSummary.text("Memory", current: Format.memory(memory.usedBytes).text, values: values) { Format.memory(UInt64(max($0, 0))).text })
                        .frame(width: PanelMetrics.chartSize.width, height: PanelMetrics.chartSize.height)
                }
                SegmentedMeter([
                    .init(id: 0, value: Double(memory.appBytes), color: Palette.memoryApp),
                    .init(id: 1, value: Double(memory.wiredBytes), color: Palette.memoryWired),
                    .init(id: 2, value: Double(memory.compressedBytes), color: Palette.memoryCompressed),
                ], total: Double(memory.totalBytes), height: 6)
                .padding(.top, 15)
                .accessibilityHidden(true)
                VStack(spacing: 0) {
                    PanelDetailRow("App", value: Format.memory(memory.appBytes).text, dot: Palette.memoryApp)
                    PanelDetailRow("Wired", value: Format.memory(memory.wiredBytes).text, dot: Palette.memoryWired)
                    PanelDetailRow("Compressed", value: Format.memory(memory.compressedBytes).text, dot: Palette.memoryCompressed)
                    PanelDetailRow("Swap Used", value: Format.memory(memory.swapUsedBytes).text)
                }
                .padding(.top, 5)
                PanelTopApps(title: "Top Apps", tab: .memory, metric: .memory, apps: Array(store.apps.prefix(5)), tint: Palette.accent) {
                    Format.memory(UInt64(max($0, 0))).text
                }
            }
            .padding(.top, 10)
        }
    }

    private func pressureTint(_ pressure: MemoryPressure) -> Color {
        pressure.tint
    }
}

struct DiskPanel: View {
    @ObservedObject private var store = TallyStore.shared

    var body: some View {
        let disk = store.snapshot.disk
        let free = Format.storage(disk.freeBytes)
        let usedFraction = disk.totalBytes == 0 ? 0 : Double(disk.usedBytes) / Double(disk.totalBytes)
        VStack(spacing: 0) {
            PanelSectionTitle("Disk")
            PanelCard {
                PanelMetricHeader {
                    PanelFigure(Figure(free.value, "\(free.unit) free"), size: 29)
                } caption: {
                    Text(verbatim: "\(Format.storage(disk.usedBytes).text) used of \(Format.storage(disk.totalBytes).text)")
                } trailing: {
                    PanelMeter(usedFraction, tint: Palette.accent, height: 6)
                        .frame(width: PanelMetrics.chartSize.width)
                        .padding(.bottom, 4)
                }
                VStack(spacing: 0) {
                    PanelDetailRow("Reading", value: Format.rate(disk.readBytesPerSecond).text)
                    PanelDetailRow("Writing", value: Format.rate(disk.writeBytesPerSecond).text)
                    if store.totals.diskWrittenToday > 0 {
                        PanelDetailRow("Written Today", value: Format.total(store.totals.diskWrittenToday).text)
                    }
                    if let drive = disk.drives.first {
                        let health = Format.percent(drive.healthPercent).text
                        PanelDetailRow("Drive Health", value: drive.needsAttention ? "\(health), Needs Attention" : health, dot: drive.needsAttention ? Palette.red : nil)
                            .help("Rated life left on the \(drive.isInternal ? "internal SSD" : drive.model), as the drive estimates it.")
                        PanelDetailRow("Total Written", value: Format.total(drive.bytesWritten).text)
                        PanelDetailRow("Total Read", value: Format.total(drive.bytesRead).text)
                    }
                }
                .padding(.top, 9)
                PanelTopApps(title: "Top Apps by Disk Writes", tab: .disk, metric: .diskWrite, apps: store.topApps(by: .diskWrite, limit: 5), tint: Palette.accent) {
                    Format.rate($0).text
                }
            }
            .padding(.top, 10)
        }
    }
}

struct NetworkPanel: View {
    @ObservedObject private var store = TallyStore.shared

    var body: some View {
        let network = store.snapshot.network
        let values = store.live.networkIn.suffix(PanelMetrics.chartSamples)
        VStack(spacing: 0) {
            PanelSectionTitle("Network")
            PanelCard {
                PanelMetricHeader {
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Image(systemName: Symbols.download)
                            .font(.system(size: 12, weight: .regular))
                            .panelSecondaryText()
                            .accessibilityLabel("Download")
                        PanelFigure(Format.rate(network.downloadBytesPerSecond), size: 29)
                    }
                } caption: {
                    HStack(spacing: 4) {
                        Image(systemName: Symbols.upload)
                            .font(.system(size: 10, weight: .regular))
                            .accessibilityLabel("Upload")
                        Text(Format.rate(network.uploadBytesPerSecond).text)
                    }
                } trailing: {
                    PanelBarChart(values, maxValue: PanelBarChart.scale(values, floor: 10_000), summary: PanelChartSummary.text("Download", current: Format.rate(network.downloadBytesPerSecond).text, values: values) { Format.rate($0).text })
                        .frame(width: PanelMetrics.chartSize.width, height: PanelMetrics.chartSize.height)
                }
                VStack(spacing: 0) {
                    if store.totals.networkInToday > 0 {
                        PanelDetailRow("Downloaded Today", value: Format.total(store.totals.networkInToday).text)
                    }
                    PanelDetailRow("Downloaded This Session", value: Format.total(network.sessionDownloadedBytes).text)
                    PanelDetailRow("Uploaded This Session", value: Format.total(network.sessionUploadedBytes).text)
                    if network.connections.isEmpty {
                        PanelDetailRow("Interface", value: interfaceText(network))
                    } else {
                        ForEach(network.connections) { connection in
                            PanelConnectionRow(connection: connection, marksPrimary: network.connections.count > 1)
                                .equatable()
                        }
                    }
                }
                .padding(.top, 9)
                PanelTopApps(title: "Top Apps by Download", tab: .network, metric: .networkIn, apps: store.topApps(by: .networkIn, limit: 5), tint: Palette.accent) {
                    Format.rate($0).text
                }
            }
            .padding(.top, 10)
        }
    }

    private func interfaceText(_ network: NetworkStats) -> String {
        guard network.isConnected, !network.interfaceName.isEmpty else { return "Not connected" }
        if network.interfaceKind.isEmpty { return network.interfaceName }
        return "\(network.interfaceKind) · \(network.interfaceName)"
    }
}

/// "Ethernet · en8  1 Gb/s ...... ↓ 21 kB/s  ↑ 217 kB/s". The link speed gives way when the row is too narrow,
/// and each rate keeps a minimum width so the arrows line up from row to row.
private struct PanelConnectionRow: View, Equatable {
    private let name: String
    private let linkSpeed: String?
    private let download: String
    private let upload: String
    private let isPrimary: Bool
    private let marksPrimary: Bool

    init(connection: NetworkConnection, marksPrimary: Bool) {
        name = "\(connection.kind) · \(connection.interfaceName)"
        linkSpeed = connection.linkSpeedText
        download = Format.rate(connection.downloadBytesPerSecond).text
        upload = Format.rate(connection.uploadBytesPerSecond).text
        isPrimary = connection.isPrimary
        self.marksPrimary = marksPrimary
    }

    var body: some View {
        HStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    label
                    if let linkSpeed {
                        Text(linkSpeed)
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(Palette.ink3)
                    }
                }
                label
            }
            Spacer(minLength: 10)
            HStack(spacing: 8) {
                rate(download, symbol: Symbols.download)
                rate(upload, symbol: Symbols.upload)
            }
        }
        .lineLimit(1)
        .frame(height: PanelMetrics.detailRowHeight)
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isPrimary && marksPrimary ? "\(name), primary" : name)
        .accessibilityValue(accessibilityValue)
    }

    private var label: some View {
        Text(name)
            .font(PanelMetrics.rowFont)
            .panelSecondaryText()
            .truncationMode(.middle)
    }

    private func rate(_ value: String, symbol: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .semibold))
                .panelSecondaryText()
            Text(value)
                .font(PanelMetrics.valueFont)
                .foregroundStyle(Palette.ink)
        }
        .fixedSize()
        .frame(minWidth: 78, alignment: .trailing)
    }

    private var accessibilityValue: String {
        var parts = ["download \(download)", "upload \(upload)"]
        if let linkSpeed { parts.append("link speed \(linkSpeed)") }
        return parts.joined(separator: ", ")
    }

    private var helpText: String {
        let speed = linkSpeed.map { "\($0) link" }
        let primary = isPrimary && marksPrimary ? "Primary connection" : nil
        return [speed, primary].compactMap { $0 }.joined(separator: " · ")
    }
}

struct GPUPanel: View {
    @ObservedObject private var store = TallyStore.shared

    var body: some View {
        let gpu = store.snapshot.gpu
        let totals = store.totals
        let values = store.live.gpu.suffix(PanelMetrics.chartSamples)
        VStack(spacing: 0) {
            PanelSectionTitle("GPU")
            PanelCard {
                PanelMetricHeader {
                    PanelFigure(Format.percent(gpu.utilizationPercent), size: 29)
                } caption: {
                    Text(gpu.name.isEmpty ? store.snapshot.cpu.chipName : gpu.name)
                } trailing: {
                    PanelBarChart(values, maxValue: PanelBarChart.scale(values, floor: 10), summary: PanelChartSummary.text("GPU", current: Format.percent(gpu.utilizationPercent).text, values: values) { Format.percent($0).text })
                        .frame(width: PanelMetrics.chartSize.width, height: PanelMetrics.chartSize.height)
                }
                VStack(spacing: 0) {
                    PanelDetailRow("GPU Memory in Use", value: Format.memory(gpu.memoryUsedBytes).text)
                    if totals.gpuPeakToday > 0 {
                        PanelDetailRow("Average Today", value: Format.percent(totals.gpuAverageToday).text)
                        PanelDetailRow("Peak Today", value: Format.percent(totals.gpuPeakToday).text)
                    }
                }
                .padding(.top, 9)
                PanelTopApps(title: "Top Apps", tab: .gpu, metric: .gpu, apps: store.topApps(by: .gpu, limit: 5), tint: Palette.accent) {
                    Format.precisePercent($0)
                }
            }
            .padding(.top, 10)
        }
    }
}

struct BatteryPanel: View {
    @ObservedObject private var store = TallyStore.shared

    var body: some View {
        let battery = store.snapshot.battery
        VStack(spacing: 0) {
            PanelSectionTitle("Battery")
            PanelCard {
                if battery.hasBattery {
                    PanelMetricHeader {
                        PanelFigure(Format.percent(battery.percent), size: 29)
                    } caption: {
                        Text(BatteryText.remaining(battery))
                    } trailing: {
                        PanelMeter(battery.percent / 100, tint: battery.percent <= 10 && !battery.isCharging ? Palette.red : Palette.accent, height: 6)
                            .frame(width: PanelMetrics.chartSize.width)
                            .padding(.bottom, 4)
                    }
                    VStack(spacing: 0) {
                        PanelDetailRow("Power Draw", value: Format.power(battery.powerDrawWatts).text)
                        if battery.isPluggedIn, let adapter = battery.adapterWatts, adapter > 0 {
                            PanelDetailRow("Power Adapter", value: "\(adapter) W")
                        }
                        if battery.healthPercent > 0 {
                            PanelDetailRow("Maximum Capacity", value: Format.percent(battery.healthPercent).text)
                        }
                        PanelDetailRow("Cycle Count", value: PanelFormat.integer(Double(battery.cycleCount)))
                    }
                    .padding(.top, 9)
                } else {
                    PanelMetricHeader {
                        PanelFigure(Format.power(battery.powerDrawWatts), size: 29)
                    } caption: {
                        Text("No battery, on power adapter")
                    } trailing: {
                        EmptyView()
                    }
                }
                PanelTopApps(title: "Top Apps by Power", tab: .battery, metric: .power, apps: store.topApps(by: .power, limit: 5), tint: Palette.accent) {
                    Format.power($0).text
                }
            }
            .padding(.top, 10)
        }
    }
}

/// CPU temperature with its recent history, every other temperature, the fans and connected devices.
struct SensorsPanel: View {
    @ObservedObject private var store = TallyStore.shared
    @ObservedObject private var settings = AppSettings.shared

    /// The panel stays short: the full list is on the Sensors tab of the window.
    private static let visibleReadings = 8

    var body: some View {
        let sensors = store.snapshot.sensors
        let unit = settings.temperatureUnit
        let readings = sensors.temperatures.filter { $0.celsius > 0 }
        VStack(spacing: 0) {
            PanelSectionTitle("Sensors")
            PanelCard {
                if let celsius = sensors.cpuTemperatureCelsius, celsius > 0 {
                    let range = TemperatureRange(celsius: celsius)
                    let values = store.live.cpuTemperature.suffix(PanelMetrics.chartSamples)
                    let current = Format.temperature(celsius, unit: unit)
                    PanelMetricHeader {
                        PanelFigure(current, size: 29)
                    } caption: {
                        Text(verbatim: "CPU, \(range.label.lowercased())")
                    } trailing: {
                        PanelBarChart(values, tint: range.tint, maxValue: TemperatureRange.scaleTop, summary: PanelChartSummary.text("CPU temperature", current: current.text, values: values) { Format.temperature($0, unit: unit).text })
                            .frame(width: PanelMetrics.chartSize.width, height: PanelMetrics.chartSize.height)
                    }
                } else {
                    Text(store.hasSample ? "This Mac does not report its temperatures." : "Reading sensors…")
                        .font(PanelMetrics.rowFont)
                        .panelSecondaryText()
                        .frame(maxWidth: .infinity, minHeight: PanelMetrics.detailRowHeight, alignment: .leading)
                }
                if !readings.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(readings.prefix(Self.visibleReadings)) { reading in
                            PanelDetailRow(reading.name, value: Format.temperature(reading.celsius, unit: unit).text)
                        }
                    }
                    .padding(.top, 9)
                }
                if !sensors.fans.isEmpty {
                    FanRows(fans: sensors.fans)
                }
                if !sensors.peripheralBatteries.isEmpty {
                    DeviceRows(devices: sensors.peripheralBatteries)
                }
                if readings.count > Self.visibleReadings || sensors.fans.isEmpty {
                    PanelDivider()
                        .padding(.top, 10)
                        .padding(.bottom, 6)
                    Button(readings.count > Self.visibleReadings ? "Show All \(readings.count) Sensors" : "Open Sensors") {
                        PanelActions.openMainWindow(.sensors)
                    }
                    .buttonStyle(PanelTextButtonStyle())
                    .frame(height: 22)
                    .padding(.horizontal, -PanelTextButtonStyle.horizontalPadding)
                }
            }
            .padding(.top, 10)
        }
    }
}

/// Each fan's speed, with a way into fan control on the window's Sensors tab.
private struct FanRows: View {
    let fans: [FanReading]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelDivider()
                .padding(.top, 10)
                .padding(.bottom, 3)
            PanelListTitle(title: fans.count == 1 ? "Fan" : "Fans", height: 30) {
                Button("Fan Control") {
                    PanelActions.openFanControl()
                }
                .buttonStyle(SoftButtonStyle())
                .help("Set fan speeds in the Tally window")
            }
            ForEach(fans) { fan in
                PanelDetailRow(fan.name, value: fan.rpm >= 1 ? "\(PanelFormat.integer(fan.rpm)) rpm" : "Off")
            }
        }
    }
}

/// Battery levels of AirPods, mice and keyboards, each with a small meter.
private struct DeviceRows: View {
    let devices: [PeripheralBattery]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelDivider()
                .padding(.top, 10)
                .padding(.bottom, 3)
            PanelListTitle(title: "Devices", height: 26)
            ForEach(devices) { device in
                PanelDetailRow(device.name) {
                    HStack(spacing: 10) {
                        PanelMeter(device.percent / 100, tint: device.percent <= 20 ? Palette.red : Palette.accent, height: 4)
                            .frame(width: PanelMetrics.meterWidth)
                        Text(Format.percent(device.percent).text)
                            .frame(width: 38, alignment: .trailing)
                    }
                }
            }
        }
    }
}
