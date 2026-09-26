import Foundation

// Each subsystem target provides one concrete type conforming to one of these.
// All methods are called on the sampling engine's background queue unless noted.

/// CPU, memory, disk, network, GPU and battery for the whole Mac. Stateful: rates come from deltas between calls.
public protocol SystemSampling: AnyObject {
    /// Returns everything except `sensors`, which the engine fills from `SensorSampling`.
    func sample() -> SystemSnapshot
}

/// Every process, with per-process rates, grouped into apps.
public protocol ProcessSampling: AnyObject {
    func sample() -> ProcessSnapshot
}

/// Temperatures, fans and Bluetooth peripheral batteries.
public protocol SensorSampling: AnyObject {
    /// Called every few seconds. Implementations cache anything slow (peripheral batteries) internally.
    func read() -> SensorStats
}

/// 30 days of history, stored on disk.
public protocol HistoryProviding: AnyObject {
    /// Called on every engine tick. Implementations aggregate in memory and write about once a minute.
    func record(snapshot: SystemSnapshot, apps: [AppUsage])
    /// Evenly bucketed points for a chart. Safe to call from any thread.
    func series(_ metric: HistoryMetric, range: HistoryRange, buckets: Int) -> [HistoryPoint]
    /// The apps that used the most of a metric over a range. Safe to call from any thread.
    func topApps(_ metric: HistoryMetric, range: HistoryRange, limit: Int) -> [HistoryAppTotal]
    /// One app's history for a metric. Safe to call from any thread.
    func appSeries(appID: String, metric: HistoryMetric, range: HistoryRange, buckets: Int) -> [HistoryPoint]
    func totals() -> UsageTotals
    func clearAll()
}

/// Watches apps for misbehaviour, posts notifications and returns the current "Worth a Look" list.
public protocol AlertEvaluating: AnyObject {
    func evaluate(snapshot: SystemSnapshot, apps: [AppUsage]) -> [AlertItem]
    func dismiss(_ alert: AlertItem)
}

/// Finds dev servers and processes with listening ports, grouped by project folder.
public protocol ProjectScanning: AnyObject {
    func scan(processes: [ProcessSample]) -> [Project]
}
