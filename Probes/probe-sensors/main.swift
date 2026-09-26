import Foundation
import TallyCore
import TallySensors

func milliseconds(since start: DispatchTime) -> String {
    String(format: "%.1f ms", Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
}

func describe(_ stats: SensorStats) {
    let cpu = stats.cpuTemperatureCelsius.map { Format.temperature($0).text } ?? "none"
    let gpu = stats.gpuTemperatureCelsius.map { Format.temperature($0).text } ?? "none"
    print("CPU \(cpu)   GPU \(gpu)")
    for reading in stats.temperatures {
        print(String(format: "  %-24@ %5.1f °C", reading.name as NSString, reading.celsius))
    }
    if stats.fans.isEmpty { print("Fans: none") }
    for fan in stats.fans {
        print("  \(fan.name): \(Format.integer(fan.rpm)) rpm (min \(Format.integer(fan.minRPM)), max \(Format.integer(fan.maxRPM)))")
    }
    if stats.peripheralBatteries.isEmpty { print("Peripheral batteries: none") }
    for battery in stats.peripheralBatteries {
        print("  \(battery.name): \(Format.percent(battery.percent).text) [\(battery.kind.rawValue)]")
    }
}

let reader = SensorReader()
reader.setDemand(SamplingDemand(isVisible: true))

var start = DispatchTime.now()
let first = reader.read()
print("First read (includes discovery and a full pass): \(milliseconds(since: start))")
describe(first)

// Give the background system_profiler run time to finish, then time steady-state reads.
Thread.sleep(forTimeInterval: 3)
func cpuMilliseconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1000 + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1000
}

func timeReads(_ label: String, count: Int) -> SensorStats {
    var timings: [Double] = []
    var stats = SensorStats()
    let cpuBefore = cpuMilliseconds()
    for _ in 0..<count {
        let start = DispatchTime.now()
        stats = reader.read()
        timings.append(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
        Thread.sleep(forTimeInterval: 0.05)
    }
    let cpu = (cpuMilliseconds() - cpuBefore) / Double(count)
    let sorted = timings.sorted()
    print(String(format: "\n%@: %d reads, median %.2f ms wall, %.2f ms CPU on average, max %.2f ms (a full pass every 60 reads)", label, count, sorted[count / 2], cpu, sorted.last ?? 0))
    return stats
}
let stats = timeReads("Steady-state reads with a window open", count: 30)
describe(stats)
reader.setDemand(SamplingDemand(isVisible: false))
let hidden = timeReads("Steady-state reads with nothing on screen (CPU only)", count: 30)
print("CPU \(hidden.cpuTemperatureCelsius.map { Format.temperature($0).text } ?? "none")")

print("\nRaw sources")
print(reader.inventory())
