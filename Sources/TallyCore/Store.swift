import Foundation
import Combine

/// Ring buffers of recent samples for live charts, oldest first.
public struct LiveSeries: Sendable {
    public static let capacity = 240

    public var dates: [Date] = []
    public var cpu: [Double] = []
    public var cpuUser: [Double] = []
    public var cpuSystem: [Double] = []
    public var memoryUsed: [Double] = []
    public var gpu: [Double] = []
    public var diskRead: [Double] = []
    public var diskWrite: [Double] = []
    public var networkIn: [Double] = []
    public var networkOut: [Double] = []
    public var battery: [Double] = []
    public var power: [Double] = []
    public var cpuTemperature: [Double] = []
    public var gpuTemperature: [Double] = []

    public init() {}

    public mutating func append(_ snapshot: SystemSnapshot) {
        func push(_ array: inout [Double], _ value: Double) {
            array.append(value)
            if array.count > Self.capacity { array.removeFirst(array.count - Self.capacity) }
        }
        dates.append(snapshot.date)
        if dates.count > Self.capacity { dates.removeFirst(dates.count - Self.capacity) }
        push(&cpu, snapshot.cpu.totalPercent)
        push(&cpuUser, snapshot.cpu.userPercent)
        push(&cpuSystem, snapshot.cpu.systemPercent)
        push(&memoryUsed, Double(snapshot.memory.usedBytes))
        push(&gpu, snapshot.gpu.utilizationPercent)
        push(&diskRead, snapshot.disk.readBytesPerSecond)
        push(&diskWrite, snapshot.disk.writeBytesPerSecond)
        push(&networkIn, snapshot.network.downloadBytesPerSecond)
        push(&networkOut, snapshot.network.uploadBytesPerSecond)
        push(&battery, snapshot.battery.percent)
        push(&power, snapshot.battery.powerDrawWatts)
        push(&cpuTemperature, snapshot.sensors.cpuTemperatureCelsius ?? 0)
        push(&gpuTemperature, snapshot.sensors.gpuTemperatureCelsius ?? 0)
    }

    public func values(for metric: HistoryMetric) -> [Double] {
        switch metric {
        case .cpu: cpu
        case .memory: memoryUsed
        case .gpu: gpu
        case .diskRead: diskRead
        case .diskWrite: diskWrite
        case .networkIn: networkIn
        case .networkOut: networkOut
        case .battery: battery
        case .power: power
        case .cpuTemperature: cpuTemperature
        }
    }

    /// The last `count` values, left-padded with the first value so bar charts keep a steady width.
    public func recent(_ metric: HistoryMetric, count: Int) -> [Double] {
        let all = values(for: metric)
        if all.count >= count { return Array(all.suffix(count)) }
        return Array(repeating: all.first ?? 0, count: count - all.count) + all
    }
}

/// The single source of truth the UI observes. Updated on the main thread by `SamplingEngine`.
@MainActor
public final class TallyStore: ObservableObject {
    public static let shared = TallyStore()

    @Published public private(set) var snapshot = SystemSnapshot()
    /// Every app, sorted by memory, largest first.
    @Published public private(set) var apps: [AppUsage] = []
    @Published public private(set) var processes: [ProcessSample] = []
    @Published public private(set) var live = LiveSeries()
    @Published public private(set) var projects: [Project] = []
    @Published public private(set) var alerts: [AlertItem] = []
    @Published public private(set) var totals = UsageTotals()
    @Published public private(set) var hasSample = false

    /// Set once at launch by the app target. Query it off the main thread for long ranges.
    public var history: HistoryProviding?
    public var alertEvaluator: AlertEvaluating?

    public init() {}

    public var processCount: Int { processes.count }

    public func apply(snapshot: SystemSnapshot, processSnapshot: ProcessSnapshot, projects: [Project]?, alerts: [AlertItem]?, totals: UsageTotals?) {
        var live = self.live
        live.append(snapshot)
        apply(snapshot: snapshot, live: live, processSnapshot: processSnapshot, projects: projects, alerts: alerts, totals: totals)
    }

    /// One update per engine tick. Only what changed is assigned, so unchanged lists never notify their observers.
    /// `processSnapshot` is nil on ticks that sampled only the whole Mac; its apps must already be sorted by memory.
    public func apply(snapshot: SystemSnapshot, live: LiveSeries, processSnapshot: ProcessSnapshot?, projects: [Project]?, alerts: [AlertItem]?, totals: UsageTotals?) {
        self.snapshot = snapshot
        self.live = live
        if let processSnapshot {
            processes = processSnapshot.processes
            apps = processSnapshot.apps
        }
        if let projects, projects != self.projects { self.projects = projects }
        if let alerts, alerts != self.alerts { self.alerts = alerts }
        if let totals, totals != self.totals { self.totals = totals }
        if !hasSample { hasSample = true }
    }

    /// Apps sorted by a metric, largest first.
    public func topApps(by metric: AppMetric, limit: Int = .max) -> [AppUsage] {
        Array(apps.sorted { $0.value(for: metric) > $1.value(for: metric) }.prefix(limit))
    }

    public func app(withID id: String) -> AppUsage? {
        apps.first { $0.id == id }
    }

    public func dismiss(_ alert: AlertItem) {
        alerts.removeAll { $0.id == alert.id }
        alertEvaluator?.dismiss(alert)
    }
}
