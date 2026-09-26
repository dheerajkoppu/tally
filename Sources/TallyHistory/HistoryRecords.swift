import Foundation
import TallyCore

/// A sum and the weight it is divided by. Levels: value × seconds over seconds. Rates: bytes over seconds.
struct Ratio {
    var numerator: Double = 0
    var denominator: Double = 0

    var value: Double? { denominator > 0 ? numerator / denominator : nil }

    mutating func add(_ other: Ratio) {
        numerator += other.numerator
        denominator += other.denominator
    }
}

extension HistoryMetric {
    /// Bytes per second, stored as bytes moved per minute.
    var isRate: Bool {
        switch self {
        case .diskRead, .diskWrite, .networkIn, .networkOut: true
        default: false
        }
    }

    var systemColumn: String {
        switch self {
        case .cpu: "cpu"
        case .memory: "memory"
        case .gpu: "gpu"
        case .diskRead: "disk_read"
        case .diskWrite: "disk_write"
        case .networkIn: "network_in"
        case .networkOut: "network_out"
        case .battery: "battery"
        case .power: "power"
        case .cpuTemperature: "cpu_temperature"
        }
    }

    /// Battery and temperature belong to the whole Mac, so apps have no column for them.
    var appColumn: String? {
        switch self {
        case .battery, .cpuTemperature: nil
        default: systemColumn
        }
    }
}

private func finite(_ value: Double) -> Double {
    value.isFinite ? value : 0
}

/// Rates are clamped so a counter glitch cannot overflow the byte columns.
private func rate(_ value: Double) -> Double {
    min(max(0, finite(value)), 1e12)
}

/// One app within one minute. Levels are integrals (value × seconds), rates are bytes.
struct AppMinute {
    var name: String
    var bundlePath: String?
    var cpu: Double = 0
    var memory: Double = 0
    var gpu: Double = 0
    var power: Double = 0
    var diskRead: Double = 0
    var diskWrite: Double = 0
    var networkIn: Double = 0
    var networkOut: Double = 0

    init(name: String, bundlePath: String?) {
        self.name = name
        self.bundlePath = bundlePath
    }

    /// Each metric with the average below which an app is not worth a row (percent, bytes, watts, bytes per second).
    static let rankedMetrics: [(value: KeyPath<AppMinute, Double>, floor: Double)] = [
        (\.cpu, 0.05), (\.memory, 16 * 1_048_576), (\.gpu, 0.05), (\.power, 0.005),
        (\.diskRead, 100), (\.diskWrite, 100), (\.networkIn, 100), (\.networkOut, 100),
    ]

    mutating func add(_ app: AppUsage, interval: Double) {
        name = app.name
        bundlePath = app.bundlePath
        cpu += max(0, finite(app.cpuPercent)) * interval
        memory += Double(app.memoryBytes) * interval
        gpu += max(0, finite(app.gpuPercent)) * interval
        power += max(0, finite(app.powerWatts)) * interval
        diskRead += rate(app.diskReadBytesPerSecond) * interval
        diskWrite += rate(app.diskWriteBytesPerSecond) * interval
        networkIn += rate(app.networkInBytesPerSecond) * interval
        networkOut += rate(app.networkOutBytesPerSecond) * interval
    }

    /// The integral for a level metric, or the bytes for a rate metric.
    func amount(for metric: HistoryMetric) -> Double {
        switch metric {
        case .cpu: cpu
        case .memory: memory
        case .gpu: gpu
        case .power: power
        case .diskRead: diskRead
        case .diskWrite: diskWrite
        case .networkIn: networkIn
        case .networkOut: networkOut
        case .battery, .cpuTemperature: 0
        }
    }
}

/// Everything recorded within one wall-clock minute, kept in memory until it is written.
struct MinuteRecord {
    /// Unix time of the minute's start.
    let minute: Int64
    /// Distinguishes two records for the same minute (after a flush, or a clock change).
    let sequence: UInt64
    /// Seconds of sampling this minute covers.
    var seconds: Double = 0
    var cpu: Double = 0
    var memory: Double = 0
    var gpu: Double = 0
    var gpuPeak: Double = 0
    var battery: Double = 0
    var batterySeconds: Double = 0
    var power: Double = 0
    var powerSeconds: Double = 0
    var temperature: Double = 0
    var temperatureSeconds: Double = 0
    var diskRead: Double = 0
    var diskWrite: Double = 0
    var networkIn: Double = 0
    var networkOut: Double = 0
    var apps: [String: AppMinute] = [:]

    init(minute: Int64, sequence: UInt64) {
        self.minute = minute
        self.sequence = sequence
    }

    mutating func add(_ snapshot: SystemSnapshot, interval: Double) {
        seconds += interval
        cpu += max(0, finite(snapshot.cpu.totalPercent)) * interval
        memory += Double(snapshot.memory.usedBytes) * interval
        let gpuPercent = max(0, finite(snapshot.gpu.utilizationPercent))
        gpu += gpuPercent * interval
        gpuPeak = max(gpuPeak, gpuPercent)
        if snapshot.battery.hasBattery {
            battery += finite(snapshot.battery.percent) * interval
            batterySeconds += interval
        }
        let watts = finite(snapshot.battery.powerDrawWatts)
        if snapshot.battery.hasBattery || watts > 0 {
            power += max(0, watts) * interval
            powerSeconds += interval
        }
        if let celsius = snapshot.sensors.cpuTemperatureCelsius, celsius.isFinite, celsius > 0 {
            temperature += celsius * interval
            temperatureSeconds += interval
        }
        diskRead += rate(snapshot.disk.readBytesPerSecond) * interval
        diskWrite += rate(snapshot.disk.writeBytesPerSecond) * interval
        networkIn += rate(snapshot.network.downloadBytesPerSecond) * interval
        networkOut += rate(snapshot.network.uploadBytesPerSecond) * interval
    }

    mutating func add(apps usage: [AppUsage], interval: Double) {
        for app in usage {
            apps[app.id, default: AppMinute(name: app.name, bundlePath: app.bundlePath)].add(app, interval: interval)
        }
    }

    /// The same numerator and denominator the database computes for a stored minute.
    func systemRatio(for metric: HistoryMetric) -> Ratio {
        switch metric {
        case .cpu: Ratio(numerator: cpu, denominator: seconds)
        case .memory: Ratio(numerator: memory, denominator: seconds)
        case .gpu: Ratio(numerator: gpu, denominator: seconds)
        case .battery: Ratio(numerator: battery, denominator: batterySeconds)
        case .power: Ratio(numerator: power, denominator: powerSeconds)
        case .cpuTemperature: Ratio(numerator: temperature, denominator: temperatureSeconds)
        case .diskRead: Ratio(numerator: diskRead, denominator: seconds)
        case .diskWrite: Ratio(numerator: diskWrite, denominator: seconds)
        case .networkIn: Ratio(numerator: networkIn, denominator: seconds)
        case .networkOut: Ratio(numerator: networkOut, denominator: seconds)
        }
    }

    func average(_ integral: Double, over weight: Double) -> Double? {
        weight > 0 ? integral / weight : nil
    }

    /// The apps worth storing: those in the top `limit` for any metric this minute, above a negligible floor.
    func retainedApps(limit: Int) -> [(key: String, usage: AppMinute)] {
        guard seconds > 0 else { return [] }
        var kept = Set<String>()
        for metric in AppMinute.rankedMetrics {
            let minimum = metric.floor * seconds
            let ranked = apps.filter { $0.value[keyPath: metric.value] > minimum }
                .sorted { $0.value[keyPath: metric.value] > $1.value[keyPath: metric.value] }
                .prefix(limit)
            for entry in ranked { kept.insert(entry.key) }
        }
        return kept.compactMap { key in apps[key].map { (key: key, usage: $0) } }
    }
}

/// Evenly sized buckets ending just after now, with edges aligned to local time so charts hold still.
struct BucketWindow {
    let count: Int
    let width: Double
    let start: Double
    let end: Double
    /// 60 when reading minute rows, 3600 when reading hourly rows; rows are placed by the start of their slot.
    let granularity: Int64

    init(range: HistoryRange, buckets: Int, now: Date, granularity: Int64) {
        count = min(max(buckets, 1), 1440)
        width = range.duration / Double(count)
        self.granularity = granularity
        let offset = Double(TimeZone.current.secondsFromGMT(for: now))
        let local = now.timeIntervalSince1970 + offset
        end = (floor(local / width) + 1) * width - offset
        start = end - width * Double(count)
    }

    /// The first row timestamp to read: the slot that contains `start`.
    var queryStart: Int64 {
        Int64(floor(start / Double(granularity))) * granularity
    }

    var queryEnd: Int64 {
        Int64(ceil(end))
    }

    func index(forMinute minute: Int64) -> Int? {
        guard minute >= queryStart, Double(minute) < end else { return nil }
        let slot = Double((minute / granularity) * granularity)
        let raw = Int(floor((slot - start) / width))
        return min(max(raw, 0), count - 1)
    }

    func clamp(_ index: Int) -> Int {
        min(max(index, 0), count - 1)
    }

    func date(ofBucket index: Int) -> Date {
        Date(timeIntervalSince1970: start + Double(index) * width)
    }

    /// Points for buckets with data. Rate metrics read zero across gaps between the first and last bucket with data.
    func points(from ratios: [Int: Ratio], zeroFillGaps: Bool) -> [HistoryPoint] {
        let filled = ratios.filter { $0.value.denominator > 0 }.keys
        guard let first = filled.min(), let last = filled.max() else { return [] }
        var points: [HistoryPoint] = []
        points.reserveCapacity(last - first + 1)
        for index in first...last {
            if let value = ratios[index]?.value {
                points.append(HistoryPoint(date: date(ofBucket: index), value: max(0, value)))
            } else if zeroFillGaps {
                points.append(HistoryPoint(date: date(ofBucket: index), value: 0))
            }
        }
        return points
    }
}
