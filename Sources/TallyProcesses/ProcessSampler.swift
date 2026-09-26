import Foundation
import TallyCore

/// Every process with per-process rates, grouped under the app it belongs to.
///
/// Rates come from deltas between calls, kept per process instance (pid plus start time) so a reused pid
/// never produces a spike. libproc covers this user's processes on every sample. Everything slower is cached and
/// refreshed on its own schedule off the sampling path, and between refreshes each process keeps the rate measured
/// last time: other users' processes through /bin/ps once a minute, their footprints through top every ten minutes
/// while something is on screen, per-process network through nettop every 15 seconds while it may be on screen
/// (every minute otherwise), and GPU time from the IORegistry every 5 seconds while visible (30 otherwise).
public final class ProcessSampler: ProcessSampling, DemandAware {
    private struct ProcessState {
        var command: CommandName
        var shortName = ""
        var executablePath: String?
        var executableName: String?
        var responsiblePid: Int32?
        var cpuTicks: UInt64 = 0
        var diskReadBytes: UInt64 = 0
        var diskWrittenBytes: UInt64 = 0
        var energyNanojoules: UInt64 = 0
        var restrictedCPUSeconds: Double?
        var restrictedCPUPercent: Double = 0
        var restrictedResidentBytes: UInt64 = 0
        var networkBytesIn: UInt64?
        var networkBytesOut: UInt64?
        var networkInRate: Double = 0
        var networkOutRate: Double = 0
        /// Went through at least one nettop reading, so traffic missing from it was really zero.
        var hasNetworkBaseline = false
        var gpuNanoseconds: UInt64?
        var gpuPercent: Double = 0
        var threadCount = 0
        var lastSeen = 0

        init(command: CommandName) {
            self.command = command
        }
    }

    private enum Tool: Hashable {
        case restricted, footprint, network
    }

    /// Output of the helper tools, written from the tool queue and read by the next sample.
    private final class ToolResults: @unchecked Sendable {
        let lock = NSLock()
        var running = Set<Tool>()
        var restricted: [Int32: RestrictedFigures] = [:]
        var restrictedStamp: UInt64 = 0
        var restrictedDate = Date.distantPast
        var restrictedGeneration = 0
        var footprints: [Int32: UInt64] = [:]
        var footprintDate: Date?
        var network: [Int32: NetworkUsageReader.Totals] = [:]
        var networkStamp: UInt64 = 0
        var networkDate = Date.distantPast
        var networkGeneration = 0
    }

    private static let second: UInt64 = 1_000_000_000
    private static let restrictedInterval = 60 * second
    /// The second ps and nettop readings come soon after launch, so rates appear quickly.
    private static let warmupInterval = 4 * second
    private static let footprintInterval = 600 * second
    private static let networkIntervalOnScreen = 15 * second
    private static let networkIntervalOffScreen = 60 * second
    private static let gpuIntervalVisible = 5 * second
    private static let gpuIntervalHidden = 30 * second
    /// ps lists every thread only on some runs: counting threads doubles its cost.
    private static let threadCountEvery = 5
    private static let minimumInterval: TimeInterval = 0.25
    private static let firstToolWait: DispatchTimeInterval = .milliseconds(500)

    private let lock = NSLock()
    private let catalog = BundleCatalog()
    private let runningApplications = RunningApplications()
    private let processTable = ProcessTable()
    private let grouper: AppGrouper
    private let toolQueue = DispatchQueue(label: "tally.processes.tools", attributes: .concurrent)
    private let toolGroup = DispatchGroup()
    private let tools = ToolResults()
    private let currentUID = getuid()

    private var demand = SamplingDemand()
    private var states: [ProcessKey: ProcessState] = [:]
    private var generation = 0
    private var lastSampleNanoseconds: UInt64 = 0
    private var lastSampleDate: Date?
    /// Watts one fully busy core draws, learned from processes that report energy. Estimates power for those that do not.
    private var wattsPerBusyCore = 1.5

    private var appliedRestrictedGeneration = 0
    private var lastRestrictedStamp: UInt64 = 0
    private var lastRestrictedDate: Date?
    private var appliedNetworkGeneration = 0
    private var lastNetworkStamp: UInt64 = 0
    private var lastNetworkDate: Date?
    private var lastGPUStamp: UInt64 = 0

    private var restrictedRuns = 0
    private var networkRuns = 0
    private var lastRestrictedStart: UInt64 = 0
    private var lastFootprintStart: UInt64 = 0
    private var lastNetworkStart: UInt64 = 0

    public init() {
        grouper = AppGrouper(catalog: catalog, runningApplications: runningApplications)
    }

    public func setDemand(_ demand: SamplingDemand) {
        lock.lock()
        self.demand = demand
        lock.unlock()
    }

    public func sample() -> ProcessSnapshot {
        lock.lock()
        defer { lock.unlock() }
        if lastSampleNanoseconds == 0 {
            // The first figures need a baseline to diff against, and a first ps reading for other users' processes.
            _ = collect()
            Thread.sleep(forTimeInterval: Self.minimumInterval)
            _ = toolGroup.wait(timeout: .now() + Self.firstToolWait)
        } else {
            // Rates over a sliver of time are mostly noise, for example when asked again right after a tick.
            let elapsed = Double(MachClock.nowNanoseconds() &- lastSampleNanoseconds) / 1e9
            if elapsed < Self.minimumInterval { Thread.sleep(forTimeInterval: Self.minimumInterval - elapsed) }
        }
        return collect()
    }

    private func collect() -> ProcessSnapshot {
        generation += 1
        let now = MachClock.nowNanoseconds()
        let date = Date()
        let hasBaseline = lastSampleNanoseconds != 0
        let wallNanoseconds = hasBaseline ? Double(now &- lastSampleNanoseconds) : 0
        let wallSeconds = wallNanoseconds / 1e9
        let intervalStart = lastSampleDate
        let isVisible = demand.isVisible

        runningApplications.refreshIfNeeded(now: now)
        let identities = processTable.read()

        let gpuInterval = (isVisible ? Self.gpuIntervalVisible : Self.gpuIntervalHidden) * UInt64(demand.intervalScale)
        let gpuTimes = Self.isDue(since: lastGPUStamp, every: gpuInterval, now: now) ? GPUUsageReader.accumulatedNanoseconds() : nil
        let gpuWallNanoseconds = gpuTimes != nil && lastGPUStamp != 0 ? Double(now &- lastGPUStamp) : 0
        if gpuTimes != nil { lastGPUStamp = now }

        var samples: [ProcessSample] = []
        var inputs: [GroupingInput] = []
        var keys: [ProcessKey] = []
        var restrictedIndices: [Int] = []
        var restrictedCandidates: [Int32] = []
        samples.reserveCapacity(identities.count)
        inputs.reserveCapacity(identities.count)
        keys.reserveCapacity(identities.count)

        var measuredEnergyNanojoules: Double = 0
        var measuredCPUNanoseconds: Double = 0
        var estimatedPowerIndices: [Int] = []

        for identity in identities where identity.pid > 0 && !identity.isZombie {
            let pid = identity.pid
            let key = ProcessKey(pid: pid, startMicroseconds: identity.startMicroseconds)
            let existing = states[key]
            var state: ProcessState
            if let existing, existing.command == identity.command {
                state = existing
            } else {
                // New process, or the same process after exec: its image and name changed.
                state = existing ?? ProcessState(command: identity.command)
                state.command = identity.command
                state.shortName = identity.command.string
                state.executablePath = ProcessInfoReader.executablePath(of: pid)
                state.executableName = state.executablePath.map { ($0 as NSString).lastPathComponent }
                state.responsiblePid = ProcessInfoReader.responsiblePid(of: pid)
            }
            let startDate = identity.startDate
            let startedDuringInterval = intervalStart.map { (startDate ?? .distantPast) >= $0 } ?? false
            // Counters of a process seen for the first time start from zero only if it began during this interval.
            let countsFromZero = hasBaseline && startedDuringInterval

            var sample = ProcessSample(
                pid: pid,
                parentPid: identity.parentPid,
                responsiblePid: state.responsiblePid ?? pid,
                uid: identity.uid,
                name: state.shortName,
                executablePath: state.executablePath
            )
            sample.startDate = startDate

            // libproc refuses other users' processes, so do not ask.
            let isOtherUser = currentUID != 0 && identity.uid != currentUID
            switch isOtherUser ? .denied : ProcessInfoReader.usage(of: pid) {
            case .gone:
                continue
            case .usage(let usage):
                let cpuTicks = usage.ri_user_time &+ usage.ri_system_time
                if existing == nil {
                    state.cpuTicks = countsFromZero ? 0 : cpuTicks
                    state.diskReadBytes = countsFromZero ? 0 : usage.ri_diskio_bytesread
                    state.diskWrittenBytes = countsFromZero ? 0 : usage.ri_diskio_byteswritten
                    state.energyNanojoules = countsFromZero ? 0 : usage.ri_energy_nj
                }
                let hasRun = existing == nil || cpuTicks != state.cpuTicks
                let cpuNanoseconds = MachClock.nanoseconds(fromTicks: Self.delta(cpuTicks, since: state.cpuTicks))
                let energy = Double(Self.delta(usage.ri_energy_nj, since: state.energyNanojoules))
                if wallNanoseconds > 0 {
                    sample.cpuPercent = cpuNanoseconds / wallNanoseconds * 100
                    sample.diskReadBytesPerSecond = Double(Self.delta(usage.ri_diskio_bytesread, since: state.diskReadBytes)) / wallSeconds
                    sample.diskWriteBytesPerSecond = Double(Self.delta(usage.ri_diskio_byteswritten, since: state.diskWrittenBytes)) / wallSeconds
                    // Nanojoules over nanoseconds is watts.
                    sample.powerWatts = energy / wallNanoseconds
                }
                if usage.ri_energy_nj > 0 {
                    measuredEnergyNanojoules += energy
                    measuredCPUNanoseconds += cpuNanoseconds
                } else {
                    // Macs without per-process energy accounting (Intel) report zero.
                    estimatedPowerIndices.append(samples.count)
                }
                state.cpuTicks = cpuTicks
                state.diskReadBytes = usage.ri_diskio_bytesread
                state.diskWrittenBytes = usage.ri_diskio_byteswritten
                state.energyNanojoules = usage.ri_energy_nj
                sample.memoryBytes = usage.ri_phys_footprint
                sample.cpuTimeSeconds = MachClock.nanoseconds(fromTicks: cpuTicks) / 1e9
                // Thread counts are only shown on screen, and a process that has not run cannot have made threads.
                if isVisible, hasRun || state.threadCount == 0, let threads = ProcessInfoReader.threadCount(of: pid) {
                    state.threadCount = threads
                }
                sample.threadCount = state.threadCount
            case .denied:
                sample.isRestricted = true
                restrictedIndices.append(samples.count)
                estimatedPowerIndices.append(samples.count)
                restrictedCandidates.append(pid)
            }

            if let gpuTimes {
                if let gpuTime = gpuTimes[pid] {
                    // A client created since the last reading has only new GPU time on it.
                    let previous = state.gpuNanoseconds ?? (existing != nil || countsFromZero ? 0 : gpuTime)
                    state.gpuPercent = gpuWallNanoseconds > 0 ? min(100, Double(Self.delta(gpuTime, since: previous)) / gpuWallNanoseconds * 100) : 0
                    state.gpuNanoseconds = gpuTime
                } else {
                    state.gpuNanoseconds = nil
                    state.gpuPercent = 0
                }
            }
            sample.gpuPercent = state.gpuPercent
            sample.networkInBytesPerSecond = state.networkInRate
            sample.networkOutBytesPerSecond = state.networkOutRate

            state.lastSeen = generation
            states[key] = state
            samples.append(sample)
            keys.append(key)
            inputs.append(GroupingInput(
                pid: pid,
                parentPid: identity.parentPid,
                uid: identity.uid,
                executablePath: state.executablePath,
                executableName: state.executableName,
                responsiblePid: state.responsiblePid == pid ? nil : state.responsiblePid,
                fallbackName: state.shortName
            ))
        }

        tools.lock.lock()
        let restrictedGeneration = tools.restrictedGeneration
        let restricted = restrictedGeneration != appliedRestrictedGeneration ? tools.restricted : nil
        let restrictedStamp = tools.restrictedStamp
        let restrictedDate = tools.restrictedDate
        let footprints = tools.footprints
        let footprintDate = tools.footprintDate
        let networkGeneration = tools.networkGeneration
        let network = networkGeneration != appliedNetworkGeneration ? tools.network : nil
        let networkStamp = tools.networkStamp
        let networkDate = tools.networkDate
        tools.lock.unlock()

        applyRestricted(restricted, stamp: restrictedStamp, footprints: footprints, footprintDate: footprintDate, to: &samples, keys: keys, indices: restrictedIndices)
        if restricted != nil {
            appliedRestrictedGeneration = restrictedGeneration
            lastRestrictedStamp = restrictedStamp
            lastRestrictedDate = restrictedDate
        }
        if let network {
            applyNetwork(network, stamp: networkStamp, to: &samples, keys: keys)
            appliedNetworkGeneration = networkGeneration
            lastNetworkStamp = networkStamp
            lastNetworkDate = networkDate
        }

        if measuredCPUNanoseconds > 0.05 * 1e9, measuredEnergyNanojoules > 0 {
            wattsPerBusyCore = wattsPerBusyCore * 0.8 + measuredEnergyNanojoules / measuredCPUNanoseconds * 0.2
        }
        for index in estimatedPowerIndices {
            samples[index].powerWatts = samples[index].cpuPercent / 100 * wattsPerBusyCore
        }

        var staleKeys: [ProcessKey] = []
        for (key, state) in states where state.lastSeen != generation { staleKeys.append(key) }
        for key in staleKeys { states.removeValue(forKey: key) }
        lastSampleNanoseconds = now
        lastSampleDate = date

        startToolsIfDue(now: now, restrictedCandidates: restrictedCandidates)
        return snapshot(from: samples, inputs: inputs)
    }

    private static func isDue(since last: UInt64, every interval: UInt64, now: UInt64) -> Bool {
        // A tenth of slack keeps a run from slipping a whole tick behind timer jitter.
        last == 0 || now &- last >= interval - interval / 10
    }

    private static func delta(_ current: UInt64, since previous: UInt64) -> UInt64 {
        current >= previous ? current - previous : 0
    }

    /// Starts every helper tool that is due and not already running. None of them blocks the sample.
    private func startToolsIfDue(now: UInt64, restrictedCandidates: [Int32]) {
        let scale = UInt64(demand.intervalScale)
        let isVisible = demand.isVisible
        let qos: DispatchQoS = isVisible ? .utility : .background

        let restrictedInterval = restrictedRuns < 2 ? Self.warmupInterval : Self.restrictedInterval * scale
        if RestrictedProcessReader.isAvailable, !restrictedCandidates.isEmpty,
           Self.isDue(since: lastRestrictedStart, every: restrictedInterval, now: now), claim(.restricted) {
            lastRestrictedStart = now
            restrictedRuns += 1
            let countsThreads = isVisible && restrictedRuns % Self.threadCountEvery == 2
            toolQueue.async(group: toolGroup, qos: qos, flags: .enforceQoS) { [tools] in
                let stamp = MachClock.nowNanoseconds()
                let date = Date()
                let figures = RestrictedProcessReader.read(pids: restrictedCandidates, countingThreads: countsThreads)
                tools.lock.lock()
                if let figures {
                    tools.restricted = figures
                    tools.restrictedStamp = stamp
                    tools.restrictedDate = date
                    tools.restrictedGeneration += 1
                }
                tools.running.remove(.restricted)
                tools.lock.unlock()
            }
        }

        // top costs about a third of a CPU second and only refines figures people are looking at.
        if isVisible, FootprintReader.isAvailable, currentUID != 0,
           Self.isDue(since: lastFootprintStart, every: Self.footprintInterval * scale, now: now), claim(.footprint) {
            lastFootprintStart = now
            toolQueue.async(qos: qos, flags: .enforceQoS) { [tools] in
                let date = Date()
                let footprints = FootprintReader.read()
                tools.lock.lock()
                if let footprints {
                    tools.footprints = footprints
                    tools.footprintDate = date
                }
                tools.running.remove(.footprint)
                tools.lock.unlock()
            }
        }

        let networkInterval = networkRuns < 2 ? Self.warmupInterval : (demand.showsAppNetwork ? Self.networkIntervalOnScreen : Self.networkIntervalOffScreen) * scale
        if NetworkUsageReader.isAvailable, Self.isDue(since: lastNetworkStart, every: networkInterval, now: now), claim(.network) {
            lastNetworkStart = now
            networkRuns += 1
            toolQueue.async(qos: qos, flags: .enforceQoS) { [tools] in
                let stamp = MachClock.nowNanoseconds()
                let date = Date()
                let totals = NetworkUsageReader.read()
                tools.lock.lock()
                if let totals {
                    tools.network = totals
                    tools.networkStamp = stamp
                    tools.networkDate = date
                    tools.networkGeneration += 1
                }
                tools.running.remove(.network)
                tools.lock.unlock()
            }
        }
    }

    private func claim(_ tool: Tool) -> Bool {
        tools.lock.lock()
        defer { tools.lock.unlock() }
        return tools.running.insert(tool).inserted
    }

    /// Other users' processes: CPU from the last two ps readings, memory from top's footprint when it has one.
    private func applyRestricted(_ figures: [Int32: RestrictedFigures]?, stamp: UInt64, footprints: [Int32: UInt64], footprintDate: Date?, to samples: inout [ProcessSample], keys: [ProcessKey], indices: [Int]) {
        let intervalNanoseconds = lastRestrictedStamp == 0 || figures == nil ? 0 : Double(stamp &- lastRestrictedStamp)
        let previousReading = lastRestrictedDate
        for index in indices {
            let key = keys[index]
            guard var state = states[key] else { continue }
            if let figures {
                if let figure = figures[key.pid] {
                    let startedSinceReading = previousReading.map { (samples[index].startDate ?? .distantPast) >= $0 } ?? false
                    let previous = state.restrictedCPUSeconds ?? (startedSinceReading ? 0 : figure.cpuSeconds)
                    if intervalNanoseconds > 0, figure.cpuSeconds >= previous {
                        state.restrictedCPUPercent = (figure.cpuSeconds - previous) * 1e9 / intervalNanoseconds * 100
                    }
                    state.restrictedCPUSeconds = figure.cpuSeconds
                    state.restrictedResidentBytes = figure.residentBytes
                    if let threads = figure.threadCount { state.threadCount = threads }
                } else {
                    state.restrictedCPUSeconds = nil
                    state.restrictedCPUPercent = 0
                }
                states[key] = state
            }
            samples[index].cpuPercent = state.restrictedCPUPercent
            samples[index].cpuTimeSeconds = state.restrictedCPUSeconds ?? 0
            if let footprintDate, let footprint = footprints[key.pid], (samples[index].startDate ?? .distantFuture) <= footprintDate {
                samples[index].memoryBytes = footprint
            } else {
                samples[index].memoryBytes = state.restrictedResidentBytes
            }
            samples[index].threadCount = state.threadCount
        }
    }

    /// A fresh nettop reading. Between readings each process keeps the rate measured last time.
    private func applyNetwork(_ totals: [Int32: NetworkUsageReader.Totals], stamp: UInt64, to samples: inout [ProcessSample], keys: [ProcessKey]) {
        let intervalSeconds = lastNetworkStamp == 0 ? 0 : Double(stamp &- lastNetworkStamp) / 1e9
        let previousReading = lastNetworkDate
        for index in samples.indices {
            let key = keys[index]
            guard var state = states[key] else { continue }
            if let current = totals[key.pid] {
                let startedSinceReading = previousReading.map { (samples[index].startDate ?? .distantPast) >= $0 } ?? false
                // A process missing from the last reading had no open sockets, so all it has now is new traffic.
                let countsFromZero = lastNetworkStamp != 0 && (state.hasNetworkBaseline || startedSinceReading)
                let previousIn = state.networkBytesIn ?? (countsFromZero ? 0 : current.bytesIn)
                let previousOut = state.networkBytesOut ?? (countsFromZero ? 0 : current.bytesOut)
                // Totals cover open sockets only and drop when one closes.
                state.networkInRate = intervalSeconds > 0 ? Double(Self.delta(current.bytesIn, since: previousIn)) / intervalSeconds : 0
                state.networkOutRate = intervalSeconds > 0 ? Double(Self.delta(current.bytesOut, since: previousOut)) / intervalSeconds : 0
                state.networkBytesIn = current.bytesIn
                state.networkBytesOut = current.bytesOut
            } else {
                state.networkBytesIn = nil
                state.networkBytesOut = nil
                state.networkInRate = 0
                state.networkOutRate = 0
            }
            state.hasNetworkBaseline = true
            states[key] = state
            samples[index].networkInBytesPerSecond = state.networkInRate
            samples[index].networkOutBytesPerSecond = state.networkOutRate
        }
    }

    private func snapshot(from samples: [ProcessSample], inputs: [GroupingInput]) -> ProcessSnapshot {
        let assignments = grouper.assign(inputs)

        var named = samples
        var members: [GroupKey: [Int]] = [:]
        for index in named.indices {
            named[index].name = assignments[index].processName
            members[assignments[index].key, default: []].append(index)
        }

        func oldest(_ indices: [Int]) -> Int32? {
            indices.min { (named[$0].startDate ?? .distantFuture) < (named[$1].startDate ?? .distantFuture) }.map { named[$0].pid }
        }

        var apps: [AppUsage] = []
        apps.reserveCapacity(members.count)
        for (key, indices) in members {
            let processes = indices.map { named[$0] }.sorted { $0.memoryBytes > $1.memoryBytes }
            let name = grouper.groupName(for: key)
            switch key {
            case .bundle(let path):
                let mainPid = oldest(indices.filter { assignments[$0].isAppMain }) ?? oldest(indices.filter { assignments[$0].isRegularApp })
                apps.append(AppUsage(id: path, name: name, kind: .app, bundleIdentifier: grouper.bundleIdentifier(forBundle: path), bundlePath: grouper.realBundlePath(forBundle: path), processes: processes, mainPid: mainPid))
            case .system:
                apps.append(AppUsage(id: "system", name: name, kind: .system, bundleIdentifier: nil, bundlePath: nil, processes: processes, mainPid: nil))
            case .tool(let toolKey):
                let mainPid = oldest(indices.filter { named[$0].executablePath == toolKey || named[$0].executablePath == nil })
                apps.append(AppUsage(id: toolKey, name: name, kind: .tool, bundleIdentifier: nil, bundlePath: nil, processes: processes, mainPid: mainPid))
            }
        }
        apps.sort { $0.memoryBytes != $1.memoryBytes ? $0.memoryBytes > $1.memoryBytes : $0.name < $1.name }
        return ProcessSnapshot(processes: named, apps: apps)
    }
}
