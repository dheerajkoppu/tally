import Foundation
import TallyCore

/// Wraps the history provider for use off the main thread. HistoryProviding is documented as safe from any thread.
struct MetricHistorySource: @unchecked Sendable {
    let provider: HistoryProviding

    /// Series for one or more metrics, summed bucket by bucket.
    func series(_ metrics: [HistoryMetric], range: HistoryRange, buckets: Int) -> [HistoryPoint] {
        var sums: [Date: Double] = [:]
        for metric in metrics {
            for point in provider.series(metric, range: range, buckets: buckets) where point.value.isFinite {
                sums[point.date, default: 0] += point.value
            }
        }
        return sums.map { HistoryPoint(date: $0.key, value: $0.value) }.sorted { $0.date < $1.date }
    }

    func topApps(_ metric: HistoryMetric, range: HistoryRange, limit: Int) -> [HistoryAppTotal] {
        provider.topApps(metric, range: range, limit: limit).filter { $0.value.isFinite && $0.value > 0 }
    }

    func appSeries(appID: String, metric: HistoryMetric, range: HistoryRange, buckets: Int) -> [HistoryPoint] {
        provider.appSeries(appID: appID, metric: metric, range: range, buckets: buckets)
            .filter { $0.value.isFinite }
            .sorted { $0.date < $1.date }
    }
}

/// History for one metric tab: the chart series and the apps that used the most.
/// Results are cached per tab and range, shared across tab switches, and reloaded at most once a minute,
/// only while that range is on screen and only when a sample arrives, so history adds no timers of its own.
@MainActor
final class MetricHistoryModel: ObservableObject {
    struct Key: Hashable {
        var metrics: [HistoryMetric]
        var appMetric: HistoryMetric
        var range: HistoryRange
    }

    struct Snapshot: Equatable {
        var key: Key
        var points: [HistoryPoint]
        var topApps: [HistoryAppTotal]
        /// Charts place buckets against this date, so a cached chart stays put between reloads.
        var loadedAt: Date
    }

    static let refreshInterval: TimeInterval = 60

    private static var cache: [Key: Snapshot] = [:]
    private static var loading = Set<Key>()

    @Published private(set) var snapshot: Snapshot?
    private var key: Key?

    /// Shows a range (nil for live), from the cache when it has one.
    func show(_ key: Key?) {
        self.key = key
        let cached = key.flatMap { Self.cache[$0] }
        if snapshot != cached { snapshot = cached }
        refreshIfStale()
    }

    /// Reloads the shown range if it is older than a minute. Called on each sample.
    func refreshIfStale() {
        guard let key, !Self.loading.contains(key) else { return }
        let cached = Self.cache[key]
        if let cached, Date().timeIntervalSince(cached.loadedAt) < Self.refreshInterval { return }
        guard let provider = TallyStore.shared.history else {
            let empty = Snapshot(key: key, points: [], topApps: [], loadedAt: Date())
            Self.cache[key] = empty
            snapshot = empty
            return
        }
        Self.loading.insert(key)
        let source = MetricHistorySource(provider: provider)
        let priority: TaskPriority = cached == nil ? .userInitiated : .utility
        Task { [weak self] in
            let loaded = await Task.detached(priority: priority) {
                Snapshot(
                    key: key,
                    points: source.series(key.metrics, range: key.range, buckets: key.range.metricBuckets),
                    topApps: source.topApps(key.appMetric, range: key.range, limit: 100),
                    loadedAt: Date()
                )
            }.value
            Self.loading.remove(key)
            Self.cache[key] = loaded
            if let self, self.key == key { self.snapshot = loaded }
        }
    }
}
