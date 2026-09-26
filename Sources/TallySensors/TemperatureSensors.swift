import Foundation
import TallyCore

/// The readable groups raw sensors are folded into, in display order.
enum TemperatureLabel: Int, CaseIterable, Comparable {
    case cpu, performanceCores, efficiencyCores, gpu, soc, neuralEngine, memory, ssd, battery, wifi, palmRest, ambient, powerManager

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .performanceCores: "CPU Performance Cores"
        case .efficiencyCores: "CPU Efficiency Cores"
        case .gpu: "GPU"
        case .soc: "SoC"
        case .neuralEngine: "Neural Engine"
        case .memory: "Memory"
        case .ssd: "SSD"
        case .battery: "Battery"
        case .wifi: "Wi-Fi"
        case .palmRest: "Palm Rest"
        case .ambient: "Ambient"
        case .powerManager: "Power Manager"
        }
    }

    /// Silicon never runs near freezing, so low readings from these groups are parked or broken sensors.
    var minimumPlausible: Double {
        switch self {
        case .cpu, .performanceCores, .efficiencyCores, .gpu, .soc, .neuralEngine, .powerManager: 10
        default: 5
        }
    }

    /// Core sensors that read a fixed placeholder while their cluster is power-gated.
    var isCore: Bool { self == .performanceCores || self == .efficiencyCores }

    /// The groups the CPU temperature is worked out from.
    var isCPU: Bool {
        switch self {
        case .cpu, .performanceCores, .efficiencyCores, .powerManager: true
        default: false
        }
    }

    static func < (lhs: TemperatureLabel, rhs: TemperatureLabel) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct TemperatureResult {
    var cpu: Double?
    var gpu: Double?
    var readings: [TemperatureReading] = []
}

/// Finds every temperature source this Mac exposes once, then reads a few live sensors per group.
///
/// An M4 Pro has well over a hundred SMC temperature keys at 70 to 200 µs each, many of them fixed placeholders.
/// A full pass reads them all and keeps a plan of up to four sensors per group, spread across the sensors that have
/// ever given a real reading, with the offset between their average and the whole group's. Reads in between follow
/// the plan and add the offset. A new full pass runs every few minutes, sooner while a core group has not been seen
/// awake yet, and at once when a group other than the cores goes quiet.
/// Not thread-safe; the owner serializes access.
final class TemperatureSensors {
    /// One sensor to read: an SMC key or a HID service. The lowest tier with readings wins a group.
    private struct Source {
        var smcKey: UInt32?
        var hidIndex: Int?
        var label: TemperatureLabel
        var tier: Int

        var id: Int { smcKey.map { Int($0) } ?? -1 - (hidIndex ?? 0) }
    }

    private struct Reading {
        var source: Source
        var celsius: Double
    }

    private static let sourcesPerLabel = 4
    private static let fullPassEvery = 60
    /// While a core group has only ever read as power-gated, look for it awake this much sooner.
    private static let fullPassEveryWhileCoresAsleep = 10

    /// A classified SMC key. Lower tiers win: Intel per-core sensors beat die sensors, which beat proximity sensors.
    struct SMCSensor {
        var key: UInt32
        var label: TemperatureLabel
        var tier: Int
    }

    private let smc: SMCConnection?
    private let hid: HIDTemperatureSensors?
    let smcSensors: [SMCSensor]
    private var plan: [Source]?
    private var readsSincePlan = 0
    private var readsPerPlan = fullPassEvery
    /// Sensors that have given a real reading at least once. Power-gated cores read a fixed placeholder,
    /// and some keys never read anything else.
    private var everLive = Set<Int>()
    /// Per group, the full average minus the plan's average at the last full pass that saw both.
    private var offsets: [TemperatureLabel: Double] = [:]
    /// Per group, how many sensors a full average covers, so the CPU figure weighs groups as it always did.
    private var weights: [TemperatureLabel: Double] = [:]
    private var lastResult = TemperatureResult()

    init(smc: SMCConnection?) {
        self.smc = smc
        self.hid = HIDTemperatureSensors()
        self.smcSensors = smc.map(Self.discover) ?? []
    }

    private static func discover(in smc: SMCConnection) -> [SMCSensor] {
        let candidates = smc.keys(startingWith: "T").filter { key in
            guard let info = smc.info(for: key) else { return false }
            return info.type == "flt " || info.type.hasPrefix("sp") || info.type.hasPrefix("fp")
        }
        let names = candidates.map(SMCConnection.name)
        let hasPerformanceKeys = names.contains { $0.hasPrefix("Tp") }
        let hasGPUKeys = names.contains { $0.hasPrefix("Tg") }
        let appleSilicon = isAppleSilicon
        return zip(candidates, names).compactMap { key, name in
            guard let (label, tier) = classify(name, appleSilicon: appleSilicon, hasPerformanceKeys: hasPerformanceKeys, hasGPUKeys: hasGPUKeys) else { return nil }
            return SMCSensor(key: key, label: label, tier: tier)
        }
    }

    /// True on Apple silicon, including when this process runs under Rosetta.
    private static var isAppleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }

    static func classify(_ name: String, appleSilicon: Bool, hasPerformanceKeys: Bool, hasGPUKeys: Bool) -> (TemperatureLabel, Int)? {
        let characters = Array(name)
        guard characters.count == 4 else { return nil }
        switch name {
        case "TC0E", "TC0F", "TC0D", "TCXC": return (.cpu, 1)
        case "TC0P", "TC0H": return (.cpu, 2)
        case "TG0D", "TGDD": return (.gpu, 1)
        case "TG0P", "TG0H", "TG0T": return (.gpu, 2)
        case "TH0x", "TH0a", "TH0b", "TH0X", "TH0A", "TH0B", "TH0P": return (.ssd, 0)
        case "TB0T", "TB1T", "TB2T", "TB3T": return (.battery, 0)
        case "Tm0P", "TM0P": return (.memory, 0)
        case "TW0P": return (.wifi, 0)
        case "Ts0P", "Ts1P": return (.palmRest, 0)
        case "TA0P", "TA0V", "TA1P": return (.ambient, 0)
        default: break
        }
        // Intel per-core sensors: TC1C, TC2C...
        if characters[1] == "C", characters[3] == "C" || characters[3] == "c", characters[2].isNumber { return (.cpu, 0) }
        // On Intel, Tp is the power supply, not the CPU.
        guard appleSilicon else { return nil }
        if name.hasPrefix("Tp") { return (.performanceCores, 0) }
        if name.hasPrefix("Te") { return (.efficiencyCores, 0) }
        if name.hasPrefix("Tg") { return (.gpu, 0) }
        // M3 generation keeps performance cores and GPU under Tf.
        if !hasPerformanceKeys, name.hasPrefix("Tf0") || name.hasPrefix("Tf4") { return (.performanceCores, 0) }
        if !hasGPUKeys, name.hasPrefix("Tf1") || name.hasPrefix("Tf2") { return (.gpu, 0) }
        return nil
    }

    private static func isPlausible(_ value: Double, label: TemperatureLabel) -> Bool {
        value.isFinite && value >= label.minimumPlausible && value <= 130
    }

    /// With `cpuOnly`, reads just the CPU groups and keeps the other figures from the last full read.
    func read(cpuOnly: Bool = false) -> TemperatureResult {
        guard let plan, readsSincePlan < readsPerPlan else {
            lastResult = result(from: planFromFullPass().mapValues(\.value))
            return lastResult
        }
        readsSincePlan += 1
        let sources = cpuOnly ? plan.filter { $0.label.isCPU } : plan
        var means = Self.means(of: readSources(sources)).mapValues(\.value)
        // A quiet core group is power-gated; any other group going quiet means the plan is out of date.
        if sources.contains(where: { means[$0.label] == nil && !$0.label.isCore }) { readsSincePlan = readsPerPlan }
        for (label, offset) in offsets where means[label] != nil { means[label]? += offset }
        if cpuOnly {
            var result = lastResult
            result.cpu = cpuTemperature(means) ?? lastResult.cpu
            return result
        }
        lastResult = result(from: means)
        return lastResult
    }

    /// Reads every sensor, picks the plan and its offsets, and returns the full averages.
    private func planFromFullPass() -> [TemperatureLabel: (value: Double, count: Int)] {
        let (sources, readings) = fullPass()
        everLive.formUnion(readings.map(\.source.id))
        let coresKnown = sources.contains { $0.label.isCore && everLive.contains($0.id) }
        let known = sources.filter { everLive.contains($0.id) && !(coresKnown && $0.label == .powerManager) }
        let bestTiers = Dictionary(grouping: known, by: \.label).compactMapValues { $0.map(\.tier).min() }
        let candidates = known.filter { $0.tier == bestTiers[$0.label] }
        let chosen = Self.spread(candidates)
        let chosenIDs = Set(chosen.map(\.id))

        let fullMeans = Self.means(of: readings)
        let planMeans = Self.means(of: readings.filter { chosenIDs.contains($0.source.id) })
        for (label, full) in fullMeans {
            if let planMean = planMeans[label]?.value { offsets[label] = full.value - planMean }
        }
        for (label, group) in Dictionary(grouping: candidates, by: \.label) { weights[label] = Double(group.count) }

        plan = chosen
        readsSincePlan = 0
        let coresAsleep = sources.contains { $0.label.isCore && bestTiers[$0.label] == nil }
        readsPerPlan = coresAsleep ? Self.fullPassEveryWhileCoresAsleep : Self.fullPassEvery
        return fullMeans
    }

    /// Every sensor that can win its group, and the real readings among them.
    private func fullPass() -> (sources: [Source], readings: [Reading]) {
        var sources = smcSensors.map { Source(smcKey: $0.key, hidIndex: nil, label: $0.label, tier: $0.tier) }
        let hidSensors = hid?.sensors ?? []
        for index in hidSensors.indices where hidSensors[index].label != .powerManager {
            sources.append(Source(smcKey: nil, hidIndex: index, label: hidSensors[index].label, tier: Self.hidTier(for: hidSensors[index].label)))
        }
        var readings = readSources(sources)
        // Power manager sensors are slow to read and only stand in when nothing measures the CPU itself.
        if !readings.contains(where: { $0.source.label == .cpu || $0.source.label.isCore }) {
            let standIns = hidSensors.indices.filter { hidSensors[$0].label == .powerManager }
                .map { Source(smcKey: nil, hidIndex: $0, label: .powerManager, tier: -1) }
            sources += standIns
            readings += readSources(standIns)
        }
        return (sources, readings)
    }

    /// On-die HID sensors (M1, M2) outrank the SMC for the chip itself. The battery gauge and SSD over HID take a
    /// millisecond each, so they only stand in when the SMC has nothing for those groups.
    private static func hidTier(for label: TemperatureLabel) -> Int {
        switch label {
        case .battery, .ssd: 10
        default: -1
        }
    }

    private func readSources(_ sources: [Source]) -> [Reading] {
        var readings: [Reading] = []
        readings.reserveCapacity(sources.count)
        for source in sources {
            guard let value = value(of: source), Self.isPlausible(value, label: source.label) else { continue }
            // Power-gated Apple silicon cores report a fixed 40 °C placeholder until they wake.
            if value == 40, source.label.isCore { continue }
            readings.append(Reading(source: source, celsius: value))
        }
        return readings
    }

    private func value(of source: Source) -> Double? {
        if let key = source.smcKey { return smc?.value(for: key) }
        if let index = source.hidIndex, let hid { return hid.celsius(of: hid.sensors[index]) }
        return nil
    }

    /// Average and count per group, from the best tier present in `readings`.
    private static func means(of readings: [Reading]) -> [TemperatureLabel: (value: Double, count: Int)] {
        var means: [TemperatureLabel: (value: Double, count: Int)] = [:]
        for (label, group) in Dictionary(grouping: readings, by: \.source.label) {
            guard let best = group.map(\.source.tier).min() else { continue }
            let values = group.filter { $0.source.tier == best }.map(\.celsius)
            if let mean = average(values) { means[label] = (mean, values.count) }
        }
        return means
    }

    /// Up to four sensors per group, evenly spread across it.
    private static func spread(_ sources: [Source]) -> [Source] {
        let byLabel = Dictionary(grouping: sources, by: \.label)
        var chosen: [Source] = []
        for label in byLabel.keys.sorted() {
            let group = byLabel[label] ?? []
            let count = group.count
            let kept = min(count, sourcesPerLabel)
            for index in 0..<kept {
                chosen.append(group[(2 * index + 1) * count / (2 * kept)])
            }
        }
        return chosen
    }

    /// Core groups weighed by how many sensors each has, as a plain average over every core sensor would.
    private func cpuTemperature(_ means: [TemperatureLabel: Double]) -> Double? {
        let coreLabels = [TemperatureLabel.performanceCores, .efficiencyCores].filter { means[$0] != nil }
        if !coreLabels.isEmpty {
            let totalWeight = coreLabels.reduce(0) { $0 + (weights[$1] ?? 1) }
            return coreLabels.reduce(0) { $0 + (means[$1] ?? 0) * (weights[$1] ?? 1) } / totalWeight
        }
        return means[.cpu] ?? means[.powerManager]
    }

    private func result(from means: [TemperatureLabel: Double]) -> TemperatureResult {
        var result = TemperatureResult()
        result.cpu = cpuTemperature(means)
        result.gpu = means[.gpu]
        result.readings = means.keys.sorted().compactMap { label in
            means[label].map { TemperatureReading(name: label.title, celsius: $0) }
        }
        return result
    }

    private static func average(_ values: [Double]?) -> Double? {
        guard let values, !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    /// A description of every raw source, for the probe.
    func inventory() -> [String] {
        var lines: [String] = []
        if let smc {
            lines.append("SMC: \(smc.keyCount) keys, \(smcSensors.count) temperature keys classified")
            let grouped = Dictionary(grouping: smcSensors, by: \.label)
            for label in grouped.keys.sorted() {
                let entries = grouped[label, default: []].map { sensor -> String in
                    let value = smc.value(for: sensor.key).map { String(format: "%.1f", $0) } ?? "--"
                    return "\(SMCConnection.name(sensor.key))=\(value)"
                }
                lines.append("  \(label.title): \(entries.joined(separator: " "))")
            }
        } else {
            lines.append("SMC: unavailable")
        }
        if let hid {
            let counts = Dictionary(grouping: hid.allServiceNames) { $0.prefix { !$0.isNumber } }.mapValues(\.count)
            lines.append("HID: \(hid.allServiceNames.count) temperature services: " + counts.keys.sorted().map { "\($0.trimmingCharacters(in: .whitespaces)) ×\(counts[$0] ?? 0)" }.joined(separator: ", "))
            for sensor in hid.sensors {
                let value = hid.celsius(of: sensor).map { String(format: "%.1f", $0) } ?? "--"
                lines.append("  \(sensor.name) [\(sensor.label.title)] = \(value)")
            }
        } else {
            lines.append("HID: unavailable")
        }
        return lines
    }
}
