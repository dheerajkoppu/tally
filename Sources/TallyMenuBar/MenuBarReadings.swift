import Foundation
import TallyCore

/// One metric as the menu bar item shows it.
struct MenuBarReading: Equatable {
    var metric: MenuBarMetric
    /// The figure style text: "59%", "↓ 1.2 MB/s", "63°".
    var text: String
    /// The shorter value used under a caption in the stacked style.
    var compactText: String
    var spokenText: String
}

enum MenuBarReadings {
    static let graphSampleCount = 10

    static func reading(for metric: MenuBarMetric, snapshot: SystemSnapshot, unit: TemperatureUnit) -> MenuBarReading {
        switch metric {
        case .cpu:
            let text = Format.percent(snapshot.cpu.totalPercent).text
            return MenuBarReading(metric: metric, text: text, compactText: text, spokenText: "CPU \(text)")
        case .memory:
            let text = Format.percent(snapshot.memory.usedFraction * 100).text
            return MenuBarReading(metric: metric, text: text, compactText: text, spokenText: "Memory \(text) used")
        case .gpu:
            let text = Format.percent(snapshot.gpu.utilizationPercent).text
            return MenuBarReading(metric: metric, text: text, compactText: text, spokenText: "GPU \(text)")
        case .network:
            let download = Format.rate(snapshot.network.downloadBytesPerSecond).text
            let upload = Format.rate(snapshot.network.uploadBytesPerSecond).text
            return MenuBarReading(metric: metric, text: "↓ \(download)", compactText: download, spokenText: "Network download \(download), upload \(upload)")
        case .temperature:
            guard let celsius = snapshot.sensors.cpuTemperatureCelsius else {
                return MenuBarReading(metric: metric, text: "–°", compactText: "–°", spokenText: "CPU temperature unavailable")
            }
            let text = Format.temperature(celsius, unit: unit).text
            let spokenUnit = unit == .celsius ? "Celsius" : "Fahrenheit"
            return MenuBarReading(metric: metric, text: text, compactText: text, spokenText: "CPU temperature \(text) \(spokenUnit)")
        case .battery:
            guard snapshot.battery.hasBattery else {
                return MenuBarReading(metric: metric, text: "–%", compactText: "–%", spokenText: "No battery")
            }
            let text = Format.percent(snapshot.battery.percent).text
            let state = snapshot.battery.isCharging ? ", charging" : ""
            return MenuBarReading(metric: metric, text: text, compactText: text, spokenText: "Battery \(text)\(state)")
        }
    }

    /// The last few values of a metric as whole bar heights from 0 to `levels`, oldest first,
    /// so the graph only redraws when a bar visibly changes.
    static func barLevels(for metric: MenuBarMetric, snapshot: SystemSnapshot, live: LiveSeries, levels: Int) -> [UInt8] {
        let series: [Double]
        let top: Double
        switch metric {
        case .cpu:
            series = live.recent(.cpu, count: graphSampleCount)
            top = max(series.max() ?? 0, 20)
        case .memory:
            series = live.recent(.memory, count: graphSampleCount)
            top = max(Double(snapshot.memory.totalBytes), series.max() ?? 0, 1)
        case .gpu:
            series = live.recent(.gpu, count: graphSampleCount)
            top = max(series.max() ?? 0, 20)
        case .network:
            series = live.recent(.networkIn, count: graphSampleCount)
            top = max(series.max() ?? 0, 50_000)
        case .temperature:
            series = live.recent(.cpuTemperature, count: graphSampleCount)
            top = max(series.max() ?? 0, 100)
        case .battery:
            series = live.recent(.battery, count: graphSampleCount)
            top = 100
        }
        return series.map { value in
            let fraction = min(max(value.isFinite ? value / top : 0, 0), 1)
            return UInt8((fraction * Double(levels)).rounded())
        }
    }

    /// The widest text a metric shows in everyday use. The item reserves this width so it does not
    /// shift the other menu bar items each time a figure gains or loses a digit.
    static func widthTemplate(for metric: MenuBarMetric, compact: Bool) -> String {
        switch metric {
        case .cpu, .memory, .gpu, .battery: "00%"
        case .temperature: "00°"
        case .network: compact ? "000 kB/s" : "↓ 000 kB/s"
        }
    }
}

enum StrainLevel: Hashable {
    case warning, critical
}

struct Strain: Equatable {
    var level: StrainLevel
    /// Every reason the Mac counts as under strain, for the tooltip.
    var reasons: [String]
}

/// Decides when the menu bar item turns into a warning sign.
struct StrainMonitor {
    static let sustainedCPUPercent: Double = 90
    static let sustainedCPUDuration: TimeInterval = 30
    static let hotCPUCelsius: Double = 95
    static let lowBatteryPercent: Double = 10

    private var busyCPUSince: Date?

    /// Call with every new snapshot, in order, so sustained CPU load is timed correctly.
    mutating func evaluate(_ snapshot: SystemSnapshot) -> Strain? {
        guard snapshot.date != .distantPast else { return nil }
        var reasons: [String] = []
        var level: StrainLevel = .warning

        if snapshot.cpu.totalPercent >= Self.sustainedCPUPercent {
            let since = busyCPUSince ?? snapshot.date
            busyCPUSince = since
            let duration = snapshot.date.timeIntervalSince(since)
            if duration >= Self.sustainedCPUDuration {
                let spoken = duration < 60 ? "\(Int(duration)) seconds" : Format.span(duration)
                reasons.append("CPU at \(Format.percent(snapshot.cpu.totalPercent).text) for \(spoken)")
            }
        } else {
            busyCPUSince = nil
        }

        switch snapshot.memory.pressure {
        case .normal:
            break
        case .warning:
            reasons.append("Memory pressure is elevated")
        case .critical:
            reasons.append("Memory pressure is critical")
            level = .critical
        }

        if let celsius = snapshot.sensors.cpuTemperatureCelsius, celsius >= Self.hotCPUCelsius {
            reasons.append("CPU temperature \(Format.temperature(celsius).text)C")
            level = .critical
        }

        let battery = snapshot.battery
        if battery.hasBattery, battery.percent <= Self.lowBatteryPercent, !battery.isCharging {
            reasons.append("Battery at \(Format.percent(battery.percent).text)")
            level = .critical
        }

        return reasons.isEmpty ? nil : Strain(level: level, reasons: reasons)
    }
}
