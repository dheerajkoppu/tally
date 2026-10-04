import SwiftUI
import TallyCore

/// The CPU, Memory, Disk, Network, GPU and Battery tabs.
/// Redrawn once per sample; every part is an equatable view, so only what changed is drawn again, and nothing animates.
public struct MetricTabView: View {
    private let tab: TallyTab

    @ObservedObject private var store = TallyStore.shared
    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var history = MetricHistoryModel()
    @State private var range: MetricRange
    @State private var showsAllApps = false
    @State private var quitRequest: QuitRequest?
    @State private var forceQuitRequest: QuitRequest?

    public init(tab: TallyTab) {
        self.tab = tab
        _range = State(initialValue: MetricRangeMemory.range)
    }

    public var body: some View {
        let content = MetricTabContent(tab: tab, store: store, settings: settings)
        let liveApps = sortedApps(for: content.list)
        let topApp = liveApps.first.flatMap { $0.value(for: content.list.appMetric) > 0 ? $0 : nil }
        VStack(spacing: Metrics.gridSpacing) {
            heroCard(content)
            HStack(spacing: Metrics.gridSpacing) {
                ForEach(content.tiles) { tile in
                    MetricStatTile(tile: tile, tint: tab.tint, isPlaceholder: content.isPlaceholder)
                        .equatable()
                }
                MetricTopAppTile(
                    appID: topApp?.id,
                    name: topApp?.name ?? "",
                    bundlePath: topApp?.bundlePath,
                    value: topApp.map { content.list.format.text($0.value(for: content.list.appMetric)) } ?? "",
                    tint: tab.tint,
                    isPlaceholder: !store.hasSample
                )
                .equatable()
            }
            if tab == .network {
                MetricConnectionsCard(network: store.snapshot.network, tint: tab.tint, isPlaceholder: !store.hasSample)
                    .equatable()
            }
            if tab == .disk, !store.snapshot.disk.drives.isEmpty {
                MetricDrivesCard(drives: store.snapshot.disk.drives, tint: tab.tint)
                    .equatable()
            }
            appList(content.list, liveApps: liveApps)
                .metricForceQuitConfirmation($forceQuitRequest, onDone: resample)
        }
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
        .quitConfirmation($quitRequest, onDone: resample)
        .announcesMemoryPressure(store.snapshot.memory.pressure)
        .onAppear { history.show(historyKey(content)) }
        .onChange(of: range) { _, newRange in
            MetricRangeMemory.range = newRange
            history.show(historyKey(content))
        }
        .onChange(of: store.snapshot.date) {
            history.refreshIfStale()
        }
    }

    private func historyKey(_ content: MetricTabContent) -> MetricHistoryModel.Key? {
        guard let historyRange = range.historyRange else { return nil }
        return MetricHistoryModel.Key(metrics: content.chart.historyMetrics, appMetric: content.list.historyMetric, range: historyRange)
    }

    /// The loaded history for the chosen range, if it matches.
    private var loadedHistory: MetricHistoryModel.Snapshot? {
        guard let historyRange = range.historyRange, let snapshot = history.snapshot, snapshot.key.range == historyRange else { return nil }
        return snapshot
    }

    private func heroCard(_ content: MetricTabContent) -> some View {
        HStack(alignment: .top, spacing: 20) {
            MetricHeroSummary(
                caption: content.caption,
                figure: content.figure,
                isPlaceholder: content.isPlaceholder,
                pressure: content.pressure,
                keyValues: content.keyValues
            )
            .equatable()

            VStack(alignment: .trailing, spacing: 6) {
                MetricRangePicker(label: "Range", items: MetricRange.all, selection: $range, tint: tab.tint, title: \.label)
                chart(content.chart)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity)
        .frame(height: MetricLayout.heroHeight)
        .metricSurface()
    }

    @ViewBuilder
    private func chart(_ model: MetricChartModel) -> some View {
        switch range {
        case .live:
            let points = MetricAreaChart.livePoints(model.liveValues, dates: model.liveDates, slots: MetricLayout.liveSlots)
            let dates = model.liveDates.suffix(MetricLayout.liveSlots)
            let data = MetricChartData(
                points: points,
                maxValue: model.scaleMax(for: points.map(\.value)),
                breakGap: nil,
                dateStyle: .seconds,
                format: model.format,
                name: model.name,
                span: "last \(MetricTabContent.liveSpan(Array(dates)))",
                isLive: true
            )
            MetricAreaChart(data: data, tint: tab.tint)
                .equatable()
        case .history(let historyRange):
            let loaded = loadedHistory
            let dateStyle: MetricChartDateStyle = historyRange.duration > 86400 ? .dayAndHour : .weekdayAndTime
            let points = MetricAreaChart.historyPoints(loaded?.points ?? [], range: historyRange, buckets: historyRange.metricBuckets, now: loaded?.loadedAt ?? Date())
            let data = MetricChartData(
                points: points,
                maxValue: model.scaleMax(for: points.map(\.value)),
                breakGap: 2.5 / Double(historyRange.metricBuckets),
                dateStyle: dateStyle,
                format: model.format,
                name: model.name,
                span: historyRange.metricPhrase,
                isLive: false
            )
            MetricAreaChart(data: data, tint: tab.tint)
                .equatable()
                .overlay {
                    if let loaded, loaded.points.count < 2 {
                        MetricNoHistory(range: historyRange)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if let first = points.first, points.count >= 2, first.position > 0.22, let date = first.date {
                        Text("Recorded since \(MetricAreaChart.dateText(date, style: dateStyle))")
                            .font(Typography.caption)
                            .foregroundStyle(Palette.ink2)
                            .padding(.top, 6)
                            .allowsHitTesting(false)
                    }
                }
        }
    }

    private func appList(_ list: MetricListModel, liveApps: [AppUsage]) -> some View {
        let limit = showsAllApps ? Int.max : MetricLayout.visibleApps
        switch range {
        case .live:
            let top = max(liveApps.first.map { $0.value(for: list.appMetric) } ?? 0, list.format.meterFloor)
            let rows = liveApps.prefix(limit).map { app in
                let value = app.value(for: list.appMetric)
                return MetricAppRowModel(app: app, value: list.format.text(value), fraction: top > 0 ? value / top : 0)
            }
            return MetricAppListCard(
                title: "App",
                valueTitle: list.title,
                rows: rows,
                totalCount: liveApps.count,
                tint: tab.tint,
                isPlaceholder: !store.hasSample,
                emptyMessage: "No apps running",
                showsAll: $showsAllApps,
                actions: actions
            )
        case .history(let historyRange):
            let loaded = loadedHistory
            let totals = loaded?.topApps ?? []
            let top = max(totals.first?.value ?? 0, list.historyFormat.meterFloor)
            let rows = totals.prefix(limit).map { total in
                MetricAppRowModel(
                    total: total,
                    running: store.app(withID: total.appID),
                    value: list.historyFormat.text(total.value),
                    fraction: top > 0 ? total.value / top : 0
                )
            }
            return MetricAppListCard(
                title: "\(list.historyTitle), \(historyRange.metricPhrase)",
                valueTitle: list.historyValueTitle,
                isHistory: true,
                rows: rows,
                totalCount: totals.count,
                tint: tab.tint,
                isPlaceholder: loaded == nil,
                emptyMessage: "No history yet",
                showsAll: $showsAllApps,
                actions: actions
            )
        }
    }

    private var actions: MetricAppActions {
        let store = store
        let quit = $quitRequest
        let forceQuit = $forceQuitRequest
        return MetricAppActions(
            inspect: { AppRouter.shared.inspectedAppID = $0 },
            quit: { appID in
                if let app = store.app(withID: appID) { quit.wrappedValue = .app(app) }
            },
            forceQuit: { appID in
                if let app = store.app(withID: appID) { forceQuit.wrappedValue = QuitRequest.app(app).metricForced }
            }
        )
    }

    /// Every app, largest first; ties keep a steady order so idle rows do not shuffle.
    private func sortedApps(for list: MetricListModel) -> [AppUsage] {
        store.apps.sorted { first, second in
            let firstValue = first.value(for: list.appMetric)
            let secondValue = second.value(for: list.appMetric)
            if firstValue != secondValue { return firstValue > secondValue }
            if first.memoryBytes != second.memoryBytes { return first.memoryBytes > second.memoryBytes }
            return first.id < second.id
        }
    }

    private func resample() {
        AppRouter.shared.engine?.sampleNow()
    }
}

/// Shown over an empty history chart.
struct MetricNoHistory: View {
    let range: HistoryRange

    @Environment(\.accessibilityReduceTransparency) private var reducesTransparency

    var body: some View {
        VStack(spacing: 3) {
            Text("No history yet")
                .font(Typography.emptyTitle)
                .foregroundStyle(Palette.ink2)
            Text("Tally records while it runs, so the \(range.label) view fills in over time.")
                .font(Typography.rowSubtitle)
                .foregroundStyle(Palette.ink2)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(Palette.card.opacity(reducesTransparency ? 1 : 0.9), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
