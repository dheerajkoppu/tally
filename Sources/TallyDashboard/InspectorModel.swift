import Foundation
import SwiftUI
import TallyCore

/// The figure the inspector's history chart shows.
enum InspectorMetric: String, CaseIterable, Identifiable {
    case cpu, memory, power

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .power: "Power"
        }
    }

    var historyMetric: HistoryMetric {
        switch self {
        case .cpu: .cpu
        case .memory: .memory
        case .power: .power
        }
    }

    var tint: Color {
        switch self {
        case .cpu: Palette.cpu
        case .memory: Palette.memory
        case .power: Palette.battery
        }
    }

    /// The smallest top of scale, so an idle app draws a flat line near the bottom.
    var floor: Double {
        switch self {
        case .cpu: 10
        case .memory: 100 * 1_048_576
        case .power: 1
        }
    }

    var format: MetricValueFormat {
        switch self {
        case .cpu: .appPercent
        case .memory: .memory
        case .power: .power
        }
    }

    func value(of sample: InspectorSample) -> Double {
        switch self {
        case .cpu: sample.cpuPercent
        case .memory: sample.memoryBytes
        case .power: sample.powerWatts
        }
    }
}

struct InspectorSample: Equatable {
    var date: Date
    var cpuPercent: Double
    var memoryBytes: Double
    var powerWatts: Double
}

enum InspectorSort: String {
    case cpu, memory
}

struct InspectorHistoryKey: Hashable {
    var range: MetricRange
    var metric: InspectorMetric
}

/// State for one inspector sheet. Publishes nothing itself: the sheet redraws on every sample anyway,
/// and only the history card, which observes `chart`, redraws when samples or history arrive.
@MainActor
final class InspectorModel: ObservableObject {
    let appID: String
    /// The app as last seen, so the header still names it after it quits.
    private(set) var lastKnown: AppUsage?
    let chart: InspectorChartModel

    init(appID: String, store: TallyStore) {
        self.appID = appID
        chart = InspectorChartModel(appID: appID)
        record(store.app(withID: appID), at: store.snapshot.date)
    }

    func record(_ app: AppUsage?, at date: Date) {
        if let app {
            lastKnown = app
            chart.append(InspectorSample(date: date, cpuPercent: app.cpuPercent, memoryBytes: Double(app.memoryBytes), powerWatts: app.powerWatts))
        }
        chart.refreshIfStale()
    }

    /// A readable name for an app that is not running: "Google Chrome" from its bundle path.
    static func displayName(for appID: String) -> String {
        if appID == "system" { return "macOS" }
        let last = (appID as NSString).lastPathComponent
        if last.hasSuffix(".app") { return String(last.dropLast(4)) }
        return last.isEmpty ? appID : last
    }
}

/// Samples taken while the sheet is open, and the app's stored history for the chosen range and metric,
/// cached per range and metric and reloaded at most once a minute when a sample arrives.
@MainActor
final class InspectorChartModel: ObservableObject {
    struct Key: Hashable {
        var range: HistoryRange
        var metric: InspectorMetric
    }

    struct History: Equatable {
        var key: Key
        var points: [HistoryPoint]
        var loadedAt: Date
    }

    static let liveCapacity = 120

    let appID: String
    @Published private(set) var samples: [InspectorSample] = []
    @Published private(set) var history: History?

    private var key: Key?
    private var cache: [Key: History] = [:]
    private var loading = Set<Key>()

    init(appID: String) {
        self.appID = appID
    }

    func append(_ sample: InspectorSample) {
        guard sample.date != samples.last?.date else { return }
        var updated = samples
        updated.append(sample)
        if updated.count > Self.liveCapacity { updated.removeFirst(updated.count - Self.liveCapacity) }
        samples = updated
    }

    /// Shows a range and metric (nil key for live), from the cache when it has one.
    func show(_ key: Key?) {
        self.key = key
        let cached = key.flatMap { cache[$0] }
        if history != cached { history = cached }
        refreshIfStale()
    }

    func refreshIfStale() {
        guard let key, !loading.contains(key) else { return }
        let cached = cache[key]
        if let cached, Date().timeIntervalSince(cached.loadedAt) < MetricHistoryModel.refreshInterval { return }
        guard let provider = TallyStore.shared.history else {
            let empty = History(key: key, points: [], loadedAt: Date())
            cache[key] = empty
            history = empty
            return
        }
        loading.insert(key)
        let source = MetricHistorySource(provider: provider)
        let appID = appID
        let priority: TaskPriority = cached == nil ? .userInitiated : .utility
        Task { [weak self] in
            let points = await Task.detached(priority: priority) {
                source.appSeries(appID: appID, metric: key.metric.historyMetric, range: key.range, buckets: key.range.metricBuckets)
            }.value
            guard let self else { return }
            let loaded = History(key: key, points: points, loadedAt: Date())
            loading.remove(key)
            cache[key] = loaded
            if self.key == key { history = loaded }
        }
    }
}

/// True while the headless render harness draws views to PNG, which cannot draw scroll views.
enum InspectorRenderMode {
    static let isHeadless = CommandLine.arguments.contains("--render")
}
