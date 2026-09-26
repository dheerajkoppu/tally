import Foundation

/// Follows dev server processes asked to stop until the project scans confirm they are gone, then says what that
/// freed: "4 servers stopped." and "1.37 GB and ports 3000, 4321, 8000 are free." Shared by the Projects tab and the
/// menu bar panel. It does no work of its own: each scan is one `update` call.
public struct ProjectStopTracker {
    public struct Result: Equatable, Identifiable {
        public let id = UUID()
        public let title: String
        public let detail: String
    }

    private struct Target {
        var pid: Int32
        var startDate: Date?
        var name: String
        var projectID: String
        var projectName: String
        var memoryBytes: UInt64
        var ports: [Int]
    }

    /// How long the processes get to exit before the result counts only those that did.
    public static let grace: TimeInterval = 10

    private var waiting: [Target] = []
    private var stopped: [Target] = []
    /// Projects whose every process was asked to stop.
    private var wholeProjects: [String] = []
    private var requestDate = Date.distantPast
    public private(set) var result: Result?

    public init() {}

    public var isWaiting: Bool { !waiting.isEmpty }

    /// Starts following `pids`, as `projects` (the list they were stopped from) describes them.
    public mutating func begin(stopping pids: [Int32], in projects: [Project], at date: Date = Date()) {
        let requested = Set(pids)
        waiting = []
        stopped = []
        wholeProjects = []
        for project in projects {
            let targets = project.processes.filter { requested.contains($0.pid) }
            guard !targets.isEmpty else { continue }
            if targets.count == project.processes.count { wholeProjects.append(project.id) }
            waiting += targets.map { process in
                Target(pid: process.pid, startDate: process.startDate, name: process.name, projectID: project.id,
                       projectName: project.name, memoryBytes: process.memoryBytes, ports: process.ports)
            }
        }
        requestDate = date
    }

    /// Takes a new scan. The result arrives once every process is gone, or after the grace with those that are.
    public mutating func update(with projects: [Project], now: Date = Date()) {
        guard !waiting.isEmpty else { return }
        var running: [Int32: Date?] = [:]
        for project in projects {
            for process in project.processes { running[process.pid] = process.startDate }
        }
        // A pid taken over by a process with another start time counts as gone.
        let isRunning: (Target) -> Bool = { target in
            guard let startDate = running[target.pid] else { return false }
            return startDate == target.startDate
        }
        stopped += waiting.filter { !isRunning($0) }
        waiting.removeAll { !isRunning($0) }
        guard waiting.isEmpty || now.timeIntervalSince(requestDate) >= Self.grace else { return }
        let survivors = Set(waiting.map(\.projectID))
        waiting = []
        guard !stopped.isEmpty else { return }
        let heldPorts = Set(projects.flatMap(\.ports))
        let freedPorts = Set(stopped.flatMap(\.ports)).subtracting(heldPorts).sorted()
        let memory = Format.memory(stopped.reduce(0) { $0 + $1.memoryBytes }).text
        result = Result(title: title(excluding: survivors), detail: Self.detail(memory: memory, ports: freedPorts))
        stopped = []
    }

    public mutating func dismiss() {
        result = nil
    }

    /// "4 servers stopped.", "storefront stopped.", "node in storefront stopped." or "3 processes stopped."
    private func title(excluding survivors: Set<String>) -> String {
        let projectIDs = wholeProjects.filter { id in !survivors.contains(id) && stopped.contains { $0.projectID == id } }
        let loose = stopped.filter { !projectIDs.contains($0.projectID) }
        if loose.isEmpty {
            if projectIDs.count == 1, let name = stopped.first?.projectName { return "\(name) stopped." }
            return "\(projectIDs.count) servers stopped."
        }
        if projectIDs.isEmpty, loose.count == 1 { return "\(loose[0].name) in \(loose[0].projectName) stopped." }
        return "\(stopped.count) processes stopped."
    }

    private static func detail(memory: String, ports: [Int]) -> String {
        guard !ports.isEmpty else { return "\(memory) of memory is free." }
        let list = ports.map(String.init).joined(separator: ", ")
        return "\(memory) and \(ports.count == 1 ? "port" : "ports") \(list) are free."
    }
}
