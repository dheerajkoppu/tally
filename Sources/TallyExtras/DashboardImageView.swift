import SwiftUI
import TallyCore

/// The dashboard image: a panel per subsystem and the apps using the most, on the share card's canvas.
struct DashboardImageView: View {
    static let size = CGSize(width: 1200, height: 900)
    private static let tileHeight: CGFloat = 202
    private static let appsHeight: CGFloat = 204
    private static let slots = 30

    @ObservedObject private var store = TallyStore.shared
    @ObservedObject private var settings = AppSettings.shared
    let date: Date

    var body: some View {
        let snapshot = store.snapshot
        ShareCanvas(size: Self.size, padding: EdgeInsets(top: 41, leading: 50, bottom: 30, trailing: 50)) {
            VStack(alignment: .leading, spacing: 16) {
                ShareHeader(snapshot: snapshot)
                    .padding(.bottom, 15)
                HStack(spacing: 16) {
                    cpuTile(snapshot)
                    memoryTile(snapshot)
                    gpuTile(snapshot)
                }
                .frame(height: Self.tileHeight)
                HStack(spacing: 16) {
                    diskTile(snapshot)
                    networkTile(snapshot)
                    if snapshot.battery.hasBattery {
                        batteryTile(snapshot)
                    } else {
                        temperatureTile(snapshot)
                    }
                }
                .frame(height: Self.tileHeight)
                HStack(spacing: 16) {
                    AppsPanel(title: "Top apps by memory", tint: Palette.accent, apps: store.topApps(by: .memory, limit: 5), metric: .memory)
                    AppsPanel(title: "Top apps by CPU", tint: Palette.accent, apps: store.topApps(by: .cpu, limit: 5), metric: .cpu)
                    AppsPanel(title: "Top apps by network", tint: Palette.accent, apps: store.topApps(by: .network, limit: 5), metric: .network)
                }
                .frame(height: Self.appsHeight)
                ShareFooter(
                    processes: store.processCount,
                    apps: store.apps.count,
                    date: "\(Format.uptime(snapshot.uptime)) · \(date.formatted(date: .abbreviated, time: .shortened))"
                )
                .padding(.top, 1)
            }
        }
    }

    private func slots(_ metric: HistoryMetric) -> RecentSlots {
        RecentSlots(metric, in: store.live, slotCount: Self.slots)
    }

    /// A scale for rates, so a trickle of traffic does not fill the chart.
    private static func rateScale(_ recent: RecentSlots) -> Double {
        max(recent.slots.compactMap { $0 }.max() ?? 0, 100_000) * 1.1
    }

    private func cpuTile(_ snapshot: SystemSnapshot) -> some View {
        let cpu = snapshot.cpu
        return MetricPanel(
            title: "CPU",
            figure: Format.percent(cpu.totalPercent),
            caption: "now",
            stats: [
                ("User", Format.percent(cpu.userPercent).text, nil),
                ("System", Format.percent(cpu.systemPercent).text, nil),
                ("Load", String(format: "%.2f", cpu.loadAverage.first ?? 0), nil),
            ],
            recent: slots(.cpu),
            maxValue: 100,
            tint: Palette.accent
        )
    }

    private func memoryTile(_ snapshot: SystemSnapshot) -> some View {
        let memory = snapshot.memory
        return MetricPanel(
            title: "Memory in use",
            figure: Format.memory(memory.usedBytes),
            caption: "of \(MachineInfo.installedMemory(snapshot))",
            pressure: memory.pressure,
            stats: [
                ("App", Format.memory(memory.appBytes).text, Palette.memoryApp),
                ("Wired", Format.memory(memory.wiredBytes).text, Palette.memoryWired),
                ("Compressed", Format.memory(memory.compressedBytes).text, Palette.memoryCompressed),
            ],
            recent: slots(.memory),
            maxValue: Double(max(memory.totalBytes, 1)),
            tint: Palette.accent
        )
    }

    private func gpuTile(_ snapshot: SystemSnapshot) -> some View {
        let gpu = snapshot.gpu
        let totals = store.totals
        return MetricPanel(
            title: "GPU",
            figure: Format.percent(gpu.utilizationPercent),
            caption: gpu.name.isEmpty ? MachineInfo.chip(snapshot) : gpu.name,
            stats: [
                ("Memory", Format.memory(gpu.memoryUsedBytes).text, nil),
                ("Average Today", Format.percent(totals.gpuAverageToday).text, nil),
                ("Peak Today", Format.percent(totals.gpuPeakToday).text, nil),
            ],
            recent: slots(.gpu),
            maxValue: 100,
            tint: Palette.accent
        )
    }

    private func diskTile(_ snapshot: SystemSnapshot) -> some View {
        let disk = snapshot.disk
        let live = store.live
        let recent = RecentSlots(dates: live.dates, values: zip(live.diskRead, live.diskWrite).map { $0 + $1 }, slotCount: Self.slots)
        return MetricPanel(
            title: "Disk free",
            figure: Format.storage(disk.freeBytes),
            caption: "of \(Format.storage(disk.totalBytes).text)",
            stats: [
                ("Reading", Format.rate(disk.readBytesPerSecond).text, nil),
                ("Writing", Format.rate(disk.writeBytesPerSecond).text, nil),
                ("Written Today", Format.total(store.totals.diskWrittenToday).text, nil),
            ],
            recent: recent,
            maxValue: Self.rateScale(recent),
            tint: Palette.accent
        )
    }

    private func networkTile(_ snapshot: SystemSnapshot) -> some View {
        let network = snapshot.network
        let recent = slots(.networkIn)
        return MetricPanel(
            title: "Network",
            figure: Format.rate(network.downloadBytesPerSecond),
            caption: "down",
            stats: [
                ("Uploading", Format.rate(network.uploadBytesPerSecond).text, nil),
                ("Today", Format.total(store.totals.networkInToday).text, nil),
                ("Last 7 Days", Format.total(store.totals.networkInLast7Days).text, nil),
            ],
            recent: recent,
            maxValue: Self.rateScale(recent),
            tint: Palette.accent
        )
    }

    private func batteryTile(_ snapshot: SystemSnapshot) -> some View {
        let battery = snapshot.battery
        let caption = battery.isCharging ? "charging" : (battery.isPluggedIn ? "on power adapter" : "on battery")
        let timeLabel: String
        let timeValue: String
        if battery.isPluggedIn && !battery.isCharging {
            timeLabel = "Status"
            timeValue = battery.percent >= 99 ? "Charged" : "Not Charging"
        } else {
            timeLabel = battery.isCharging ? "Until Full" : "Remaining"
            timeValue = battery.timeRemainingMinutes.map { Format.duration(minutes: $0) } ?? "Estimating"
        }
        return MetricPanel(
            title: "Battery",
            figure: Format.percent(battery.percent),
            caption: caption,
            stats: [
                (timeLabel, timeValue, nil),
                ("Power Draw", Format.power(battery.powerDrawWatts).text, nil),
                ("Health", Format.percent(battery.healthPercent).text, nil),
            ],
            recent: slots(.battery),
            maxValue: 100,
            tint: Palette.accent
        )
    }

    private func temperatureTile(_ snapshot: SystemSnapshot) -> some View {
        let sensors = snapshot.sensors
        let unit = settings.temperatureUnit
        let fan = sensors.fans.first.map { Format.integer($0.rpm) + " rpm" } ?? "None"
        return MetricPanel(
            title: "Temperature",
            figure: sensors.cpuTemperatureCelsius.map { Format.temperature($0, unit: unit) } ?? Figure("–", ""),
            caption: "CPU",
            stats: [
                ("GPU", sensors.gpuTemperatureCelsius.map { Format.temperature($0, unit: unit).text } ?? "–", nil),
                ("Fan", fan, nil),
                ("Uptime", Format.uptime(snapshot.uptime).replacingOccurrences(of: "Up ", with: ""), nil),
            ],
            recent: slots(.cpuTemperature),
            maxValue: 110,
            tint: Palette.red
        )
    }
}

/// One subsystem: caps title, a large figure, three stats and the last five minutes as bars over tracks.
private struct MetricPanel: View {
    let title: String
    let figure: Figure
    let caption: String
    var pressure: MemoryPressure?
    let stats: [(String, String, Color?)]
    let recent: RecentSlots
    let maxValue: Double
    let tint: Color

    var body: some View {
        ShareInset(padding: EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18)) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    ShareCapsLabel(title, size: 10)
                    Spacer(minLength: 0)
                    if let pressure { SharePressureTag(pressure: pressure, size: 10) }
                }
                .frame(height: 16)
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(figure.value)
                        .font(.system(size: 36, weight: .bold).monospacedDigit())
                        .tracking(-0.8)
                        .foregroundStyle(Palette.ink)
                    if !figure.unit.isEmpty {
                        Text(figure.unit)
                            .font(.system(size: 23, weight: .semibold))
                            .foregroundStyle(Palette.shareUnit)
                            .padding(.leading, figure.unit == "%" || figure.unit == "°" ? 1 : 5)
                    }
                    Text(caption)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Palette.ink2)
                        .padding(.leading, 9)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.top, 4)
                HStack(alignment: .top, spacing: 10) {
                    ForEach(stats.indices, id: \.self) { index in
                        StatPair(label: stats[index].0, value: stats[index].1, dot: stats[index].2)
                    }
                }
                .padding(.top, 6)
                Spacer(minLength: 10)
                ShareBarChart(slots: recent.slots, maxValue: maxValue, tint: tint, barWidth: 5)
                    .frame(height: 40)
            }
        }
    }
}

/// A caption over a value, with an optional colour dot.
private struct StatPair: View {
    let label: String
    let value: String
    let dot: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                if let dot {
                    Circle().fill(dot).frame(width: 6, height: 6)
                }
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.ink2)
            }
            Text(value)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(Palette.ink)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The five apps using the most of a metric, with icons, bars on neutral tracks and values.
private struct AppsPanel: View {
    let title: String
    let tint: Color
    let apps: [AppUsage]
    let metric: AppMetric

    var body: some View {
        let largest = apps.map { $0.value(for: metric) }.max() ?? 0
        ShareInset(padding: EdgeInsets(top: 15, leading: 16, bottom: 12, trailing: 16)) {
            VStack(alignment: .leading, spacing: 0) {
                ShareCapsLabel(title, size: 10)
                    .frame(height: 12)
                    .padding(.bottom, 6)
                ForEach(apps) { app in
                    HStack(spacing: 0) {
                        AppIconView(app, size: 18)
                        Text(app.name)
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.ink)
                            .padding(.leading, 9)
                        Spacer(minLength: 10)
                        ShareMeter(fraction: largest > 0 ? app.value(for: metric) / largest : 0, tint: tint)
                            .frame(width: 50, height: 4)
                        Text(valueText(app))
                            .font(.system(size: 13, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Palette.ink)
                            .frame(width: 70, alignment: .trailing)
                    }
                    .lineLimit(1)
                    .frame(height: 31.5)
                }
            }
        }
    }

    private func valueText(_ app: AppUsage) -> String {
        switch metric {
        case .memory: Format.memory(app.memoryBytes).text
        case .cpu: Format.precisePercent(app.cpuPercent)
        default: Format.rate(app.value(for: metric)).text
        }
    }
}
