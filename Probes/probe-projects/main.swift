import Foundation
import TallyCore
import TallyProjects

// Usage: probe-projects [--interval seconds] [--scans count]
let arguments = CommandLine.arguments
func value(after flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}
let interval = Double(value(after: "--interval") ?? "5") ?? 5
let scans = max(1, Int(value(after: "--scans") ?? "2") ?? 2)

func describe(_ activity: DevActivity, now: Date) -> String {
    switch activity {
    case .working: "working"
    case .idle(let since): "idle \(Format.span(now.timeIntervalSince(since)))"
    case .barelyUsed(let upSince): "up \(Format.span(now.timeIntervalSince(upSince))), barely used"
    }
}

let scanner = ProjectScanner()
var projects: [Project] = []
for scan in 1...scans {
    let processes = ProjectScanner.currentUserProcesses()
    let started = Date()
    projects = scanner.scan(processes: processes)
    let elapsed = Date().timeIntervalSince(started) * 1000
    print(String(format: "scan %d: %d processes in, %d projects out, %.1f ms", scan, processes.count, projects.count, elapsed))
    if scan < scans { Thread.sleep(forTimeInterval: interval) }
}

let now = Date()
print("")
for project in projects {
    let ports = project.ports.map(String.init).joined(separator: ", ")
    print("\(project.name)  \(Format.memory(project.memoryBytes).text)  ports [\(ports)]  \(project.isWorking ? "working" : "idle")")
    print("  \(project.path)")
    for process in project.processes {
        let processPorts = process.ports.map(String.init).joined(separator: ",")
        print("  pid \(process.pid)  \(process.name) (\(process.kind.label))  ports [\(processPorts)]  \(Format.memory(process.memoryBytes).text)  \(Format.precisePercent(process.cpuPercent)) CPU  \(describe(process.activity, now: now))")
        print("    \(process.commandLine.prefix(140))")
    }
}
if projects.isEmpty { print("No dev servers running.") }
