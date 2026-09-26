import Foundation
import TallyCore
import TallyProcesses

// Usage: probe-processes [--samples N] [--interval seconds] [--hidden] [--all] [--group name]...
// --hidden samples as the app does with no window open: cached tool figures, no thread counts.

func option(_ name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: name), index + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[index + 1]
}

func cpuMilliseconds(_ who: Int32) -> Double {
    var usage = rusage()
    getrusage(who, &usage)
    func milliseconds(_ time: timeval) -> Double { Double(time.tv_sec) * 1000 + Double(time.tv_usec) / 1000 }
    return milliseconds(usage.ru_utime) + milliseconds(usage.ru_stime)
}

func pad(_ text: String, _ width: Int) -> String {
    text.count >= width ? String(text.prefix(width)) : text + String(repeating: " ", count: width - text.count)
}

func padLeft(_ text: String, _ width: Int) -> String {
    text.count >= width ? text : String(repeating: " ", count: width - text.count) + text
}

let sampleCount = Int(option("--samples") ?? "") ?? 4
let interval = Double(option("--interval") ?? "") ?? 1
let groupFilters = CommandLine.arguments.enumerated()
    .filter { $0.offset > 0 && CommandLine.arguments[$0.offset - 1] == "--group" }
    .map { $0.element.lowercased() }

let sampler = ProcessSampler()
let isHidden = CommandLine.arguments.contains("--hidden")
sampler.setDemand(SamplingDemand(isVisible: !isHidden, showsAppNetwork: !isHidden))
var snapshot = ProcessSnapshot(processes: [], apps: [])
let runStart = Date()
for round in 1...sampleCount {
    if round > 1 { Thread.sleep(forTimeInterval: interval) }
    let selfBefore = cpuMilliseconds(RUSAGE_SELF)
    let start = Date()
    snapshot = sampler.sample()
    let wall = Date().timeIntervalSince(start) * 1000
    let selfCPU = cpuMilliseconds(RUSAGE_SELF) - selfBefore
    print(String(format: "sample %d: %.1f ms wall, %.1f ms CPU in process, %d processes, %d groups",
                 round, wall, selfCPU, snapshot.processes.count, snapshot.apps.count))
}
// The helper tools run in the background; give the last ones time to finish before counting their CPU.
Thread.sleep(forTimeInterval: 1)
let runSeconds = Date().timeIntervalSince(runStart)
print(String(format: "over %.0f s: %.1f ms CPU in process, %.1f ms CPU in ps/nettop/top, %.3f%% of one core in all",
             runSeconds, cpuMilliseconds(RUSAGE_SELF), cpuMilliseconds(RUSAGE_CHILDREN),
             (cpuMilliseconds(RUSAGE_SELF) + cpuMilliseconds(RUSAGE_CHILDREN)) / (runSeconds * 10)))

let processes = snapshot.processes
let restricted = processes.filter(\.isRestricted)
print("")
print("\(processes.count) processes in \(snapshot.apps.count) apps")
let pathless = processes.filter { $0.executablePath == nil }
let pathlessList = pathless.isEmpty ? "" : ": " + pathless.map { "\($0.pid) \($0.name)" }.joined(separator: ", ")
print("  \(restricted.count) owned by other users (read through ps), \(pathless.count) without a path\(pathlessList)")
print(String(format: "  CPU total %.1f%% of one core, memory total %@, network in %@ out %@, GPU %.1f%%, power %@",
             processes.reduce(0) { $0 + $1.cpuPercent },
             Format.memory(processes.reduce(0) { $0 + $1.memoryBytes }).text,
             Format.rate(processes.reduce(0) { $0 + $1.networkInBytesPerSecond }).text,
             Format.rate(processes.reduce(0) { $0 + $1.networkOutBytesPerSecond }).text,
             processes.reduce(0) { $0 + $1.gpuPercent },
             Format.power(processes.reduce(0) { $0 + $1.powerWatts }).text))
let kinds = Dictionary(grouping: snapshot.apps, by: \.kind)
print("  groups: \(kinds[.app]?.count ?? 0) apps, \(kinds[.tool]?.count ?? 0) tools, \(kinds[.system]?.count ?? 0) macOS")
print("")

func row(_ app: AppUsage) -> String {
    [
        pad(app.name, 30),
        pad(app.kind.rawValue, 6),
        padLeft("\(app.processCount)", 4),
        padLeft(Format.memory(app.memoryBytes).text, 10),
        padLeft(Format.precisePercent(app.cpuPercent), 7),
        padLeft(Format.rate(app.diskReadBytesPerSecond + app.diskWriteBytesPerSecond).text, 10),
        padLeft(Format.rate(app.networkInBytesPerSecond + app.networkOutBytesPerSecond).text, 10),
        padLeft(Format.precisePercent(app.gpuPercent), 6),
        padLeft(Format.power(app.powerWatts).text, 8),
        "  main \(app.mainPid.map(String.init) ?? "-")",
        "  \(app.bundleIdentifier ?? "")",
    ].joined(separator: " ")
}

let header = [pad("App", 30), pad("Kind", 6), padLeft("#", 4), padLeft("Memory", 10), padLeft("CPU", 7), padLeft("Disk", 10), padLeft("Network", 10), padLeft("GPU", 6), padLeft("Power", 8)].joined(separator: " ")
let showAll = CommandLine.arguments.contains("--all")
print(showAll ? "All groups by memory" : "Top 25 by memory")
print(header)
for app in snapshot.apps.prefix(showAll ? .max : 25) { print(row(app)) }

print("")
print("Top 10 by CPU")
print(header)
for app in snapshot.apps.sorted(by: { $0.cpuPercent > $1.cpuPercent }).prefix(10) { print(row(app)) }

print("")
print("Top 8 processes by CPU")
for process in processes.sorted(by: { $0.cpuPercent > $1.cpuPercent }).prefix(8) {
    print("  \(padLeft(String(process.pid), 6)) \(pad(process.name, 40)) \(padLeft(Format.precisePercent(process.cpuPercent), 7)) \(padLeft(Format.memory(process.memoryBytes).text, 9)) threads \(process.threadCount)\(process.isRestricted ? "  (ps)" : "")")
}

for filter in groupFilters {
    for app in snapshot.apps where app.name.lowercased().contains(filter) || app.id.lowercased().contains(filter) {
        print("")
        print("\(app.name) (\(app.id)): \(Format.processes(app.processCount))")
        for process in app.processes {
            let rates = "net \(padLeft(Format.rate(process.networkInBytesPerSecond).text, 9))/\(padLeft(Format.rate(process.networkOutBytesPerSecond).text, 9)) disk \(padLeft(Format.rate(process.diskReadBytesPerSecond + process.diskWriteBytesPerSecond).text, 9)) gpu \(padLeft(Format.precisePercent(process.gpuPercent), 5)) \(padLeft(Format.power(process.powerWatts).text, 7))"
            let figures = "\(padLeft(Format.memory(process.memoryBytes).text, 9)) \(padLeft(Format.precisePercent(process.cpuPercent), 7)) \(rates) thr \(padLeft(String(process.threadCount), 3)) uid \(padLeft(String(process.uid), 3)) resp \(padLeft(String(process.responsiblePid), 6)) ppid \(padLeft(String(process.parentPid), 6))"
            print("  \(padLeft(String(process.pid), 6)) \(pad(process.name, 38)) \(figures)\(process.isRestricted ? " ps" : "")  \(process.executablePath ?? "?")")
        }
    }
}
