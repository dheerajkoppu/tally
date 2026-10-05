import Foundation
import TallyCore

/// One hour of whole-Mac history. `hour` counts hours of local time since 1970.
struct YearHourRow {
    var hour: Int64
    var seconds: Double
    /// CPU percent × seconds.
    var cpuSeconds: Double
    var hottest: Double?
    var networkIn: Double
    var networkOut: Double
    var diskWrite: Double
    var firstMinute: Int64
    var lastMinute: Int64
}

/// One app's year: CPU percent, bytes of memory and watts, each × seconds, and bytes moved.
struct YearAppRow {
    var key: String
    var name: String
    var bundlePath: String?
    var cpu: Double
    var memory: Double
    var power: Double
    var network: Double
}

extension YearSummary {
    static let topAppCount = 5
    /// A day, or an hour of the day, needs this much sampling to count as the busiest.
    private static let minimumBusySeconds: Double = 3600

    static func make(year: Int, hours: [YearHourRow], apps: [YearAppRow], offset: Int64, calendar: Calendar) -> YearSummary? {
        guard let first = hours.map(\.firstMinute).min(), let last = hours.map(\.lastMinute).max() else { return nil }
        var summary = YearSummary(
            year: year,
            firstDate: Date(timeIntervalSince1970: TimeInterval(first)),
            lastDate: Date(timeIntervalSince1970: TimeInterval(last))
        )

        var days: [Int64: Ratio] = [:]
        var hoursOfDay = [Ratio](repeating: Ratio(), count: 24)
        var cpu = Ratio()
        var networkIn = 0.0, networkOut = 0.0, diskWritten = 0.0
        for row in hours {
            let load = Ratio(numerator: row.cpuSeconds, denominator: row.seconds)
            days[row.hour / 24, default: Ratio()].add(load)
            hoursOfDay[Int(row.hour % 24)].add(load)
            cpu.add(load)
            networkIn += row.networkIn
            networkOut += row.networkOut
            diskWritten += row.diskWrite
            if let hottest = row.hottest { summary.hottestCelsius = max(summary.hottestCelsius ?? hottest, hottest) }
        }
        summary.activeSeconds = cpu.denominator
        summary.activeDays = days.count
        summary.cpuAverage = cpu.value ?? 0
        summary.networkInBytes = bytes(networkIn)
        summary.networkOutBytes = bytes(networkOut)
        summary.diskWrittenBytes = bytes(diskWritten)

        /// Noon of a day counted from 1970 in local time, clear of the hour daylight saving can move it by.
        func noon(of day: Int64) -> Date {
            Date(timeIntervalSince1970: TimeInterval(day * 86400 + 43200 - offset))
        }
        for (day, load) in days {
            let month = calendar.component(.month, from: noon(of: day))
            summary.monthlyHours[min(max(month - 1, 0), 11)] += load.denominator / 3600
        }
        let busiestDay = days
            .filter { $0.value.denominator >= minimumBusySeconds }
            .max { ($0.value.value ?? 0, $1.key) < ($1.value.value ?? 0, $0.key) }
        if let busiestDay {
            summary.busiestDay = noon(of: busiestDay.key)
            summary.busiestDayCPU = busiestDay.value.value ?? 0
        }
        summary.busiestHour = hoursOfDay.indices
            .filter { hoursOfDay[$0].denominator >= minimumBusySeconds }
            .max { (hoursOfDay[$0].value ?? 0) < (hoursOfDay[$1].value ?? 0) }

        // macOS itself would top every list, and Wrapped is about the apps someone chose to run. An app kept under
        // several paths (updates, build products) counts once, with the icon of the copy that ran the most.
        var merged: [String: YearAppRow] = [:]
        for row in apps.sorted(by: { $0.cpu > $1.cpu }) where row.key != "system" {
            guard var app = merged[row.name] else {
                merged[row.name] = row
                continue
            }
            app.cpu += row.cpu
            app.memory += row.memory
            app.power += row.power
            app.network += row.network
            merged[row.name] = app
        }
        let apps = Array(merged.values)
        summary.appCount = apps.count
        func total(_ row: YearAppRow, _ value: Double) -> HistoryAppTotal? {
            value > 0 && value.isFinite ? HistoryAppTotal(appID: row.key, name: row.name, bundlePath: row.bundlePath, value: value) : nil
        }
        func top(_ amount: (YearAppRow) -> Double, scale: Double) -> [HistoryAppTotal] {
            apps.sorted { amount($0) != amount($1) ? amount($0) > amount($1) : $0.name < $1.name }
                .prefix(topAppCount)
                .compactMap { total($0, amount($0) * scale) }
        }
        summary.topByCPU = top(\.cpu, scale: 1 / 100)
        summary.topByMemory = top(\.memory, scale: summary.activeSeconds > 0 ? 1 / summary.activeSeconds : 0).first
        summary.topByNetwork = top(\.network, scale: 1).first
        summary.topByEnergy = top(\.power, scale: 1 / 3600).first
        return summary
    }

    private static func bytes(_ value: Double) -> UInt64 {
        value.isFinite && value > 0 ? UInt64(value.rounded()) : 0
    }
}
