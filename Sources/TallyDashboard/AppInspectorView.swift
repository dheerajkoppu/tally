import SwiftUI
import TallyCore

/// One app's processes, figures and history, shown as a sheet.
public struct AppInspectorView: View {
    private let appID: String

    @ObservedObject private var store = TallyStore.shared
    @StateObject private var model: InspectorModel
    @State private var metric: InspectorMetric = .cpu
    @State private var range: MetricRange = .history(.hours12)
    @State private var sort: InspectorSort = .cpu
    @State private var quitRequest: QuitRequest?
    @State private var forceQuitRequest: QuitRequest?

    public init(appID: String) {
        self.appID = appID
        _model = StateObject(wrappedValue: InspectorModel(appID: appID, store: TallyStore.shared))
    }

    public var body: some View {
        let current = store.app(withID: appID)
        let app = current ?? model.lastKnown
        VStack(spacing: 0) {
            header(current: current, app: app)
                .equatable()
            Rectangle()
                .fill(Palette.line)
                .frame(height: 1)
            if InspectorRenderMode.isHeadless {
                details(current: current)
            } else {
                ScrollView {
                    details(current: current)
                }
                .scrollIndicators(.automatic)
            }
        }
        .frame(width: InspectorRenderMode.isHeadless ? nil : 640, height: InspectorRenderMode.isHeadless ? nil : 620, alignment: .top)
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
        .quitConfirmation($quitRequest, onDone: resample)
        .onAppear { model.chart.show(chartKey) }
        .onChange(of: store.snapshot.date) { _, date in
            model.record(store.app(withID: appID), at: date)
        }
        .onChange(of: InspectorHistoryKey(range: range, metric: metric)) {
            model.chart.show(chartKey)
        }
    }

    private var chartKey: InspectorChartModel.Key? {
        range.historyRange.map { InspectorChartModel.Key(range: $0, metric: metric) }
    }

    private func header(current: AppUsage?, app: AppUsage?) -> InspectorHeader {
        let store = store
        let appID = appID
        let quit = $quitRequest
        let forceQuit = $forceQuitRequest
        return InspectorHeader(
            appID: appID,
            bundlePath: app?.bundlePath,
            name: app?.name ?? InspectorModel.displayName(for: appID),
            identity: Self.identity(of: app, appID: appID),
            isRunning: current != nil,
            hasSample: store.hasSample,
            wasSeen: app != nil,
            processCount: current?.processCount ?? 0,
            isSystem: app?.kind == .system,
            canQuit: current != nil && MetricAppMenu.canQuit(current),
            onQuit: {
                if let app = store.app(withID: appID) { quit.wrappedValue = .app(app) }
            },
            onForceQuit: {
                if let app = store.app(withID: appID) { forceQuit.wrappedValue = QuitRequest.app(app).metricForced }
            },
            onDone: { AppRouter.shared.inspectedAppID = nil }
        )
    }

    private func details(current: AppUsage?) -> some View {
        let store = store
        let appID = appID
        let quit = $quitRequest
        let forceQuit = $forceQuitRequest
        func process(_ pid: Int32) -> ProcessSample? {
            store.app(withID: appID)?.processes.first { $0.pid == pid }
        }
        return VStack(spacing: 14) {
            InspectorFigureGrid(app: current, snapshot: store.snapshot)
                .equatable()
            InspectorHistoryCard(model: model.chart, metric: $metric, range: $range)
            InspectorProcessTable(
                processes: current?.processes ?? [],
                isRunning: current != nil,
                wasRunning: model.lastKnown != nil,
                sort: $sort,
                onQuit: { pid in
                    if let process = process(pid) { quit.wrappedValue = .process(process) }
                },
                onForceQuit: { pid in
                    if let process = process(pid) { forceQuit.wrappedValue = QuitRequest.process(process).metricForced }
                }
            )
        }
        .padding(20)
        .metricForceQuitConfirmation($forceQuitRequest, onDone: resample)
    }

    private static func identity(of app: AppUsage?, appID: String) -> String {
        if let app {
            if app.kind == .system { return "Processes that are part of macOS" }
            if let bundle = app.bundleIdentifier, !bundle.isEmpty { return bundle }
            if let path = app.bundlePath ?? app.processes.first?.executablePath { return path }
        }
        return appID
    }

    private func resample() {
        AppRouter.shared.engine?.sampleNow()
    }
}
