import SwiftUI
import TallyCore

/// The time span a metric tab charts: the live buffer or a stored history range.
enum MetricRange: Hashable, Identifiable {
    case live
    case history(HistoryRange)

    static let all: [MetricRange] = [.live] + HistoryRange.allCases.map { .history($0) }

    var id: String {
        switch self {
        case .live: "live"
        case .history(let range): range.rawValue
        }
    }

    var label: String {
        switch self {
        case .live: "Live"
        case .history(let range): range.label
        }
    }

    var historyRange: HistoryRange? {
        if case .history(let range) = self { return range }
        return nil
    }
}

extension HistoryRange {
    /// "last 12 hours", "last 7 days"
    var metricPhrase: String {
        switch self {
        case .hours12: "last 12 hours"
        case .hours24: "last 24 hours"
        case .days7: "last 7 days"
        case .days30: "last 30 days"
        }
    }

    /// Chart resolution for each range, close to one point per 12 pt of chart width.
    var metricBuckets: Int {
        switch self {
        case .hours12: 72
        case .hours24: 96
        case .days7: 84
        case .days30: 90
        }
    }
}

/// The range chosen on any metric tab, kept while the app runs so switching tabs keeps it.
@MainActor
enum MetricRangeMemory {
    static var range: MetricRange = .live
}

struct MetricKeyValue: Identifiable, Equatable {
    var label: String
    var value: String
    var help: String?

    var id: String { label }
}

enum MetricTileDetail: Equatable {
    case none
    case text(String)
    case tags([String])
    case meter(Double)
}

struct MetricTileModel: Identifiable, Equatable {
    var symbol: String
    var label: String
    var value: String
    var detail: MetricTileDetail = .none
    var help: String?

    var id: String { label }
}

/// How a figure is written in charts, lists and tooltips.
enum MetricValueFormat: Hashable {
    /// "66%"
    case percent
    /// Per-app percent: "44.1%"
    case appPercent
    /// "53.88 GB"
    case memory
    /// "5.3 MB/s"
    case rate
    /// "4.8 GB"
    case total
    /// "1.7 W"
    case power

    /// The least a full meter stands for, so figures that round to nothing do not fill their meter.
    var meterFloor: Double {
        switch self {
        case .percent, .appPercent: 1
        case .rate: 10_000
        case .power: 0.01
        case .memory, .total: 0
        }
    }

    func text(_ value: Double) -> String {
        switch self {
        case .percent: Format.percent(value).text
        case .appPercent: MetricTabContent.appPercent(value)
        case .memory: Format.memory(MetricTabContent.byteCount(value)).text
        case .rate: Format.rate(value).text
        case .total: Format.total(MetricTabContent.byteCount(value)).text
        case .power: Format.power(value).text
        }
    }
}

/// How a tab charts its main figure, live and from history.
struct MetricChartModel {
    /// Spoken name of the chart: "CPU".
    var name: String
    var liveValues: [Double]
    var liveDates: [Date]
    /// Summed when there is more than one, as disk read + write.
    var historyMetrics: [HistoryMetric]
    /// A fixed top of scale (100 for percentages, total RAM for memory); nil scales to the data.
    var fixedMax: Double?
    /// The smallest top of scale when scaling to the data, so idle noise stays flat.
    var autoFloor: Double
    var format: MetricValueFormat

    func scaleMax(for values: [Double]) -> Double {
        if let fixedMax, fixedMax > 0 { return fixedMax }
        return max((values.max() ?? 0) * 1.15, autoFloor)
    }
}

/// How a tab ranks apps, live and over a history range.
struct MetricListModel {
    var appMetric: AppMetric
    var historyMetric: HistoryMetric
    /// Column title for the live list: "CPU", "Writing".
    var title: String
    /// "Most CPU" in "Most CPU, last 7 days".
    var historyTitle: String
    /// Column title for the history list: "Average", "Written".
    var historyValueTitle: String
    var format: MetricValueFormat
    var historyFormat: MetricValueFormat
}

/// Everything one metric tab shows, computed from the store on each update.
struct MetricTabContent {
    /// True before the first sample arrives, when figures show placeholders.
    var isPlaceholder: Bool
    var caption: String
    var figure: Figure
    var pressure: MemoryPressure?
    var keyValues: [MetricKeyValue]
    var chart: MetricChartModel
    var tiles: [MetricTileModel]
    var list: MetricListModel

    private static let placeholder = "—"

    @MainActor
    init(tab: TallyTab, store: TallyStore, settings: AppSettings) {
        let snapshot = store.snapshot
        let live = store.live
        let totals = store.totals
        let ready = store.hasSample
        isPlaceholder = !ready
        let dash = Self.placeholder
        let temperatureUnit = settings.temperatureUnit
        pressure = nil

        switch tab {
        case .memory:
            let memory = snapshot.memory
            let total = Double(memory.totalBytes)
            let free = memory.totalBytes > memory.usedBytes ? memory.totalBytes - memory.usedBytes : 0
            caption = ready ? "In use of \(Self.wholeGigabytes(memory.totalBytes))" : "In use"
            figure = ready ? Format.memory(memory.usedBytes) : Figure(dash, "GB")
            pressure = ready ? memory.pressure : nil
            keyValues = [
                MetricKeyValue(label: "Free", value: ready ? Format.memory(free).text : dash, help: "Memory not used by apps, the system or compression. Cached files are counted as free."),
                MetricKeyValue(label: "Swap", value: ready ? Format.memory(memory.swapUsedBytes).text : dash, help: "Memory moved out to the startup disk."),
            ]
            chart = MetricChartModel(name: "Memory used", liveValues: live.memoryUsed, liveDates: live.dates, historyMetrics: [.memory], fixedMax: total > 0 ? total : nil, autoFloor: 1_073_741_824, format: .memory)
            tiles = [
                MetricTileModel(symbol: Symbols.apps, label: "App", value: ready ? Format.memory(memory.appBytes).text : dash, detail: .meter(Self.fraction(memory.appBytes, of: memory.totalBytes)), help: "Memory held by apps and their helper processes."),
                MetricTileModel(symbol: Symbols.lock, label: "Wired", value: ready ? Format.memory(memory.wiredBytes).text : dash, detail: .meter(Self.fraction(memory.wiredBytes, of: memory.totalBytes)), help: "Memory macOS keeps in RAM for itself. It cannot be compressed or swapped."),
                MetricTileModel(symbol: TallyTab.memory.symbol, label: "Compressed", value: ready ? Format.memory(memory.compressedBytes).text : dash, detail: .meter(Self.fraction(memory.compressedBytes, of: memory.totalBytes)), help: "Memory macOS compressed to make room."),
            ]
            list = MetricListModel(appMetric: .memory, historyMetric: .memory, title: "Memory", historyTitle: "Most memory", historyValueTitle: "Average", format: .memory, historyFormat: .memory)

        case .disk:
            let disk = snapshot.disk
            caption = ready && disk.totalBytes > 0 ? "Free of \(Format.storage(disk.totalBytes).text)" : "Free"
            figure = ready ? Format.storage(disk.freeBytes) : Figure(dash, "GB")
            keyValues = [
                MetricKeyValue(label: "Used", value: ready ? Format.storage(disk.usedBytes).text : dash),
                MetricKeyValue(label: "Written today", value: ready ? Format.total(totals.diskWrittenToday).text : dash),
            ]
            let activity = zip(live.diskRead, live.diskWrite).map { $0 + $1 }
            chart = MetricChartModel(name: "Disk activity", liveValues: activity, liveDates: live.dates, historyMetrics: [.diskRead, .diskWrite], fixedMax: nil, autoFloor: 1_000_000, format: .rate)
            let volumeNames = disk.volumes.map(\.name)
            tiles = [
                MetricTileModel(symbol: "arrow.down.to.line", label: "Reading", value: ready ? Format.rate(disk.readBytesPerSecond).text : dash),
                MetricTileModel(symbol: Symbols.upload, label: "Writing", value: ready ? Format.rate(disk.writeBytesPerSecond).text : dash),
                MetricTileModel(symbol: TallyTab.disk.symbol, label: "Volumes", value: ready ? "\(disk.volumes.count)" : dash, detail: .tags(volumeNames), help: volumeNames.joined(separator: ", ")),
            ]
            list = MetricListModel(appMetric: .diskWrite, historyMetric: .diskWrite, title: "Writing", historyTitle: "Most written", historyValueTitle: "Written", format: .rate, historyFormat: .total)

        case .network:
            let network = snapshot.network
            caption = "Downloading"
            figure = ready ? Format.rate(network.downloadBytesPerSecond) : Figure(dash, "kB/s")
            keyValues = [
                MetricKeyValue(label: "Today", value: ready ? Format.total(totals.networkInToday).text : dash, help: "Downloaded since midnight."),
                MetricKeyValue(label: "Last 30 days", value: ready ? Format.total(totals.networkInLast30Days).text : dash, help: "Downloaded in the last 30 days."),
            ]
            chart = MetricChartModel(name: "Download speed", liveValues: live.networkIn, liveDates: live.dates, historyMetrics: [.networkIn], fixedMax: nil, autoFloor: 100_000, format: .rate)
            let connected = network.isConnected && !network.interfaceName.isEmpty
            let interfaceSymbol: String = {
                let kind = network.interfaceKind.lowercased()
                if kind.contains("wi-fi") || kind.contains("wifi") || kind.contains("airport") { return Symbols.wifi }
                if kind.contains("ethernet") || kind.contains("thunderbolt") || kind.contains("usb") { return "cable.connector.horizontal" }
                return "network"
            }()
            tiles = [
                MetricTileModel(symbol: Symbols.upload, label: "Uploading", value: ready ? Format.rate(network.uploadBytesPerSecond).text : dash),
                MetricTileModel(symbol: "chart.bar.xaxis", label: "Last 7 Days", value: ready ? Format.total(totals.networkInLast7Days).text : dash, help: "Downloaded in the last 7 days."),
                MetricTileModel(
                    symbol: interfaceSymbol,
                    label: "Interface",
                    value: ready ? (connected ? (network.interfaceKind.isEmpty ? network.interfaceName : network.interfaceKind) : "Offline") : dash,
                    detail: ready ? .text(connected ? network.interfaceName : "No connection") : .none
                ),
            ]
            list = MetricListModel(appMetric: .networkIn, historyMetric: .networkIn, title: "Downloading", historyTitle: "Most downloaded", historyValueTitle: "Downloaded", format: .rate, historyFormat: .total)

        case .gpu:
            let gpu = snapshot.gpu
            let chip = gpu.name.isEmpty ? snapshot.cpu.chipName : gpu.name
            caption = chip.isEmpty ? "GPU" : chip
            figure = ready ? Format.percent(gpu.utilizationPercent) : Figure(dash, "%")
            keyValues = [
                MetricKeyValue(label: "Average", value: ready ? Format.percent(totals.gpuAverageToday).text : dash, help: "Average GPU use today."),
                MetricKeyValue(label: "Peak", value: ready ? Format.percent(totals.gpuPeakToday).text : dash, help: "Highest GPU use today."),
            ]
            chart = MetricChartModel(name: "GPU", liveValues: live.gpu, liveDates: live.dates, historyMetrics: [.gpu], fixedMax: 100, autoFloor: 100, format: .percent)
            tiles = [
                MetricTileModel(symbol: TallyTab.memory.symbol, label: "Memory", value: ready ? Format.memory(gpu.memoryUsedBytes).text : dash, help: "Memory the GPU is using now."),
                MetricTileModel(symbol: "chart.bar.xaxis", label: "Average", value: ready ? Format.percent(totals.gpuAverageToday).text : dash, help: "Average GPU use today."),
                MetricTileModel(symbol: Symbols.power, label: "Peak", value: ready ? Format.percent(totals.gpuPeakToday).text : dash, help: "Highest GPU use today."),
            ]
            list = MetricListModel(appMetric: .gpu, historyMetric: .gpu, title: "GPU", historyTitle: "Most GPU", historyValueTitle: "Average", format: .appPercent, historyFormat: .appPercent)

        case .battery:
            let battery = snapshot.battery
            let sensors = snapshot.sensors
            let powerList = MetricListModel(appMetric: .power, historyMetric: .power, title: "Power", historyTitle: "Most energy", historyValueTitle: "Average", format: .power, historyFormat: .power)
            list = powerList
            if !ready || battery.hasBattery {
                caption = !ready ? "Battery" : (battery.isCharging ? "Charging" : (battery.isPluggedIn ? (battery.percent >= 99.5 ? "Fully charged" : "Plugged in") : "On battery"))
                figure = ready ? Format.percent(battery.percent) : Figure(dash, "%")
                let remainingLabel = battery.isCharging ? "Until full" : (battery.isPluggedIn ? "Adapter" : "Remaining")
                let remainingValue: String = {
                    guard ready else { return dash }
                    if battery.isPluggedIn && !battery.isCharging {
                        return battery.adapterWatts.map { "\($0) W" } ?? "Connected"
                    }
                    if let minutes = battery.timeRemainingMinutes, minutes > 0 { return Format.duration(minutes: minutes) }
                    return "Estimating"
                }()
                keyValues = [
                    MetricKeyValue(label: remainingLabel, value: remainingValue),
                    MetricKeyValue(label: "Cycles", value: ready ? Format.integer(Double(battery.cycleCount)) : dash, help: "Charge cycles counted by the battery."),
                ]
                chart = MetricChartModel(name: "Battery charge", liveValues: live.battery, liveDates: live.dates, historyMetrics: [.battery], fixedMax: 100, autoFloor: 100, format: .percent)
                let capacityHelp = battery.designCapacitymAh > 0 ? "\(Format.integer(Double(battery.maxCapacitymAh))) of \(Format.integer(Double(battery.designCapacitymAh))) mAh design capacity." : nil
                tiles = [
                    MetricTileModel(symbol: Symbols.power, label: "Power Draw", value: ready ? Format.power(battery.powerDrawWatts).text : dash, help: battery.isPluggedIn ? "Power the Mac draws from the adapter." : "Power the Mac draws from the battery."),
                    MetricTileModel(symbol: TallyTab.battery.symbol, label: "Health", value: ready && battery.healthPercent > 0 ? Format.percent(battery.healthPercent).text : dash, detail: .meter(Self.rounded(battery.healthPercent / 100)), help: capacityHelp),
                    MetricTileModel(symbol: Symbols.temperature, label: "Temperature", value: ready && battery.temperatureCelsius > 0 ? Format.temperature(battery.temperatureCelsius, unit: temperatureUnit).text : dash, help: "Battery temperature."),
                ]
            } else {
                caption = "Power draw"
                figure = Format.power(battery.powerDrawWatts)
                keyValues = [
                    MetricKeyValue(label: "Source", value: battery.adapterWatts.map { "\($0) W adapter" } ?? "AC power"),
                    MetricKeyValue(label: "Uptime", value: Self.uptime(snapshot.uptime)),
                ]
                chart = MetricChartModel(name: "Power draw", liveValues: live.power, liveDates: live.dates, historyMetrics: [.power], fixedMax: nil, autoFloor: 10, format: .power)
                let peak = live.power.max() ?? battery.powerDrawWatts
                tiles = [
                    MetricTileModel(symbol: Symbols.power, label: "Peak Draw", value: Format.power(peak).text, detail: .text("Last \(Self.liveSpan(live.dates))"), help: "Highest power draw in the live graph."),
                    MetricTileModel(symbol: Symbols.temperature, label: "CPU", value: sensors.cpuTemperatureCelsius.map { Format.temperature($0, unit: temperatureUnit).text } ?? dash, detail: .text("Temperature")),
                    MetricTileModel(symbol: Symbols.temperature, label: "GPU", value: sensors.gpuTemperatureCelsius.map { Format.temperature($0, unit: temperatureUnit).text } ?? dash, detail: .text("Temperature")),
                ]
            }

        default:
            let cpu = snapshot.cpu
            caption = "Now"
            figure = ready ? Format.percent(cpu.totalPercent) : Figure(dash, "%")
            keyValues = [
                MetricKeyValue(label: "Average today", value: ready ? Format.percent(totals.cpuAverageToday).text : dash),
                MetricKeyValue(label: "Load", value: ready ? String(format: "%.2f", cpu.loadAverage.first ?? 0) : dash, help: "Load average over the last minute: work running or waiting for the CPU."),
            ]
            chart = MetricChartModel(name: "CPU", liveValues: live.cpu, liveDates: live.dates, historyMetrics: [.cpu], fixedMax: 100, autoFloor: 100, format: .percent)
            var coreTags: [String] = []
            if cpu.performanceCores > 0 { coreTags.append("\(cpu.performanceCores) P") }
            if cpu.efficiencyCores > 0 { coreTags.append("\(cpu.efficiencyCores) E") }
            tiles = [
                MetricTileModel(symbol: TallyTab.cpu.symbol, label: "User", value: ready ? Format.percent(cpu.userPercent).text : dash, detail: .text("Your apps")),
                MetricTileModel(symbol: TallyTab.cpu.symbol, label: "System", value: ready ? Format.percent(cpu.systemPercent).text : dash, detail: .text("macOS")),
                MetricTileModel(symbol: Symbols.power, label: "Cores", value: ready && cpu.logicalCores > 0 ? "\(cpu.logicalCores)" : dash, detail: .tags(coreTags), help: coreTags.isEmpty ? nil : "\(cpu.performanceCores) performance and \(cpu.efficiencyCores) efficiency cores."),
            ]
            list = MetricListModel(appMetric: .cpu, historyMetric: .cpu, title: "CPU", historyTitle: "Most CPU", historyValueTitle: "Average", format: .appPercent, historyFormat: .appPercent)
        }
    }

    /// Per-app percent: "44.1%", "25%", "130%".
    static func appPercent(_ value: Double) -> String {
        let safe = value.isFinite ? max(0, value) : 0
        if safe >= 100 { return String(format: "%.0f%%", safe) }
        let text = String(format: "%.1f", safe)
        return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + "%"
    }

    /// A byte count from a chart or history value, which may be fractional or out of range.
    static func byteCount(_ value: Double) -> UInt64 {
        guard value.isFinite, value > 0 else { return 0 }
        return value >= Double(UInt64.max) ? UInt64.max : UInt64(value)
    }

    /// "64 GB", the way Apple quotes installed memory.
    static func wholeGigabytes(_ bytes: UInt64) -> String {
        let gigabytes = Double(bytes) / 1_073_741_824
        return gigabytes >= 1 ? String(format: "%.0f GB", gigabytes.rounded()) : Format.memory(bytes).text
    }

    static func fraction(_ part: UInt64, of total: UInt64) -> Double {
        total == 0 ? 0 : rounded(Double(part) / Double(total))
    }

    /// A 0...1 fraction to the nearest half percent, finer than a meter can show, so small changes do not redraw it.
    static func rounded(_ fraction: Double) -> Double {
        guard fraction.isFinite else { return 0 }
        return (min(max(fraction, 0), 1) * 200).rounded() / 200
    }

    static func uptime(_ seconds: TimeInterval) -> String {
        let text = Format.uptime(seconds)
        return text.hasPrefix("Up ") ? String(text.dropFirst(3)) : text
    }

    static func liveSpan(_ dates: [Date]) -> String {
        guard let first = dates.first, let last = dates.last else { return "minute" }
        return Format.span(max(60, last.timeIntervalSince(first)))
    }
}
