import SwiftUI
import TallyCore

struct OverviewStatContent: Identifiable, Equatable {
    var label: String
    var value: String
    var dot: Color?

    var id: String { label }
}

struct OverviewChipContent: Equatable {
    var label: String?
    var value: String
    /// A status colour before the text, such as memory pressure.
    var dot: Color?
}

/// What a card draws beside its figure.
enum OverviewVisual: Equatable {
    case none
    /// One column per core, each a share of full load.
    case cores([Double])
    case ring([RingGauge.Segment])
    case battery(level: Double, isCharging: Bool, isLow: Bool)
    case thermometer(level: Double, isHot: Bool)
    /// A second, smaller figure, as upload is beside download.
    case figure(symbol: String, Figure, label: String)
}

struct OverviewMetricContent: Equatable {
    var tab: TallyTab
    var title: String
    var symbol: String
    /// The grey line under the figure.
    var detail: String
    /// nil before the first sample.
    var figure: Figure?
    var chips: [OverviewChipContent] = []
    var visual: OverviewVisual = .none
    var stats: [OverviewStatContent]
    /// Bar heights as fractions of the sparkline, rounded to what a pixel can show.
    var bars: [Double]
    /// A second series stacked on the first, as system CPU is on user CPU.
    var stackedBars: [Double]?
    /// What VoiceOver reads for the card: "12% now, average 9% and peak 31% over the last 4 min. User 8%, …".
    var spokenSummary: String
    /// The sparkline's data for VoiceOver's chart description, built only when asked for.
    var chart: SeriesChartDescriptor
}

struct OverviewBreakdownEntry: Identifiable, Equatable {
    var id: String
    var label: String
    /// Share of the donut, rounded to a thousandth.
    var share: Double
    var valueText: String
    var color: Color
    /// Set for app rows, which open the app in the inspector.
    var appID: String?
    var bundlePath: String?
}

struct OverviewBreakdownContent: Equatable {
    var tab: TallyTab
    var title: String
    var symbol: String
    var centerTitle: String
    var centerSubtitle: String
    var entries: [OverviewBreakdownEntry]
}

struct OverviewFanContent: Identifiable, Equatable {
    var id: Int
    var name: String
    /// "2,310 rpm", or "Off".
    var speed: String
    /// Where the speed sits between the fan's slowest and fastest, 0...1.
    var fraction: Double
}

struct OverviewDeviceContent: Identifiable, Equatable {
    var id: String
    var name: String
    var symbol: String
    var percent: String
    var level: Double
    var isLow: Bool
}

struct OverviewAlertContent: Identifiable, Equatable {
    var alert: AlertItem
    var tab: TallyTab
    /// "Just now", "12 min ago".
    var age: String

    var id: String { alert.id }
}

/// Everything the Overview shows, derived from one store update and rounded to what is displayed,
/// so cards whose visible content did not change are not redrawn.
@MainActor
struct OverviewContent {
    static let placeholder = "—"
    static let sparklineCount = 96
    static let appSliceCount = 4

    let cpu: OverviewMetricContent
    let memory: OverviewMetricContent
    let gpu: OverviewMetricContent
    let disk: OverviewMetricContent
    let network: OverviewMetricContent
    let battery: OverviewMetricContent
    let memoryByType: OverviewBreakdownContent
    let memoryByApp: OverviewBreakdownContent
    let powerByApp: OverviewBreakdownContent
    /// nil on Macs that report no temperature.
    let temperature: OverviewMetricContent?
    let fans: [OverviewFanContent]
    let devices: [OverviewDeviceContent]
    let alerts: [OverviewAlertContent]

    init(store: TallyStore, temperatureUnit: TemperatureUnit) {
        let snapshot = store.snapshot
        let hasSample = store.hasSample
        let hasHistory = store.history != nil
        let totals = store.totals
        let live = store.live
        let recentDates = live.dates.suffix(Self.sparklineCount)
        let spanText = Self.spanText(recentDates)
        let spacing = Self.spacing(recentDates)

        func text(_ figure: Figure) -> String { hasSample ? figure.text : Self.placeholder }
        func historyText(_ figure: Figure) -> String { hasSample && hasHistory ? figure.text : Self.placeholder }
        func series(_ metric: HistoryMetric) -> [Double] {
            hasSample ? Array(live.values(for: metric).suffix(Self.sparklineCount)) : []
        }
        /// "average 9% and peak 31% over the last 4 min", from the samples the sparkline shows.
        func trend(_ values: ArraySlice<Double>, _ unit: ChartUnit) -> String? {
            guard hasSample, values.count > 1, let peak = values.max() else { return nil }
            let average = values.reduce(0, +) / Double(values.count)
            return "average \(unit.text(average)) and peak \(unit.text(peak)) over the \(spanText)"
        }
        func recent(_ metric: HistoryMetric) -> ArraySlice<Double> {
            live.values(for: metric).suffix(Self.sparklineCount)
        }
        func spoken(_ figurePhrase: String, pill: String? = nil, trend: String?, stats: [OverviewStatContent]) -> String {
            Self.spokenSummary(hasSample: hasSample, figurePhrase: figurePhrase, pill: pill, trend: trend, stats: stats)
        }
        func chart(_ name: String, bars: [Double], top: Double, unit: ChartUnit, trend: String?) -> SeriesChartDescriptor {
            let summary = trend.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "No samples yet"
            return SeriesChartDescriptor(title: name, summary: summary, seriesName: name, fractions: bars, scale: top, spacing: spacing, unit: unit)
        }

        let cpuStats = snapshot.cpu
        let cpuStatList = [
            OverviewStatContent(label: "User", value: text(Format.percent(cpuStats.userPercent)), dot: Palette.accent),
            OverviewStatContent(label: "System", value: text(Format.percent(cpuStats.systemPercent)), dot: Palette.accentSecond),
            OverviewStatContent(label: "Average Today", value: historyText(Format.percent(totals.cpuAverageToday))),
        ]
        let cpuTrend = trend(recent(.cpu), .percent)
        let cpuBars = Self.bars(series(.cpu), top: 100)
        cpu = OverviewMetricContent(
            tab: .cpu,
            title: "CPU",
            symbol: TallyTab.cpu.symbol,
            detail: hasSample && !cpuStats.chipName.isEmpty ? cpuStats.chipName : "Processor",
            figure: hasSample ? Format.percent(cpuStats.totalPercent) : nil,
            chips: hasSample ? [OverviewChipContent(label: "Load", value: String(format: "%.2f", cpuStats.loadAverage.first ?? 0))] : [],
            visual: .cores(Self.bars(cpuStats.perCorePercent, top: 100)),
            stats: cpuStatList,
            bars: hasSample ? Self.bars(Array(live.cpuUser.suffix(Self.sparklineCount)), top: 100) : [],
            stackedBars: hasSample ? Self.bars(Array(live.cpuSystem.suffix(Self.sparklineCount)), top: 100) : nil,
            spokenSummary: spoken("\(Format.percent(cpuStats.totalPercent).text) now", trend: cpuTrend, stats: cpuStatList),
            chart: chart("CPU usage", bars: cpuBars, top: 100, unit: .percent, trend: cpuTrend)
        )

        let memoryStats = snapshot.memory
        let memoryStatList = [
            OverviewStatContent(label: "App", value: text(Format.memory(memoryStats.appBytes)), dot: Palette.memoryApp),
            OverviewStatContent(label: "Wired", value: text(Format.memory(memoryStats.wiredBytes)), dot: Palette.memoryWired),
            OverviewStatContent(label: "Compressed", value: text(Format.memory(memoryStats.compressedBytes)), dot: Palette.memoryCompressed),
        ]
        let installed = memoryStats.totalBytes > 0 ? Self.installedMemory(memoryStats.totalBytes) : nil
        let memorySeries = series(.memory)
        let memoryTop = memoryStats.totalBytes > 0 ? Double(memoryStats.totalBytes) : Self.top(memorySeries)
        let memoryTrend = trend(recent(.memory), .memory)
        let memoryBars = Self.bars(memorySeries, top: memoryTop)
        let memoryTotal = Double(max(memoryStats.totalBytes, 1))
        memory = OverviewMetricContent(
            tab: .memory,
            title: "Memory",
            symbol: TallyTab.memory.symbol,
            detail: hasSample && installed != nil ? "in use of \(installed ?? "")" : "in use",
            figure: hasSample ? Format.memory(memoryStats.usedBytes) : nil,
            chips: hasSample ? [
                OverviewChipContent(label: "Pressure", value: memoryStats.pressure.label, dot: memoryStats.pressure.tint),
                OverviewChipContent(label: "Swap", value: Format.memory(memoryStats.swapUsedBytes).text),
            ] : [],
            visual: .ring([
                RingGauge.Segment(Double(memoryStats.appBytes) / memoryTotal, color: Palette.memoryApp),
                RingGauge.Segment(Double(memoryStats.wiredBytes) / memoryTotal, color: Palette.memoryWired),
                RingGauge.Segment(Double(memoryStats.compressedBytes) / memoryTotal, color: Palette.memoryCompressed),
            ]),
            stats: memoryStatList,
            bars: memoryBars,
            spokenSummary: spoken(
                "\(Format.memory(memoryStats.usedBytes).text) in use" + (installed.map { " of \($0)" } ?? ""),
                pill: "memory pressure \(memoryStats.pressure.label)",
                trend: memoryTrend,
                stats: memoryStatList
            ),
            chart: chart("Memory in use", bars: memoryBars, top: memoryTop, unit: .memory, trend: memoryTrend)
        )

        let gpuStats = snapshot.gpu
        let chipName = gpuStats.name.isEmpty ? cpuStats.chipName : gpuStats.name
        let gpuStatList = [
            OverviewStatContent(label: "Memory", value: text(Format.memory(gpuStats.memoryUsedBytes))),
            OverviewStatContent(label: "Average", value: historyText(Format.percent(totals.gpuAverageToday))),
            OverviewStatContent(label: "Peak", value: historyText(Format.percent(totals.gpuPeakToday))),
        ]
        let gpuTrend = trend(recent(.gpu), .percent)
        let gpuBars = Self.bars(series(.gpu), top: 100)
        gpu = OverviewMetricContent(
            tab: .gpu,
            title: "GPU",
            symbol: TallyTab.gpu.symbol,
            detail: hasSample && !chipName.isEmpty ? chipName : "Graphics",
            figure: hasSample ? Format.percent(gpuStats.utilizationPercent) : nil,
            visual: .ring([RingGauge.Segment(gpuStats.utilizationPercent / 100)]),
            stats: gpuStatList,
            bars: gpuBars,
            spokenSummary: spoken("\(Format.percent(gpuStats.utilizationPercent).text) now", trend: gpuTrend, stats: gpuStatList),
            chart: chart("GPU usage", bars: gpuBars, top: 100, unit: .percent, trend: gpuTrend)
        )

        let diskStats = snapshot.disk
        let diskSeries: [Double] = hasSample
            ? zip(live.diskRead.suffix(Self.sparklineCount), live.diskWrite.suffix(Self.sparklineCount)).map { $0 + $1 }
            : []
        let diskStatList = [
            OverviewStatContent(label: "Reading", value: text(Format.rate(diskStats.readBytesPerSecond))),
            OverviewStatContent(label: "Writing", value: text(Format.rate(diskStats.writeBytesPerSecond))),
            OverviewStatContent(label: "Written Today", value: historyText(Format.total(totals.diskWrittenToday))),
        ]
        let diskTop = Self.top(diskSeries, floor: 100_000)
        let diskTrend = trend(diskSeries.suffix(min(recentDates.count, diskSeries.count)), .rate)
        let diskBars = Self.bars(diskSeries, top: diskTop)
        let diskTotal = diskStats.totalBytes > 0 ? " of \(Format.storage(diskStats.totalBytes).text)" : ""
        let startupVolume = diskStats.volumes.first(where: \.isRoot)?.name
        disk = OverviewMetricContent(
            tab: .disk,
            title: "Disk",
            symbol: TallyTab.disk.symbol,
            detail: hasSample && diskStats.totalBytes > 0 ? "free of \(Format.storage(diskStats.totalBytes).text)" : "free",
            figure: hasSample ? Format.storage(diskStats.freeBytes) : nil,
            chips: hasSample ? [startupVolume.map { OverviewChipContent(value: $0) }].compactMap { $0 } : [],
            visual: .ring([RingGauge.Segment(diskStats.totalBytes > 0 ? Double(diskStats.usedBytes) / Double(diskStats.totalBytes) : 0)]),
            stats: diskStatList,
            bars: diskBars,
            spokenSummary: spoken("\(Format.storage(diskStats.freeBytes).text) free\(diskTotal)", trend: diskTrend.map { "activity \($0)" }, stats: diskStatList),
            chart: chart("Disk activity", bars: diskBars, top: diskTop, unit: .rate, trend: diskTrend)
        )

        let networkStats = snapshot.network
        let networkStatList = [
            OverviewStatContent(label: "Today", value: historyText(Format.total(totals.networkInToday))),
            OverviewStatContent(label: "Last 7 Days", value: historyText(Format.total(totals.networkInLast7Days))),
            OverviewStatContent(label: "Last 30 Days", value: historyText(Format.total(totals.networkInLast30Days))),
        ]
        let networkSeries = series(.networkIn)
        let networkTop = Self.top(networkSeries, floor: 100_000)
        let networkTrend = trend(recent(.networkIn), .rate)
        let networkBars = Self.bars(networkSeries, top: networkTop)
        let upload = Format.rate(networkStats.uploadBytesPerSecond)
        network = OverviewMetricContent(
            tab: .network,
            title: "Network",
            symbol: TallyTab.network.symbol,
            detail: hasSample && !networkStats.isConnected ? "not connected" : "downloading",
            figure: hasSample ? Format.rate(networkStats.downloadBytesPerSecond) : nil,
            chips: hasSample && networkStats.isConnected && !networkStats.interfaceKind.isEmpty ? [OverviewChipContent(value: networkStats.interfaceKind)] : [],
            visual: hasSample ? .figure(symbol: "arrowtriangle.up.fill", upload, label: "Uploading") : .none,
            stats: networkStatList,
            bars: networkBars,
            spokenSummary: spoken(
                networkStats.isConnected ? "\(Format.rate(networkStats.downloadBytesPerSecond).text) downloading, \(upload.text) uploading" : "Not connected",
                trend: networkTrend,
                stats: networkStatList.map { OverviewStatContent(label: "Downloaded \($0.label)", value: $0.value) }
            ),
            chart: chart("Download speed", bars: networkBars, top: networkTop, unit: .rate, trend: networkTrend)
        )

        battery = Self.batteryContent(snapshot: snapshot, apps: store.apps, hasSample: hasSample, series: series, recent: recent, trend: trend, spoken: spoken, chart: chart)

        memoryByType = Self.memoryByTypeContent(memoryStats, hasSample: hasSample)
        memoryByApp = Self.appBreakdown(
            tab: .memory,
            title: "Memory by App",
            symbol: Symbols.apps,
            apps: store.apps,
            metric: .memory,
            hasSample: hasSample,
            format: { Format.memory(UInt64(max($0, 0))) }
        )
        powerByApp = Self.appBreakdown(
            tab: .battery,
            title: "Power by App",
            symbol: Symbols.power,
            apps: store.apps,
            metric: .power,
            hasSample: hasSample,
            format: { Format.power($0) }
        )

        temperature = hasSample ? Self.temperatureContent(snapshot.sensors, unit: temperatureUnit, live: live, spanText: spanText, spacing: spacing) : nil
        fans = hasSample ? Self.fanContent(snapshot.sensors.fans) : []
        devices = hasSample ? Self.deviceContent(snapshot.sensors.peripheralBatteries) : []
        let now = Date()
        alerts = store.alerts.map { alert in
            OverviewAlertContent(alert: alert, tab: Self.tab(for: alert.kind), age: Self.age(since: alert.date, now: now))
        }
    }

    /// The value a full-height bar stands for: the largest value, never below `floor`.
    static func top(_ values: [Double], floor: Double = 0) -> Double {
        max(values.max() ?? 0, floor, 0.000_001)
    }

    /// Bar heights as fractions of `top`, in 1/256 steps.
    static func bars(_ values: [Double], top: Double) -> [Double] {
        let top = max(top, 0.000_001)
        return values.map { value in
            let fraction = value.isFinite ? min(max(value / top, 0), 1) : 0
            return (fraction * 256).rounded() / 256
        }
    }

    /// "last 4 min", or "last 30 seconds" just after launch.
    static func spanText(_ dates: ArraySlice<Date>) -> String {
        guard let first = dates.first, let last = dates.last else { return "no history yet" }
        let seconds = last.timeIntervalSince(first)
        return seconds < 60 ? "last \(Int(seconds)) seconds" : "last \(Format.span(seconds))"
    }

    /// Whole seconds between the samples a sparkline shows.
    static func spacing(_ dates: ArraySlice<Date>) -> Double {
        guard let first = dates.first, let last = dates.last, dates.count > 1 else { return 5 }
        return max(1, (last.timeIntervalSince(first) / Double(dates.count - 1)).rounded())
    }

    /// "12% now, average 9% and peak 31% over the last 4 min. User 8%, System 4%, Average Today 9%".
    /// Figures not known yet are left out rather than read as dashes.
    static func spokenSummary(hasSample: Bool, figurePhrase: String, pill: String?, trend: String?, stats: [OverviewStatContent]) -> String {
        guard hasSample else { return "Waiting for the first sample" }
        var sentences = [trend.map { "\(figurePhrase), \($0)" } ?? figurePhrase]
        if let pill { sentences.append(pill.prefix(1).uppercased() + pill.dropFirst()) }
        let known = stats.filter { $0.value != placeholder }.map { "\($0.label) \($0.value)" }
        if !known.isEmpty { sentences.append(known.joined(separator: ", ")) }
        return sentences.joined(separator: ". ")
    }

    /// Installed RAM the way Apple quotes it: "64 GB", not "64.00 GB".
    static func installedMemory(_ bytes: UInt64) -> String {
        let gigabytes = Double(bytes) / 1_073_741_824
        if gigabytes >= 1, abs(gigabytes - gigabytes.rounded()) < 0.05 {
            return "\(Int(gigabytes.rounded())) GB"
        }
        return Format.memory(bytes).text
    }

    static func tab(for kind: AlertKind) -> TallyTab {
        switch kind {
        case .highCPU: .cpu
        case .growingMemory: .memory
        case .heavyDisk: .disk
        case .heavyNetwork: .network
        }
    }

    static func age(since date: Date, now: Date) -> String {
        let elapsed = now.timeIntervalSince(date)
        return elapsed < 60 ? "Just now" : "\(Format.span(elapsed)) ago"
    }

    private static func batteryContent(
        snapshot: SystemSnapshot,
        apps: [AppUsage],
        hasSample: Bool,
        series: (HistoryMetric) -> [Double],
        recent: (HistoryMetric) -> ArraySlice<Double>,
        trend: (ArraySlice<Double>, ChartUnit) -> String?,
        spoken: (String, String?, String?, [OverviewStatContent]) -> String,
        chart: (String, [Double], Double, ChartUnit, String?) -> SeriesChartDescriptor
    ) -> OverviewMetricContent {
        let battery = snapshot.battery
        func text(_ value: String) -> String { hasSample ? value : placeholder }

        guard !hasSample || battery.hasBattery else {
            let appsPower = apps.reduce(0) { $0 + $1.powerWatts }
            let topApp = apps.max { $0.powerWatts < $1.powerWatts }
            let draw = Format.power(battery.powerDrawWatts > 0 ? battery.powerDrawWatts : appsPower)
            let stats = [
                OverviewStatContent(label: "All Apps", value: Format.power(appsPower).text),
                OverviewStatContent(label: "Top App", value: topApp.map { $0.powerWatts > 0 ? $0.name : placeholder } ?? placeholder),
                OverviewStatContent(label: "Uptime", value: uptime(snapshot.uptime)),
            ]
            let powerSeries = series(.power)
            let powerTop = top(powerSeries, floor: 5)
            let powerTrend = trend(recent(.power), .power)
            let powerBars = bars(powerSeries, top: powerTop)
            return OverviewMetricContent(
                tab: .battery,
                title: "Power",
                symbol: Symbols.power,
                detail: "power draw",
                figure: draw,
                stats: stats,
                bars: powerBars,
                spokenSummary: spoken("\(draw.text) power draw", nil, powerTrend, stats),
                chart: chart("Power draw", powerBars, powerTop, .power, powerTrend)
            )
        }

        let caption: String
        var chips: [OverviewChipContent] = []
        let time = battery.timeRemainingMinutes.flatMap { $0 > 0 ? Format.duration(minutes: $0) : nil }
        if battery.isCharging {
            caption = "charging"
            if let time { chips.append(OverviewChipContent(label: "Full in", value: time)) }
        } else if battery.isPluggedIn {
            caption = "on power adapter"
            if let adapter = battery.adapterWatts, adapter > 0 { chips.append(OverviewChipContent(label: "Adapter", value: "\(adapter) W")) }
        } else {
            caption = hasSample ? "on battery" : "battery"
            if let time { chips.append(OverviewChipContent(label: "Remaining", value: time)) }
        }
        let stats = [
            OverviewStatContent(label: "Power Draw", value: text(Format.power(battery.powerDrawWatts).text)),
            OverviewStatContent(label: "Cycles", value: text(battery.cycleCount > 0 ? battery.cycleCount.formatted() : placeholder)),
            OverviewStatContent(label: "Health", value: text(battery.healthPercent > 0 ? Format.percent(battery.healthPercent).text : placeholder)),
        ]
        let batteryTrend = trend(recent(.battery), .percent)
        let batteryBars = bars(series(.battery), top: 100)
        return OverviewMetricContent(
            tab: .battery,
            title: "Battery",
            symbol: TallyTab.battery.symbol,
            detail: caption,
            figure: hasSample ? Format.percent(battery.percent) : nil,
            chips: hasSample ? chips : [],
            visual: .battery(level: battery.percent / 100, isCharging: battery.isCharging, isLow: battery.percent <= 10 && !battery.isCharging),
            stats: stats,
            bars: batteryBars,
            spokenSummary: spoken("\(Format.percent(battery.percent).text), \(caption)", chips.first.map { "\($0.label ?? "") \($0.value)" }, batteryTrend, stats),
            chart: chart("Battery level", batteryBars, 100, .percent, batteryTrend)
        )
    }

    /// "3d 4h", "5h 12m", "12m".
    private static func uptime(_ seconds: TimeInterval) -> String {
        guard seconds > 0 else { return placeholder }
        let text = Format.uptime(seconds)
        return text.hasPrefix("Up ") ? String(text.dropFirst(3)) : text
    }

    private static func share(_ value: Double, of total: Double) -> Double {
        guard total > 0, value.isFinite, value > 0 else { return 0 }
        return (min(value / total, 1) * 1000).rounded() / 1000
    }

    private static func memoryByTypeContent(_ memory: MemoryStats, hasSample: Bool) -> OverviewBreakdownContent {
        let parts: [(String, UInt64, Color)] = [
            ("App", memory.appBytes, Palette.memoryApp),
            ("Wired", memory.wiredBytes, Palette.memoryWired),
            ("Compressed", memory.compressedBytes, Palette.memoryCompressed),
            ("Cached", memory.cachedBytes, Palette.memoryCached),
            ("Free", memory.freeBytes, Palette.memoryFree),
        ]
        let total = parts.reduce(0) { $0 + Double($1.1) }
        return OverviewBreakdownContent(
            tab: .memory,
            title: "Memory by Type",
            symbol: TallyTab.memory.symbol,
            centerTitle: hasSample && memory.totalBytes > 0 ? Format.percent(memory.usedFraction * 100).text : placeholder,
            centerSubtitle: "in use",
            entries: parts.map { label, bytes, color in
                OverviewBreakdownEntry(
                    id: label,
                    label: label,
                    share: hasSample ? share(Double(bytes), of: total) : 0,
                    valueText: hasSample ? Format.memory(bytes).text : placeholder,
                    color: color
                )
            }
        )
    }

    private static func appBreakdown(tab: TallyTab, title: String, symbol: String, apps: [AppUsage], metric: AppMetric, hasSample: Bool, format: (Double) -> Figure) -> OverviewBreakdownContent {
        let hasSample = hasSample && !apps.isEmpty
        let total = apps.reduce(0) { $0 + max($1.value(for: metric), 0) }
        let top = Array(apps.lazy.filter { $0.value(for: metric) > 0 }.sorted { $0.value(for: metric) > $1.value(for: metric) }.prefix(appSliceCount))
        let other = max(total - top.reduce(0) { $0 + $1.value(for: metric) }, 0)

        var entries = top.enumerated().map { index, app in
            OverviewBreakdownEntry(
                id: app.id,
                label: app.name,
                share: share(app.value(for: metric), of: total),
                valueText: format(app.value(for: metric)).text,
                color: Palette.accent.opacity(1 - 0.2 * Double(index)),
                appID: app.id,
                bundlePath: app.bundlePath ?? (app.kind == .tool ? app.processes.first?.executablePath : nil)
            )
        }
        if hasSample && (!entries.isEmpty || total > 0) {
            entries.append(OverviewBreakdownEntry(id: "other", label: "Other", share: share(other, of: total), valueText: format(other).text, color: Palette.memoryFree))
        }
        return OverviewBreakdownContent(
            tab: tab,
            title: title,
            symbol: symbol,
            centerTitle: hasSample ? format(total).text : placeholder,
            centerSubtitle: "all apps",
            entries: entries
        )
    }

    /// The CPU temperature with its recent history, and up to three other sensors beside it.
    private static func temperatureContent(_ sensors: SensorStats, unit: TemperatureUnit, live: LiveSeries, spanText: String, spacing: Double) -> OverviewMetricContent? {
        guard let celsius = sensors.cpuTemperatureCelsius, celsius > 0 else { return nil }
        let figure = Format.temperature(celsius, unit: unit)
        let range = TemperatureRange(celsius: celsius)
        let others = sensors.temperatures.filter { !$0.name.hasPrefix("CPU") && $0.celsius > 0 }
        var stats = others.prefix(3).map { OverviewStatContent(label: $0.name, value: Format.temperature($0.celsius, unit: unit).text) }
        if stats.isEmpty, let gpu = sensors.gpuTemperatureCelsius, gpu > 0 {
            stats = [OverviewStatContent(label: "GPU", value: Format.temperature(gpu, unit: unit).text)]
        }
        let recentValues = live.cpuTemperature.suffix(sparklineCount).filter { $0 > 0 }
        let series = bars(Array(live.cpuTemperature.suffix(sparklineCount)), top: TemperatureRange.scaleTop)
        var trend: String?
        if recentValues.count > 1, let peak = recentValues.max() {
            let average = recentValues.reduce(0, +) / Double(recentValues.count)
            trend = "average \(Format.temperature(average, unit: unit).text) and peak \(Format.temperature(peak, unit: unit).text) over the \(spanText)"
        }
        return OverviewMetricContent(
            tab: .sensors,
            title: "Temperature",
            symbol: Symbols.temperature,
            detail: "CPU",
            figure: figure,
            chips: [OverviewChipContent(label: "Range", value: range.label, dot: range.statusTint)],
            visual: .thermometer(level: TemperatureRange.level(celsius), isHot: range == .high),
            stats: stats,
            bars: series,
            spokenSummary: spokenSummary(hasSample: true, figurePhrase: "CPU \(figure.text), \(range.label.lowercased())", pill: nil, trend: trend, stats: stats),
            chart: SeriesChartDescriptor(title: "CPU temperature", summary: trend.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "No samples yet", seriesName: "CPU temperature", fractions: series, scale: TemperatureRange.scaleTop, spacing: spacing, unit: .temperature(unit))
        )
    }

    private static func fanContent(_ fans: [FanReading]) -> [OverviewFanContent] {
        fans.map { fan in
            let rpm = (fan.rpm / 10).rounded() * 10
            let span = fan.maxRPM - fan.minRPM
            return OverviewFanContent(
                id: fan.id,
                name: fans.count == 1 ? "Fan" : fan.name,
                speed: fan.rpm >= 1 ? "\(Format.integer(rpm)) rpm" : "Off",
                fraction: fan.rpm >= 1 && span > 0 ? min(max((fan.rpm - fan.minRPM) / span, 0.04), 1) : 0
            )
        }
    }

    static func deviceContent(_ peripherals: [PeripheralBattery]) -> [OverviewDeviceContent] {
        peripherals.map { peripheral in
            OverviewDeviceContent(
                id: peripheral.id,
                name: peripheral.name,
                symbol: peripheral.kind.symbol,
                percent: Format.percent(peripheral.percent).text,
                level: (peripheral.percent / 100 * 50).rounded() / 50,
                isLow: peripheral.percent <= 20
            )
        }
    }
}
