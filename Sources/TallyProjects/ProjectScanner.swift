import Darwin
import Foundation
import TallyCore

/// Finds dev servers and listening ports, grouped by project folder.
///
/// What never changes for a process (its arguments, whether it is a dev tool at all, whether an editor started it)
/// is worked out once and cached per process instance, so a scan of an unchanged Mac costs a few system calls per
/// dev process. Project folders are found without listing any folder; see `ProjectLocator`.
public final class ProjectScanner: ProjectScanning {
    /// Share of one core, in percent, above which a process counts as doing something.
    public static let activeCPUPercent: Double = 1
    /// How long after its last activity a process still shows as working.
    public static let workingWindow: TimeInterval = 120
    /// How long a process must be up before it can count as barely used.
    public static let barelyUsedUptime: TimeInterval = 86_400

    private struct ProcessKey: Hashable {
        var pid: Int32
        var startMicroseconds: Int64
    }

    /// What never changes for one process: read once, then reused every scan.
    private struct Identity {
        var executablePath: String?
        var normalizedName: String
        var arguments: [String]
        var baseKind: DevServerKind?
        /// A shell, editor, agent, system or app process, or a helper recognised from its arguments.
        var isExcluded: Bool
        var startDate: Date
        /// Arguments that name an existing script, resolved once when first needed.
        var scriptPaths: [String]?
        /// Started by an editor, agent or app rather than from a shell, worked out once when first needed.
        var isEditorHelper: Bool?
        /// For a process of no known runtime: whether its executable sits inside a project folder, the only way it
        /// can count without listening on a port.
        var isBuiltInProject: Bool?
    }

    private struct Activity {
        var firstSeen: Date
        var cpuSecondsAtFirstSeen: Double
        var lastCPUSeconds: Double
        var lastSampleDate: Date
        var lastActiveDate: Date?
        /// Where the idle time counts from when no activity has been seen yet.
        var quietSince: Date
        var cpuPercent: Double
    }

    private let lock = NSLock()
    private let locator = ProjectLocator()
    private let userID = getuid()
    private let ownPid = getpid()
    private var identities: [ProcessKey: Identity] = [:]
    private var activities: [ProcessKey: Activity] = [:]
    private var scanCount = 0

    public init() {}

    public func scan(processes: [ProcessSample]) -> [Project] {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        locator.beginScan()
        let samples = processes.isEmpty ? Self.currentUserProcesses() : processes
        var processesByPid: [Int32: ProcessSample]?

        var seen = Set<ProcessKey>()
        var grouped: [String: [DevProcess]] = [:]

        for sample in samples where sample.uid == userID && sample.pid > 1 && sample.pid != ownPid {
            guard let (key, startDate) = Self.key(for: sample) else { continue }
            seen.insert(key)
            var identity = identity(for: key, sample: sample, startDate: startDate)
            if identity.isExcluded { continue }

            let ports = ProcessInspector.listeningPorts(sample.pid)
            if ports.isEmpty, identity.baseKind == nil {
                if identity.isBuiltInProject == nil {
                    switch identity.executablePath.map({ locator.lookUpRoot(from: ($0 as NSString).deletingLastPathComponent, now: now) }) {
                    case .found: identity.isBuiltInProject = true
                    case .deferred: break
                    case .missing, nil: identity.isBuiltInProject = false
                    }
                    identities[key] = identity
                }
                if identity.isBuiltInProject != true { continue }
            }
            let workingDirectory = ProcessInspector.workingDirectory(sample.pid)
            guard let root = projectRoot(workingDirectory: workingDirectory, identity: &identity, listens: !ports.isEmpty, now: now) else {
                identities[key] = identity
                continue
            }

            var kind = identity.baseKind
            if kind == nil, let path = identity.executablePath, path.hasPrefix(root + "/") {
                kind = DevServerClassifier.kindForBinary(atPath: path, inProject: root) { locator.hasFile(named: $0, in: root, now: now) }
            }
            guard kind != nil || !ports.isEmpty else {
                identities[key] = identity
                continue
            }
            if ports.isEmpty {
                if identity.isEditorHelper == nil, processesByPid == nil {
                    processesByPid = Dictionary(samples.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
                }
                let isHelper = identity.isEditorHelper ?? isEditorHelper(parentPid: sample.parentPid, processesByPid: processesByPid ?? [:])
                identity.isEditorHelper = isHelper
                identities[key] = identity
                if isHelper { continue }
            } else {
                identities[key] = identity
            }

            let usage = ProcessInspector.usage(sample.pid)
            let cpuSeconds = usage?.cpuSeconds ?? sample.cpuTimeSeconds
            let activity = updateActivity(for: key, cpuSeconds: cpuSeconds, reportedPercent: sample.cpuPercent, startDate: identity.startDate, now: now)
            let name = displayName(for: identity, kind: kind)
            let process = DevProcess(
                pid: sample.pid,
                name: name,
                kind: kind ?? .other,
                commandLine: commandLine(for: identity, name: name),
                ports: ports,
                memoryBytes: usage?.footprintBytes ?? sample.memoryBytes,
                cpuPercent: activity.cpuPercent,
                startDate: identity.startDate,
                lastActiveDate: activity.lastActiveDate ?? activity.quietSince,
                activity: status(of: activity, cpuSeconds: cpuSeconds, startDate: identity.startDate, now: now)
            )
            grouped[root, default: []].append(process)
        }

        if identities.count > seen.count { identities = identities.filter { seen.contains($0.key) } }
        activities = activities.filter { seen.contains($0.key) }
        scanCount += 1
        if scanCount % 60 == 0 { locator.pruneCache(now: now) }

        return grouped.map { root, members in
            Project(
                name: (root as NSString).lastPathComponent,
                path: root,
                processes: members.sorted { ($0.memoryBytes, $1.pid) > ($1.memoryBytes, $0.pid) }
            )
        }
        .sorted { ($0.memoryBytes, $1.name) > ($1.memoryBytes, $0.name) }
    }

    /// The process instance key, from the sample's start date when it has one.
    private static func key(for sample: ProcessSample) -> (ProcessKey, Date)? {
        if let startDate = sample.startDate {
            let microseconds = Int64((startDate.timeIntervalSince1970 * 1_000_000).rounded())
            return (ProcessKey(pid: sample.pid, startMicroseconds: microseconds), startDate)
        }
        guard let info = ProcessInspector.bsdInfo(sample.pid) else { return nil }
        return (ProcessKey(pid: sample.pid, startMicroseconds: info.startMicroseconds), info.startDate)
    }

    /// A minimal list of this user's processes (pid, parent, name, path), for callers without a process sampler.
    public static func currentUserProcesses() -> [ProcessSample] {
        let userID = getuid()
        return ProcessInspector.allPids().compactMap { pid in
            guard let info = ProcessInspector.bsdInfo(pid), info.uid == userID else { return nil }
            var sample = ProcessSample(pid: pid, parentPid: info.parentPid, responsiblePid: pid, uid: info.uid, name: info.name, executablePath: ProcessInspector.executablePath(pid))
            sample.startDate = info.startDate
            return sample
        }
    }

    private func identity(for key: ProcessKey, sample: ProcessSample, startDate: Date) -> Identity {
        if let cached = identities[key], cached.executablePath == (sample.executablePath ?? cached.executablePath) { return cached }
        let path = sample.executablePath ?? ProcessInspector.executablePath(key.pid)
        let name = DevServerClassifier.normalizedName(name: sample.name, executablePath: path)
        // Most processes are ruled out by name and path alone, without reading their arguments.
        let isObviouslyExcluded = DevServerClassifier.isObviouslyExcluded(normalizedName: name, executablePath: path)
        let arguments = isObviouslyExcluded ? [] : ProcessInspector.arguments(key.pid)
        let identity = Identity(
            executablePath: path,
            normalizedName: name,
            arguments: arguments,
            baseKind: isObviouslyExcluded ? nil : DevServerClassifier.kind(normalizedName: name, executablePath: path, arguments: arguments),
            isExcluded: isObviouslyExcluded || DevServerClassifier.isExcludedByArguments(arguments),
            startDate: startDate
        )
        identities[key] = identity
        return identity
    }

    /// The working directory decides the project; when it is the home folder or the root, the script path does.
    private func projectRoot(workingDirectory: String?, identity: inout Identity, listens: Bool, now: Date) -> String? {
        let informative = workingDirectory.map { !locator.isUninformative($0) } ?? false
        if informative, let workingDirectory, let root = locator.root(from: workingDirectory, now: now) { return root }
        let scripts = identity.scriptPaths ?? scriptPaths(identity.arguments, workingDirectory: workingDirectory)
        identity.scriptPaths = scripts
        for script in scripts {
            if let root = locator.root(from: (script as NSString).deletingLastPathComponent, now: now) { return root }
        }
        if listens, informative, let workingDirectory { return locator.fallbackRoot(for: workingDirectory) }
        return nil
    }

    /// Arguments that name an existing file, resolved against the working directory.
    private func scriptPaths(_ arguments: [String], workingDirectory: String?) -> [String] {
        let scriptExtensions: Set<String> = ["js", "mjs", "cjs", "ts", "mts", "py", "rb", "php", "exs", "ex"]
        var paths: [String] = []
        for argument in arguments.dropFirst().prefix(16) where !argument.hasPrefix("-") {
            guard argument.contains("/") || scriptExtensions.contains((argument as NSString).pathExtension) else { continue }
            let expanded = (argument as NSString).expandingTildeInPath
            let base = workingDirectory ?? locator.home
            let resolved = expanded.hasPrefix("/") ? expanded : (base as NSString).appendingPathComponent(expanded)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory), !isDirectory.boolValue {
                paths.append((resolved as NSString).standardizingPath)
                if paths.count == 3 { break }
            }
        }
        return paths
    }

    /// True when the process was started by an editor, agent or app rather than from a shell: a language server,
    /// an MCP server, a formatter. Processes that listen on a port are kept whoever started them.
    private func isEditorHelper(parentPid: Int32, processesByPid: [Int32: ProcessSample]) -> Bool {
        var current = parentPid
        for _ in 0..<12 {
            guard current > 1 else { return false }
            let parent = processesByPid[current]
            let path = parent?.executablePath ?? ProcessInspector.executablePath(current)
            let parentName = parent?.name ?? ProcessInspector.bsdInfo(current)?.name ?? ""
            let name = DevServerClassifier.normalizedName(name: parentName, executablePath: path)
            if DevServerClassifier.isTerminalBoundary(name) { return false }
            if DevServerClassifier.isHelperOwner(normalizedName: name, executablePath: path) { return true }
            if DevServerClassifier.isExcludedByArguments(ProcessInspector.arguments(current)) { return true }
            guard let next = parent?.parentPid ?? ProcessInspector.bsdInfo(current)?.parentPid, next != current else { return false }
            current = next
        }
        return false
    }

    private func updateActivity(for key: ProcessKey, cpuSeconds: Double, reportedPercent: Double, startDate: Date, now: Date) -> Activity {
        guard var activity = activities[key] else {
            let age = max(now.timeIntervalSince(startDate), 1)
            var fresh = Activity(
                firstSeen: now,
                cpuSecondsAtFirstSeen: cpuSeconds,
                lastCPUSeconds: cpuSeconds,
                lastSampleDate: now,
                lastActiveDate: nil,
                quietSince: now,
                cpuPercent: reportedPercent
            )
            if reportedPercent > Self.activeCPUPercent || age < Self.workingWindow {
                fresh.lastActiveDate = reportedPercent > Self.activeCPUPercent ? now : startDate
            } else if cpuSeconds / age < 0.002 {
                // Almost no CPU in its whole life: it has been quiet since shortly after it started.
                fresh.quietSince = startDate
            }
            activities[key] = fresh
            return fresh
        }
        let elapsed = now.timeIntervalSince(activity.lastSampleDate)
        if elapsed > 0.5 {
            let used = max(0, cpuSeconds - activity.lastCPUSeconds)
            activity.cpuPercent = used / elapsed * 100
            activity.lastCPUSeconds = cpuSeconds
            activity.lastSampleDate = now
            if activity.cpuPercent > Self.activeCPUPercent { activity.lastActiveDate = now }
        }
        activities[key] = activity
        return activity
    }

    private func status(of activity: Activity, cpuSeconds: Double, startDate: Date, now: Date) -> DevActivity {
        if let lastActive = activity.lastActiveDate, now.timeIntervalSince(lastActive) < Self.workingWindow { return .working }
        let uptime = now.timeIntervalSince(startDate)
        let quietSince = activity.lastActiveDate ?? activity.quietSince
        if uptime >= Self.barelyUsedUptime, now.timeIntervalSince(quietSince) >= 3600 || activity.lastActiveDate == nil {
            let watched = max(now.timeIntervalSince(activity.firstSeen), 1)
            let watchedShare = max(0, cpuSeconds - activity.cpuSecondsAtFirstSeen) / watched
            let lifetimeShare = cpuSeconds / max(uptime, 1)
            if watchedShare < 0.001 && lifetimeShare < 0.005 { return .barelyUsed(upSince: startDate) }
        }
        return .idle(since: quietSince)
    }

    private func displayName(for identity: Identity, kind: DevServerKind?) -> String {
        let executable = identity.executablePath.map { ($0 as NSString).lastPathComponent } ?? identity.normalizedName
        guard kind == .python, executable == "Python" else { return executable }
        let invoked = identity.arguments.first.map { ($0 as NSString).lastPathComponent.lowercased() } ?? ""
        return invoked.hasPrefix("python") && invoked != "python" ? invoked : "python3"
    }

    /// The arguments as typed, with the program reduced to its name.
    private func commandLine(for identity: Identity, name: String) -> String {
        // Processes that rename themselves (npm, next-server) leave blank arguments behind.
        let arguments = identity.arguments.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let first = arguments.first else { return name }
        let program = first.hasPrefix("/") ? (first as NSString).lastPathComponent : first
        let rest = arguments.dropFirst().map { $0.contains(" ") ? "\"\($0)\"" : $0 }
        return ([program == "Python" ? name : program] + rest).joined(separator: " ")
    }
}
