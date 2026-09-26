import Foundation
import Combine

/// Drives every sampler on one background queue and publishes results to `TallyStore`.
///
/// While a window or the menu bar panel is visible it takes a full sample at the user's update interval. With nothing
/// on screen it takes only the cheap whole-Mac sample the menu bar item shows, every max(interval, 5) seconds (every
/// 15 when the item is just an icon), and leaves per-app figures, history, alerts and sensors to every 15 seconds and
/// projects to every 30. Low Power Mode doubles every interval. Work runs at utility QoS while visible and background
/// QoS otherwise.
public final class SamplingEngine {
    public static let minimumBackgroundInterval: TimeInterval = 5
    static let backgroundProcessInterval: TimeInterval = 15
    static let backgroundSensorInterval: TimeInterval = 15
    static let backgroundProjectInterval: TimeInterval = 30
    static let totalsInterval: TimeInterval = 60
    /// How long a tick waits for the project scan it started before publishing without it.
    static let projectScanWait: DispatchTimeInterval = .milliseconds(100)
    private static let panelReason = "menubar-panel"

    private let store: TallyStore
    private let system: SystemSampling
    private let processes: ProcessSampling
    private let sensors: SensorSampling
    private let history: HistoryProviding?
    private let alerts: AlertEvaluating?
    private let projects: ProjectScanning?

    /// No QoS of its own, so each block runs at the QoS it is submitted with.
    private let queue = DispatchQueue(label: "tally.sampling")
    private let projectQueue = DispatchQueue(label: "tally.sampling.projects")
    private var timer: DispatchSourceTimer?
    private var tickInterval: TimeInterval = 0
    private var tickIsVisible = false

    private var visibleInterval: TimeInterval = 5
    private var fastReasons = Set<String>()
    private var isLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    private var selectedTab: TallyTab = .overview
    private var isInspectingApp = false
    /// The menu bar item shows figures that change with every sample, rather than just the icon.
    private var menuBarShowsFigures = true
    private var appliedDemand: SamplingDemand?

    private var live = LiveSeries()
    private var lastSensors = SensorStats()
    private var latestProcesses: [ProcessSample]?
    private var lastProcessSample = -Double.infinity
    private var lastSensorRead = -Double.infinity
    private var lastProjectScan = -Double.infinity
    private var lastTotals = -Double.infinity

    /// Project scans run on their own queue so a folder behind a privacy prompt never stalls sampling.
    private let projectLock = NSLock()
    private var isScanningProjects = false
    private var scannedProjects: [Project]?

    private var powerObserver: NSObjectProtocol?
    private var cancellables = Set<AnyCancellable>()

    public init(store: TallyStore, system: SystemSampling, processes: ProcessSampling, sensors: SensorSampling, history: HistoryProviding?, alerts: AlertEvaluating?, projects: ProjectScanning?) {
        self.store = store
        self.system = system
        self.processes = processes
        self.sensors = sensors
        self.history = history
        self.alerts = alerts
        self.projects = projects
    }

    deinit {
        if let powerObserver { NotificationCenter.default.removeObserver(powerObserver) }
        timer?.cancel()
    }

    public func start() {
        powerObserver = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: nil) { [weak self] _ in
            let isLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            self?.perform(.utility) { engine in
                engine.isLowPower = isLowPower
                engine.reschedule()
            }
        }
        observeNavigation()
        perform(.utility) { engine in
            engine.tick(full: true)
            engine.reschedule()
        }
    }

    /// Ask for sampling at the update interval while a view is visible. Balanced by `endFastSampling`.
    public func beginFastSampling(_ reason: String) {
        perform(.utility) { engine in
            let wasVisible = !engine.fastReasons.isEmpty
            engine.fastReasons.insert(reason)
            engine.reschedule()
            // Something just came on screen: give it fresh figures now rather than at the next tick.
            if !wasVisible { engine.tick(full: true) }
        }
    }

    public func endFastSampling(_ reason: String) {
        perform(.utility) { engine in
            engine.fastReasons.remove(reason)
            engine.reschedule()
        }
    }

    /// Seconds between samples while a window or panel is visible.
    public func setUpdateInterval(_ interval: TimeInterval) {
        perform(.utility) { engine in
            engine.visibleInterval = max(1, interval)
            engine.reschedule()
        }
    }

    /// Sample right away, for example after quitting an app.
    public func sampleNow() {
        perform(.utility) { engine in engine.tick(full: true) }
    }

    private func perform(_ qos: DispatchQoS, _ body: @escaping (SamplingEngine) -> Void) {
        queue.async(qos: qos, flags: .enforceQoS) { [weak self] in
            if let self { body(self) }
        }
    }

    /// Per-app network figures are worth a fresh nettop run more often only while they may be on screen, and the
    /// whole-Mac sample is worth taking more often than the per-app one only while the menu bar item shows figures.
    private func observeNavigation() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                AppSettings.shared.$menuBarStyle
                    .combineLatest(AppSettings.shared.$showInMenuBar)
                    .map { style, isShown in isShown && style != .icon }
                    .removeDuplicates()
                    .sink { [weak self] showsFigures in
                        self?.perform(.utility) { engine in
                            engine.menuBarShowsFigures = showsFigures
                            engine.reschedule()
                        }
                    }
                    .store(in: &self.cancellables)
                let router = AppRouter.shared
                router.$tab.combineLatest(router.$inspectedAppID.map { $0 != nil })
                    .removeDuplicates { $0 == $1 }
                    .sink { [weak self] tab, isInspecting in
                        self?.perform(.utility) { engine in
                            engine.selectedTab = tab
                            engine.isInspectingApp = isInspecting
                        }
                    }
                    .store(in: &self.cancellables)
            }
        }
    }

    private func currentDemand() -> SamplingDemand {
        let isVisible = !fastReasons.isEmpty
        let showsAppNetwork = fastReasons.contains(Self.panelReason) || (isVisible && (selectedTab == .network || isInspectingApp))
        return SamplingDemand(isVisible: isVisible, showsAppNetwork: showsAppNetwork, isLowPower: isLowPower)
    }

    private func reschedule() {
        let isVisible = !fastReasons.isEmpty
        let scale = isLowPower ? 2.0 : 1.0
        let backgroundInterval = menuBarShowsFigures ? max(visibleInterval, Self.minimumBackgroundInterval) : Self.backgroundProcessInterval
        let interval = (isVisible ? visibleInterval : backgroundInterval) * scale
        guard timer == nil || interval != tickInterval || isVisible != tickIsVisible else { return }
        tickInterval = interval
        tickIsVisible = isVisible
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // Generous leeway lets macOS batch this wakeup with others, more of it while nothing is on screen.
        let leeway = interval * (isVisible ? 0.1 : 0.5)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(Int(leeway * 1000)))
        timer.setEventHandler(handler: DispatchWorkItem(qos: isVisible ? .utility : .background, flags: .enforceQoS) { [weak self] in
            self?.tick(full: false)
        })
        timer.resume()
        self.timer = timer
    }

    private func tick(full: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        let demand = currentDemand()
        if demand != appliedDemand {
            appliedDemand = demand
            let samplers: [AnyObject?] = [system, processes, sensors, history, alerts, projects]
            for sampler in samplers { (sampler as? DemandAware)?.setDemand(demand) }
        }
        let samplesEverything = full || demand.isVisible
        // A task is due a little early rather than a whole tick late.
        func isDue(_ last: TimeInterval, every interval: TimeInterval) -> Bool {
            let scaled = interval * demand.intervalScale
            return now - last >= scaled - min(tickInterval * 0.5, scaled * 0.25)
        }

        var snapshot = system.sample()
        snapshot.date = Date()
        if samplesEverything || isDue(lastSensorRead, every: Self.backgroundSensorInterval) {
            lastSensors = sensors.read()
            lastSensorRead = now
        }
        snapshot.sensors = lastSensors
        live.append(snapshot)

        var processSnapshot: ProcessSnapshot?
        var currentAlerts: [AlertItem]?
        if samplesEverything || isDue(lastProcessSample, every: Self.backgroundProcessInterval) {
            let sampled = processes.sample()
            processSnapshot = sampled
            latestProcesses = sampled.processes
            lastProcessSample = now
            history?.record(snapshot: snapshot, apps: sampled.apps)
            currentAlerts = alerts?.evaluate(snapshot: snapshot, apps: sampled.apps)
        } else {
            (history as? SystemHistoryRecording)?.recordSystem(snapshot: snapshot)
        }

        if let projects, let latestProcesses, samplesEverything || isDue(lastProjectScan, every: Self.backgroundProjectInterval),
           startProjectScan(projects, processes: latestProcesses, qos: demand.isVisible ? .utility : .background) {
            lastProjectScan = now
        }
        let newProjects = takeScannedProjects()

        var totals: UsageTotals?
        if let history, demand.isVisible, full || now - lastTotals >= Self.totalsInterval * demand.intervalScale {
            totals = history.totals()
            lastTotals = now
        }

        let store = self.store
        let live = self.live
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                store.apply(snapshot: snapshot, live: live, processSnapshot: processSnapshot, projects: newProjects, alerts: currentAlerts, totals: totals)
            }
        }
    }

    /// Starts a scan unless one is still running, and waits briefly so a quick scan lands in this tick's update.
    private func startProjectScan(_ scanner: ProjectScanning, processes: [ProcessSample], qos: DispatchQoS) -> Bool {
        projectLock.lock()
        guard !isScanningProjects else {
            projectLock.unlock()
            return false
        }
        isScanningProjects = true
        projectLock.unlock()

        let finished = DispatchSemaphore(value: 0)
        projectQueue.async(qos: qos, flags: .enforceQoS) { [weak self] in
            let found = scanner.scan(processes: processes)
            if let self {
                projectLock.lock()
                scannedProjects = found
                isScanningProjects = false
                projectLock.unlock()
            }
            finished.signal()
        }
        _ = finished.wait(timeout: .now() + Self.projectScanWait)
        return true
    }

    private func takeScannedProjects() -> [Project]? {
        projectLock.lock()
        defer { projectLock.unlock() }
        let found = scannedProjects
        scannedProjects = nil
        return found
    }
}
