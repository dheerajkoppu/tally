import Foundation
import TallyCore
import TallySystem

func milliseconds(_ body: () -> Void) -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    body()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
}

func pad(_ label: String) -> String {
    label.padding(toLength: 22, withPad: " ", startingAt: 0)
}

func line(_ label: String, _ value: String) {
    print("  \(pad(label))\(value)")
}

let arguments = CommandLine.arguments
let rounds = arguments.firstIndex(of: "--rounds").flatMap { Int(arguments[$0 + 1]) } ?? 1
let interval = arguments.firstIndex(of: "--interval").flatMap { Double(arguments[$0 + 1]) } ?? 2

var sampler: SystemSampler!
let initTime = milliseconds { sampler = SystemSampler() }
var snapshot = SystemSnapshot()
let firstTime = milliseconds { snapshot = sampler.sample() }
print("init \(String(format: "%.1f", initTime)) ms, first sample \(String(format: "%.1f", firstTime)) ms")

func residentBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
    }
    return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
}

// --bench N: time N back-to-back samples 50 ms apart and report the spread and memory growth.
if let benchIndex = arguments.firstIndex(of: "--bench"), let count = Int(arguments[benchIndex + 1]) {
    let startResident = residentBytes()
    var timings: [Double] = []
    for _ in 0..<count {
        Thread.sleep(forTimeInterval: 0.05)
        timings.append(milliseconds { _ = sampler.sample() })
    }
    let sorted = timings.sorted()
    let average = timings.reduce(0, +) / Double(max(1, timings.count))
    print(String(format: "%d samples: min %.2f ms, median %.2f ms, avg %.2f ms, p95 %.2f ms, max %.2f ms", count, sorted.first ?? 0, sorted[sorted.count / 2], average, sorted[Int(Double(sorted.count) * 0.95)], sorted.last ?? 0))
    print("resident memory \(Format.memory(startResident).text) -> \(Format.memory(residentBytes()).text)")
    exit(0)
}

for round in 1...rounds {
    Thread.sleep(forTimeInterval: interval)
    let sampleTime = milliseconds { snapshot = sampler.sample() }
    let cpu = snapshot.cpu
    let memory = snapshot.memory
    let disk = snapshot.disk
    let network = snapshot.network
    let gpu = snapshot.gpu
    let battery = snapshot.battery

    print("\n=== Sample \(round) (\(String(format: "%.2f", sampleTime)) ms) — \(snapshot.machineName), \(Format.uptime(snapshot.uptime))")

    print("CPU — \(cpu.chipName), \(cpu.logicalCores) cores (\(cpu.performanceCores) P + \(cpu.efficiencyCores) E)")
    line("Total", Format.precisePercent(cpu.totalPercent))
    line("User / System", "\(Format.precisePercent(cpu.userPercent)) / \(Format.precisePercent(cpu.systemPercent))")
    line("Idle", Format.precisePercent(100 - cpu.totalPercent))
    line("Load average", cpu.loadAverage.map { String(format: "%.2f", $0) }.joined(separator: ", "))
    line("Per core", cpu.perCorePercent.map { String(format: "%.0f", $0) }.joined(separator: " "))

    print("Memory — \(Format.memory(memory.totalBytes).text) total, pressure \(memory.pressure.label)")
    line("Used", "\(Format.memory(memory.usedBytes).text) (\(Format.percent(memory.usedFraction * 100).text))")
    line("App", Format.memory(memory.appBytes).text)
    line("Wired", Format.memory(memory.wiredBytes).text)
    line("Compressed", Format.memory(memory.compressedBytes).text)
    line("Cached files", Format.memory(memory.cachedBytes).text)
    line("Free", Format.memory(memory.freeBytes).text)
    line("Swap", "\(Format.memory(memory.swapUsedBytes).text) of \(Format.memory(memory.swapTotalBytes).text)")

    print("Disk — \(Format.storage(disk.freeBytes).text) free of \(Format.storage(disk.totalBytes).text) (used \(Format.storage(disk.usedBytes).text))")
    line("Read", Format.rate(disk.readBytesPerSecond).text)
    line("Write", Format.rate(disk.writeBytesPerSecond).text)
    for volume in disk.volumes {
        let tags = [volume.isRoot ? "startup" : nil, volume.isInternal ? "internal" : "external"].compactMap { $0 }.joined(separator: ", ")
        line("Volume", "\(volume.name) at \(volume.mountPath): \(Format.storage(volume.freeBytes).text) free of \(Format.storage(volume.totalBytes).text) [\(tags)]")
    }

    print("Network — \(network.interfaceKind.isEmpty ? "none" : network.interfaceKind) (\(network.interfaceName.isEmpty ? "-" : network.interfaceName)), \(network.isConnected ? "connected" : "disconnected")")
    line("Download", Format.rate(network.downloadBytesPerSecond).text)
    line("Upload", Format.rate(network.uploadBytesPerSecond).text)
    line("Session in / out", "\(Format.total(network.sessionDownloadedBytes).text) / \(Format.total(network.sessionUploadedBytes).text)")
    for connection in network.connections {
        let details = [connection.linkSpeedText.map { "link \($0)" }, connection.isPrimary ? "primary" : nil].compactMap { $0 }
        line("\(connection.kind) · \(connection.interfaceName)", "↓ \(Format.rate(connection.downloadBytesPerSecond).text)  ↑ \(Format.rate(connection.uploadBytesPerSecond).text)" + (details.isEmpty ? "" : "  (\(details.joined(separator: ", ")))"))
    }

    print("GPU — \(gpu.name)")
    line("Utilization", Format.percent(gpu.utilizationPercent).text)
    line("Memory in use", Format.memory(gpu.memoryUsedBytes).text)

    if battery.hasBattery {
        let state = battery.isCharging ? "charging" : (battery.isPluggedIn ? "plugged in, not charging" : "on battery")
        print("Battery — \(Format.percent(battery.percent).text), \(state)")
        line("Time remaining", battery.timeRemainingMinutes.map { Format.duration(minutes: $0) } ?? "estimating / n/a")
        line("Power draw", Format.power(battery.powerDrawWatts).text)
        line("Health", "\(Format.percent(battery.healthPercent).text) (\(battery.maxCapacitymAh) of \(battery.designCapacitymAh) mAh)")
        line("Cycles", "\(battery.cycleCount)")
        line("Temperature", String(format: "%.1f °C", battery.temperatureCelsius))
        line("Adapter", battery.adapterWatts.map { "\($0) W" } ?? "none")
    } else {
        print("Battery — none")
    }
}
