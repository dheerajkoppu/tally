import Foundation
import TallyCore
import TallyHistory

setvbuf(stdout, nil, _IOLBF, 0)

struct SplitMix {
    var state: UInt64

    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        value ^= value >> 31
        return Double(value >> 11) / Double(1 << 53)
    }
}

func milliseconds(_ nanoseconds: UInt64) -> Double { Double(nanoseconds) / 1_000_000 }

func timed<T>(_ body: () -> T) -> (T, Double) {
    let start = DispatchTime.now().uptimeNanoseconds
    let result = body()
    return (result, milliseconds(DispatchTime.now().uptimeNanoseconds - start))
}

func percentile(_ values: [Double], _ fraction: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))]
}

func sparkline(_ values: [Double]) -> String {
    let blocks = Array("▁▂▃▄▅▆▇█")
    let top = max(values.max() ?? 1, 0.000_001)
    return String(values.map { blocks[min(blocks.count - 1, Int(($0 / top) * Double(blocks.count - 1) + 0.5))] })
}

func describe(_ value: Double, _ metric: HistoryMetric) -> String {
    switch metric {
    case .cpu, .gpu, .battery: String(format: "%.1f%%", value)
    case .memory: Format.memory(UInt64(max(0, value))).text
    case .diskRead, .diskWrite, .networkIn, .networkOut: Format.rate(value).text
    case .power: Format.power(value).text
    case .cpuTemperature: String(format: "%.1f°C", value)
    }
}

func describeTotal(_ value: Double, _ metric: HistoryMetric) -> String {
    switch metric {
    case .cpu, .gpu: Format.precisePercent(value)
    case .memory: Format.memory(UInt64(max(0, value))).text
    case .diskRead, .diskWrite, .networkIn, .networkOut: Format.total(UInt64(max(0, value))).text
    case .power: Format.power(value).text
    case .battery, .cpuTemperature: String(value)
    }
}

let localFormatter = DateFormatter()
localFormatter.dateFormat = "MMM d HH:mm"


struct SyntheticApp {
    var id: String
    var name: String
    var kind: AppKind
    var cpu: Double
    var memoryGB: Double
    var diskWriteMBps: Double
    var networkInMBps: Double
    var gpu: Double
    var watts: Double
}

let majorApps: [SyntheticApp] = [
    SyntheticApp(id: "/Applications/Google Chrome.app", name: "Google Chrome", kind: .app, cpu: 32, memoryGB: 6.2, diskWriteMBps: 0.4, networkInMBps: 0.9, gpu: 6, watts: 1.6),
    SyntheticApp(id: "/Applications/Xcode.app", name: "Xcode", kind: .app, cpu: 18, memoryGB: 4.1, diskWriteMBps: 2.5, networkInMBps: 0.05, gpu: 2, watts: 1.2),
    SyntheticApp(id: "system", name: "macOS", kind: .system, cpu: 9, memoryGB: 5.0, diskWriteMBps: 0.8, networkInMBps: 0.1, gpu: 8, watts: 0.9),
    SyntheticApp(id: "/Applications/Slack.app", name: "Slack", kind: .app, cpu: 3, memoryGB: 1.2, diskWriteMBps: 0.05, networkInMBps: 0.08, gpu: 1, watts: 0.3),
    SyntheticApp(id: "/Applications/Safari.app", name: "Safari", kind: .app, cpu: 6, memoryGB: 2.4, diskWriteMBps: 0.1, networkInMBps: 0.4, gpu: 3, watts: 0.5),
    SyntheticApp(id: "/System/Applications/Utilities/Terminal.app", name: "Terminal", kind: .app, cpu: 2, memoryGB: 0.4, diskWriteMBps: 0.02, networkInMBps: 0.01, gpu: 0.5, watts: 0.1),
    SyntheticApp(id: "/Applications/Visual Studio Code.app", name: "VS Code", kind: .app, cpu: 7, memoryGB: 2.9, diskWriteMBps: 0.3, networkInMBps: 0.05, gpu: 1.5, watts: 0.6),
    SyntheticApp(id: "/Applications/zoom.us.app", name: "Zoom", kind: .app, cpu: 22, memoryGB: 0.9, diskWriteMBps: 0.05, networkInMBps: 0.6, gpu: 12, watts: 2.1),
    SyntheticApp(id: "/System/Applications/Music.app", name: "Music", kind: .app, cpu: 1.5, memoryGB: 0.35, diskWriteMBps: 0.01, networkInMBps: 0.04, gpu: 0.5, watts: 0.15),
    SyntheticApp(id: "/Applications/Dropbox.app", name: "Dropbox", kind: .app, cpu: 1, memoryGB: 0.5, diskWriteMBps: 0.6, networkInMBps: 0.3, gpu: 0, watts: 0.1),
    SyntheticApp(id: "/usr/local/bin/node", name: "node", kind: .tool, cpu: 4, memoryGB: 0.7, diskWriteMBps: 0.2, networkInMBps: 0.02, gpu: 0, watts: 0.3),
    SyntheticApp(id: "/Applications/Figma.app", name: "Figma", kind: .app, cpu: 5, memoryGB: 1.6, diskWriteMBps: 0.05, networkInMBps: 0.1, gpu: 9, watts: 0.7),
]
let tinyTools: [SyntheticApp] = (1...40).map { index in
    SyntheticApp(id: "/usr/libexec/helper\(index)", name: "helper\(index)", kind: .tool, cpu: 0.05, memoryGB: 0.004, diskWriteMBps: 0.0001, networkInMBps: 0, gpu: 0, watts: 0.001)
}
let allApps = majorApps + tinyTools

let calendar = Calendar.current
let now = Date()
let timeZoneOffset = Double(TimeZone.current.secondsFromGMT(for: now))
let recordSpacing: TimeInterval = 10
let continuousFrom = now.timeIntervalSince1970 - 26 * 3600
let firstTime = now.timeIntervalSince1970 - 30 * 86400 + 120
let lastTime = now.timeIntervalSince1970 - 1

func isActive(_ time: TimeInterval) -> Bool {
    if time >= continuousFrom { return true }
    let secondOfDay = (time + timeZoneOffset).truncatingRemainder(dividingBy: 86400)
    return secondOfDay >= 9 * 3600 && secondOfDay < 19 * 3600
}

/// 0...1 over the local day, busiest mid-afternoon.
func dayLoad(_ time: TimeInterval) -> Double {
    let hour = (time + timeZoneOffset).truncatingRemainder(dividingBy: 86400) / 3600
    return max(0, sin((hour - 7) / 16 * .pi))
}

struct Expected {
    var networkInToday = 0.0
    var networkOutToday = 0.0
    var networkInWeek = 0.0
    var networkInMonth = 0.0
    var diskWrittenToday = 0.0
    var cpuToday = 0.0
    var gpuToday = 0.0
    var secondsToday = 0.0
    var gpuPeakToday = 0.0
    var chromeNetworkMonth = 0.0
    var chromeCPUIntegralDay = 0.0
    var secondsDay = 0.0
}

struct RecordedSample {
    var minute: Int64
    var interval: Double
    var networkIn: Double
    var networkOut: Double
    var diskWrite: Double
    var cpu: Double
    var gpu: Double
    var chromeNetwork: Double
    var chromeCPU: Double
}

func makeSnapshot(at time: TimeInterval, random: inout SplitMix) -> (SystemSnapshot, [AppUsage]) {
    let load = dayLoad(time)
    var snapshot = SystemSnapshot()
    snapshot.date = Date(timeIntervalSince1970: time)
    snapshot.cpu.totalPercent = min(100, 8 + 42 * load + 10 * random.next())
    snapshot.memory.totalBytes = 64 << 30
    snapshot.memory.appBytes = UInt64((22 + 10 * load) * 1_073_741_824)
    snapshot.memory.wiredBytes = UInt64(5.4 * 1_073_741_824)
    snapshot.memory.compressedBytes = UInt64((3 + 6 * load) * 1_073_741_824)
    snapshot.gpu.utilizationPercent = min(100, 5 + 40 * load * random.next() + (random.next() > 0.97 ? 40 : 0))
    snapshot.battery.hasBattery = true
    let secondOfDay = (time + timeZoneOffset).truncatingRemainder(dividingBy: 86400)
    snapshot.battery.percent = max(8, 100 - max(0, secondOfDay - 9 * 3600) / 36000 * 70)
    snapshot.battery.powerDrawWatts = 6 + 18 * load + 3 * random.next()
    snapshot.sensors.cpuTemperatureCelsius = 42 + 30 * load + 4 * random.next()
    let burst = random.next() > 0.9 ? 6.0 : 1.0
    snapshot.disk.readBytesPerSecond = (1.5 + 8 * load * random.next()) * 1_000_000
    snapshot.disk.writeBytesPerSecond = (2 + 6 * load * random.next() * burst) * 1_000_000
    snapshot.network.downloadBytesPerSecond = (0.2 + 3 * load * random.next() * burst) * 1_000_000
    snapshot.network.uploadBytesPerSecond = (0.05 + 0.4 * load * random.next()) * 1_000_000

    let meeting = secondOfDay >= 10 * 3600 && secondOfDay < 11 * 3600
    var apps: [AppUsage] = []
    apps.reserveCapacity(allApps.count)
    for synthetic in allApps {
        if synthetic.name == "Zoom" && !meeting { continue }
        let jitter = 0.6 + 0.8 * random.next()
        var app = AppUsage(id: synthetic.id, name: synthetic.name, kind: synthetic.kind, bundleIdentifier: nil,
                           bundlePath: synthetic.kind == .app ? synthetic.id : nil, processes: [], mainPid: 100)
        app.cpuPercent = synthetic.cpu * jitter * (0.4 + load)
        app.memoryBytes = UInt64(synthetic.memoryGB * (0.8 + 0.3 * load) * 1_073_741_824)
        app.diskWriteBytesPerSecond = synthetic.diskWriteMBps * jitter * 1_000_000
        app.diskReadBytesPerSecond = synthetic.diskWriteMBps * 0.5 * jitter * 1_000_000
        app.networkInBytesPerSecond = synthetic.networkInMBps * jitter * (0.3 + load) * 1_000_000
        app.networkOutBytesPerSecond = synthetic.networkInMBps * 0.2 * jitter * 1_000_000
        app.gpuPercent = synthetic.gpu * jitter
        app.powerWatts = synthetic.watts * jitter
        apps.append(app)
    }
    return (snapshot, apps)
}


let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tally-probe-history")
try? FileManager.default.removeItem(at: directory)

var store: HistoryStore? = HistoryStore(directory: directory)
print("History file: \(store!.fileURL.path)")

var random = SplitMix(state: 42)
var samples: [RecordedSample] = []
var recordTimes: [Double] = []
var flushTimes: [Double] = []
var previousTime: TimeInterval?
var previousMinute: Int64?
let recordStart = Date()

var time = firstTime
while time <= lastTime {
    defer { time += recordSpacing }
    guard isActive(time) else { continue }
    let (snapshot, apps) = makeSnapshot(at: time, random: &random)
    let interval = previousTime.map { min(time - $0, 60) } ?? 1
    previousTime = time
    let minute = Int64(floor(time / 60)) * 60
    let chrome = apps[0]
    samples.append(RecordedSample(
        minute: minute, interval: interval,
        networkIn: snapshot.network.downloadBytesPerSecond * interval,
        networkOut: snapshot.network.uploadBytesPerSecond * interval,
        diskWrite: snapshot.disk.writeBytesPerSecond * interval,
        cpu: snapshot.cpu.totalPercent * interval,
        gpu: snapshot.gpu.utilizationPercent * interval,
        chromeNetwork: chrome.networkInBytesPerSecond * interval,
        chromeCPU: chrome.cpuPercent * interval
    ))
    let start = DispatchTime.now().uptimeNanoseconds
    store!.record(snapshot: snapshot, apps: apps)
    let elapsed = milliseconds(DispatchTime.now().uptimeNanoseconds - start)
    if let previousMinute, previousMinute != minute { flushTimes.append(elapsed) } else { recordTimes.append(elapsed) }
    previousMinute = minute
}
let (_, drainTime) = timed { store!.totals() }
print(String(format: "Recorded %d samples (%d apps each, %d minutes) in %.1f s; queue drained %.0f ms later",
             samples.count, allApps.count, flushTimes.count + 1, Date().timeIntervalSince(recordStart), drainTime))
print(String(format: "record(): p50 %.4f ms, p99 %.4f ms, max %.3f ms; at a minute rollover: p50 %.4f ms, p99 %.4f ms, max %.3f ms",
             percentile(recordTimes, 0.5), percentile(recordTimes, 0.99), recordTimes.max() ?? 0,
             percentile(flushTimes, 0.5), percentile(flushTimes, 0.99), flushTimes.max() ?? 0))

func expectedTotals(at date: Date) -> Expected {
    var expected = Expected()
    let today = Int64(calendar.startOfDay(for: date).timeIntervalSince1970)
    let week = Int64(date.timeIntervalSince1970) - 7 * 86400
    let month = Int64(date.timeIntervalSince1970) - 30 * 86400
    let monthHour = (Int64(floor(date.timeIntervalSince1970 - 30 * 86400)) / 3600) * 3600
    let dayMinute = (Int64(floor(date.timeIntervalSince1970 - 86400)) / 60) * 60
    for sample in samples {
        if sample.minute >= month { expected.networkInMonth += sample.networkIn }
        if sample.minute >= week { expected.networkInWeek += sample.networkIn }
        if sample.minute >= monthHour { expected.chromeNetworkMonth += sample.chromeNetwork }
        if sample.minute >= dayMinute {
            expected.chromeCPUIntegralDay += sample.chromeCPU
            expected.secondsDay += sample.interval
        }
        guard sample.minute >= today else { continue }
        expected.networkInToday += sample.networkIn
        expected.networkOutToday += sample.networkOut
        expected.diskWrittenToday += sample.diskWrite
        expected.cpuToday += sample.cpu
        expected.gpuToday += sample.gpu
        expected.secondsToday += sample.interval
    }
    return expected
}

func check(_ label: String, actual: Double, expected: Double, tolerance: Double = 0.001) -> Bool {
    let error = expected == 0 ? abs(actual) : abs(actual - expected) / abs(expected)
    let passed = error <= tolerance
    print(String(format: "  %@ %-28@ actual %16.3f  expected %16.3f  (error %.5f%%)", passed ? "ok  " : "FAIL", label as NSString, actual, expected, error * 100))
    return passed
}

func verifyTotals(_ store: HistoryStore, label: String) -> UsageTotals {
    let queryDate = Date()
    let (totals, elapsed) = timed { store.totals() }
    let expected = expectedTotals(at: queryDate)
    print("\ntotals() \(label) in \(String(format: "%.2f", elapsed)) ms")
    print("  networkIn today \(Format.total(totals.networkInToday).text), out today \(Format.total(totals.networkOutToday).text), in 7 d \(Format.total(totals.networkInLast7Days).text), in 30 d \(Format.total(totals.networkInLast30Days).text)")
    print("  disk written today \(Format.total(totals.diskWrittenToday).text), CPU average today \(String(format: "%.1f", totals.cpuAverageToday))%, GPU average \(String(format: "%.1f", totals.gpuAverageToday))%, GPU peak \(String(format: "%.1f", totals.gpuPeakToday))%")
    var passed = true
    passed = check("networkInToday", actual: Double(totals.networkInToday), expected: expected.networkInToday) && passed
    passed = check("networkOutToday", actual: Double(totals.networkOutToday), expected: expected.networkOutToday) && passed
    passed = check("networkInLast7Days", actual: Double(totals.networkInLast7Days), expected: expected.networkInWeek) && passed
    passed = check("networkInLast30Days", actual: Double(totals.networkInLast30Days), expected: expected.networkInMonth) && passed
    passed = check("diskWrittenToday", actual: Double(totals.diskWrittenToday), expected: expected.diskWrittenToday) && passed
    passed = check("cpuAverageToday", actual: totals.cpuAverageToday, expected: expected.cpuToday / expected.secondsToday) && passed
    passed = check("gpuAverageToday", actual: totals.gpuAverageToday, expected: expected.gpuToday / expected.secondsToday) && passed
    print(passed ? "  totals match an independent integration of the same samples" : "  TOTALS MISMATCH")
    return totals
}

let totalsBefore = verifyTotals(store!, label: "(file + minute in memory)")

let metrics: [HistoryMetric] = [.cpu, .memory, .gpu, .diskRead, .diskWrite, .networkIn, .networkOut, .battery, .power, .cpuTemperature]
var slowestQuery = 0.0
for range in HistoryRange.allCases {
    print("\nseries, \(range.label), 90 buckets")
    for metric in metrics {
        let (points, elapsed) = timed { store!.series(metric, range: range, buckets: 90) }
        slowestQuery = max(slowestQuery, elapsed)
        let values = points.map(\.value)
        let average = values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
        let span = points.isEmpty ? "" : "\(localFormatter.string(from: points.first!.date)) to \(localFormatter.string(from: points.last!.date))"
        print(String(format: "  %-15@ %3d pts %6.2f ms  min %-10@ avg %-10@ max %-10@ %@", metric.rawValue as NSString, points.count, elapsed,
                     describe(values.min() ?? 0, metric) as NSString, describe(average, metric) as NSString, describe(values.max() ?? 0, metric) as NSString, span as NSString))
        if metric == .cpu || metric == .networkIn || metric == .battery {
            print("                  \(sparkline(values))")
        }
    }
}

for range in HistoryRange.allCases {
    print("\ntopApps, \(range.label)")
    for metric in [HistoryMetric.cpu, .memory, .networkIn, .diskWrite, .gpu, .power] {
        let (apps, elapsed) = timed { store!.topApps(metric, range: range, limit: 5) }
        slowestQuery = max(slowestQuery, elapsed)
        let list = apps.map { "\($0.name) \(describeTotal($0.value, metric))" }.joined(separator: ", ")
        print(String(format: "  %-10@ %6.2f ms  %@", metric.rawValue as NSString, elapsed, list as NSString))
    }
}

for range in HistoryRange.allCases {
    let (points, elapsed) = timed { store!.appSeries(appID: "/Applications/Google Chrome.app", metric: .cpu, range: range, buckets: 60) }
    let (network, networkElapsed) = timed { store!.appSeries(appID: "/Applications/Google Chrome.app", metric: .networkIn, range: range, buckets: 60) }
    slowestQuery = max(slowestQuery, elapsed, networkElapsed)
    print(String(format: "\nappSeries Chrome cpu, %@: %d pts in %.2f ms, avg %.1f%%", range.label as NSString, points.count, elapsed,
                 points.isEmpty ? 0 : points.map(\.value).reduce(0, +) / Double(points.count)))
    print("  cpu      \(sparkline(points.map(\.value)))")
    print(String(format: "  network  %@  (%d pts in %.2f ms)", sparkline(network.map(\.value)) as NSString, network.count, networkElapsed))
}
let zoom = store!.appSeries(appID: "/Applications/zoom.us.app", metric: .cpu, range: .hours24, buckets: 96)
print("\nappSeries Zoom cpu, 24 h (meetings 10:00 to 11:00 only): \(sparkline(zoom.map(\.value)))")
print("appSeries for an app never seen: \(store!.appSeries(appID: "/Applications/Nothing.app", metric: .cpu, range: .days7, buckets: 60).count) points")
print("appSeries battery (not per app): \(store!.appSeries(appID: "/Applications/Google Chrome.app", metric: .battery, range: .days7, buckets: 60).count) points")

let queryDate = Date()
let expected = expectedTotals(at: queryDate)
let chromeMonth = store!.topApps(.networkIn, range: .days30, limit: 20).first { $0.name == "Google Chrome" }?.value ?? 0
let chromeDay = store!.topApps(.cpu, range: .hours24, limit: 20).first { $0.name == "Google Chrome" }?.value ?? 0
print("\nPer-app checks")
_ = check("Chrome network in, 30 d", actual: chromeMonth, expected: expected.chromeNetworkMonth)
_ = check("Chrome average CPU, 24 h", actual: chromeDay, expected: expected.chromeCPUIntegralDay / expected.secondsDay, tolerance: 0.002)
let helperTotal = store!.topApps(.memory, range: .hours24, limit: 100).filter { $0.name.hasPrefix("helper") }.count
print("  tiny helpers outside every top 15 kept in the file: \(helperTotal) (the minute in memory still counts them)")

print(String(format: "\nSlowest query: %.2f ms", slowestQuery))
print("File size after 30 days of synthetic data: \(Format.storage(store!.fileSize).text)")

store!.flush()
print("\nflush(), then reopen")
store = nil
store = HistoryStore(directory: directory)
let totalsAfter = verifyTotals(store!, label: "(reopened file)")
let unchanged = [
    (Double(totalsBefore.networkInToday), Double(totalsAfter.networkInToday)),
    (Double(totalsBefore.networkOutToday), Double(totalsAfter.networkOutToday)),
    (Double(totalsBefore.diskWrittenToday), Double(totalsAfter.diskWrittenToday)),
    (totalsBefore.cpuAverageToday, totalsAfter.cpuAverageToday),
    (totalsBefore.gpuPeakToday, totalsAfter.gpuPeakToday),
].allSatisfy { abs($0.0 - $0.1) <= max(2, abs($0.0) * 1e-9) }
print("  today's totals unchanged by flush and reopen: \(unchanged)")

// A second write to the same minute merges with the first.
let mergeMinute = (floor(Date().timeIntervalSince1970 / 60) + 5) * 60
var mergeSnapshot = SystemSnapshot()
mergeSnapshot.cpu.totalPercent = 20
mergeSnapshot.date = Date(timeIntervalSince1970: mergeMinute + 1)
store!.record(snapshot: mergeSnapshot, apps: [])
mergeSnapshot.date = Date(timeIntervalSince1970: mergeMinute + 11)
store!.record(snapshot: mergeSnapshot, apps: [])
store!.flush()
mergeSnapshot.cpu.totalPercent = 80
mergeSnapshot.date = Date(timeIntervalSince1970: mergeMinute + 21)
store!.record(snapshot: mergeSnapshot, apps: [])
store!.flush()
print("  merged minute written twice (20% for 11 s, then 80% for 10 s); inspect with sqlite3: minute \(Int64(mergeMinute))")

// The background cadence: the whole Mac every 5 s, apps every 15 s. App averages must not be diluted.
let cadenceDirectory = directory.appendingPathComponent("cadence", isDirectory: true)
var cadenceStore: HistoryStore? = HistoryStore(directory: cadenceDirectory)
let cadenceStart = (floor(Date().timeIntervalSince1970 / 3600) - 2) * 3600
var cadenceSnapshot = SystemSnapshot()
cadenceSnapshot.cpu.totalPercent = 20
cadenceSnapshot.network.downloadBytesPerSecond = 1_000_000
var cadenceApp = AppUsage(id: "/Applications/Steady.app", name: "Steady", kind: .app, bundleIdentifier: nil, bundlePath: "/Applications/Steady.app", processes: [], mainPid: 1)
cadenceApp.cpuPercent = 50
for step in 0..<(3600 / 5) {
    cadenceSnapshot.date = Date(timeIntervalSince1970: cadenceStart + Double(step) * 5)
    if step % 3 == 0 {
        cadenceStore!.record(snapshot: cadenceSnapshot, apps: [cadenceApp])
    } else {
        cadenceStore!.recordSystem(snapshot: cadenceSnapshot)
    }
}
cadenceStore!.flush()
let steady = cadenceStore!.topApps(.cpu, range: .hours12, limit: 1).first?.value ?? 0
let systemCPU = cadenceStore!.series(.cpu, range: .hours12, buckets: 12).map(\.value).max() ?? 0
let downloaded = cadenceStore!.series(.networkIn, range: .hours12, buckets: 12).map(\.value).max() ?? 0
print(String(format: "\nBackground cadence (Mac every 5 s, apps every 15 s): app CPU %.2f%% (expected 50), Mac CPU %.2f%% (expected 20), download %.0f B/s (expected 1000000)",
             steady, systemCPU, downloaded))
cadenceStore = nil

if ProcessInfo.processInfo.environment["PROBE_HISTORY_KEEP"] != nil { exit(0) }
store!.clearAll()
let cleared = store!.totals()
print("\nclearAll(): network in 30 d \(cleared.networkInLast30Days), cpu today \(cleared.cpuAverageToday), series points \(store!.series(.cpu, range: .days30, buckets: 60).count), file \(Format.storage(store!.fileSize).text)")
store = nil

let damagedDirectory = directory.appendingPathComponent("damaged", isDirectory: true)
try? FileManager.default.createDirectory(at: damagedDirectory, withIntermediateDirectories: true)
try? Data(repeating: 0x5A, count: 64 * 1024).write(to: damagedDirectory.appendingPathComponent("history.sqlite"))
var damagedStore: HistoryStore? = HistoryStore(directory: damagedDirectory)
var damagedSnapshot = SystemSnapshot()
damagedSnapshot.network.downloadBytesPerSecond = 1_000_000
for offset in 0..<130 {
    damagedSnapshot.date = Date().addingTimeInterval(Double(offset - 130))
    damagedStore!.record(snapshot: damagedSnapshot, apps: [])
}
let recovered = damagedStore!.totals().networkInToday
damagedStore = nil
let files = (try? FileManager.default.contentsOfDirectory(atPath: damagedDirectory.path).sorted()) ?? []
print("\nDamaged file: recorded \(Format.total(recovered).text) into a fresh file; directory now holds \(files)")

print("\nAlert engine (thresholds: \(AppSettings.alertThresholds()))")
let engine = AlertEngine()
let alertStart = Date().addingTimeInterval(-3 * 3600)
let tick: TimeInterval = 5
var alertRandom = SplitMix(state: 7)
var seen = Set<String>()
var evaluateTimes: [Double] = []
var dismissedPhotos = false

func alertApp(_ id: String, _ name: String, kind: AppKind = .app, pid: Int32) -> AppUsage {
    AppUsage(id: id, name: name, kind: kind, bundleIdentifier: nil, bundlePath: kind == .app ? id : nil, processes: [], mainPid: pid)
}

func printList(_ list: [AlertItem], at minute: Double) {
    print(String(format: "  Worth a Look at %.0f min: %d", minute, list.count))
    for alert in list {
        print(String(format: "    [%4.1f min] %@ / %@", alert.date.timeIntervalSince(alertStart) / 60, alert.title as NSString, alert.detail as NSString))
    }
}

var step = 0
while Double(step) * tick <= 95 * 60 {
    let elapsed = Double(step) * tick
    let minute = elapsed / 60
    var snapshot = SystemSnapshot()
    snapshot.date = alertStart.addingTimeInterval(elapsed)
    var apps: [AppUsage] = []

    var chrome = alertApp("/Applications/Google Chrome.app", "Google Chrome", pid: 200)
    chrome.cpuPercent = minute < 80 ? 80 + 10 * alertRandom.next() : 12
    chrome.memoryBytes = 3 << 30
    apps.append(chrome)

    var xcode = alertApp("/Applications/Xcode.app", "Xcode", pid: 201)
    xcode.cpuPercent = 15
    let growth = min(minute, 40) * 90 * 1_048_576
    xcode.memoryBytes = UInt64(4 * 1_073_741_824 + growth + 40_000_000 * alertRandom.next())
    apps.append(xcode)

    var slack = alertApp("/Applications/Slack.app", "Slack", pid: 202)
    slack.memoryBytes = minute < 15 ? 1 << 30 : 4 << 30
    apps.append(slack)

    var photos = alertApp("/System/Applications/Photos.app", "Photos", pid: 203)
    photos.diskWriteBytesPerSecond = minute >= 30 && minute < 37 ? 85_000_000 : 200_000
    apps.append(photos)

    if minute < 55 {
        var dropbox = alertApp("/Applications/Dropbox.app", "Dropbox", pid: 204)
        let heavy = minute >= 40 && minute < 50
        dropbox.networkInBytesPerSecond = heavy ? 12_000_000 : 50_000
        dropbox.networkOutBytesPerSecond = heavy ? 3_000_000 : 10_000
        apps.append(dropbox)
    }

    var bursty = alertApp("/Applications/Bursty.app", "Bursty", pid: 205)
    bursty.diskWriteBytesPerSecond = Int(elapsed / 30) % 2 == 0 ? 120_000_000 : 0
    apps.append(bursty)

    var system = alertApp("system", "macOS", kind: .system, pid: 1)
    system.cpuPercent = 300
    apps.append(system)

    var launch = alertApp("/Applications/Busy At Launch.app", "Busy At Launch", pid: 206)
    launch.cpuPercent = 95
    apps.append(launch)

    var moderate = alertApp("/Applications/Moderate.app", "Moderate", pid: 207)
    moderate.cpuPercent = 60
    apps.append(moderate)

    var node = alertApp("/usr/local/bin/node", "node", kind: .tool, pid: 208)
    node.cpuPercent = minute >= 50 && minute < 66 ? 150 : 1
    apps.append(node)

    let started = DispatchTime.now().uptimeNanoseconds
    let list = engine.evaluate(snapshot: snapshot, apps: apps)
    evaluateTimes.append(milliseconds(DispatchTime.now().uptimeNanoseconds - started))

    for alert in list where !seen.contains(alert.id) {
        seen.insert(alert.id)
        print(String(format: "  fired at %5.1f min: %@ / %@", minute, alert.title as NSString, alert.detail as NSString))
    }
    if !dismissedPhotos, let photosAlert = list.first(where: { $0.appName == "Photos" }) {
        engine.dismiss(photosAlert)
        dismissedPhotos = true
        print(String(format: "  dismissed Photos at %.1f min", minute))
    }
    if [12.0, 36.0, 52.0, 56.0, 72.0, 95.0].contains(minute) { printList(list, at: minute) }
    step += 1
}
print(String(format: "evaluate(): p50 %.4f ms, max %.3f ms over %d ticks", percentile(evaluateTimes, 0.5), evaluateTimes.max() ?? 0, evaluateTimes.count))
