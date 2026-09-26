import Foundation
import TallyCore

/// Watches for apps that misbehave and posts notifications.
///
/// Each app keeps a rolling window of 20 second slots. An alert needs a full window of observation, so nothing
/// fires in the first minutes after launch, and each app and kind fires at most once an hour.
public final class AlertEngine: AlertEvaluating {
    static let slotLength: TimeInterval = 20
    static let memoryWindow: TimeInterval = 30 * 60
    /// Memory growth needs this much observation, and must be spread over at least this long.
    static let memoryMinimumSpan: TimeInterval = 10 * 60
    static let sustainedWindow: TimeInterval = 5 * 60
    static let cooldown: TimeInterval = 3600
    /// How long an alert stays in "Worth a Look".
    static let lifetime: TimeInterval = 3600
    /// Share of a window that must have been sampled for its average to count.
    static let minimumCoverage = 0.8
    /// The longest gap counted as observed time: the background cadence, doubled in Low Power Mode, with room to spare.
    static let maximumInterval: TimeInterval = 60

    static let gibibyte = 1024.0 * 1024 * 1024
    static let megabyte = 1_000_000.0

    private let lock = NSLock()
    private var trackers: [String: AppTracker] = [:]
    private var alerts: [AlertItem] = []
    private var lastFired: [String: Date] = [:]
    /// Per app, alerts up to this date were dismissed.
    private var dismissedUntil: [String: Date] = [:]
    private var lastEvaluation: Date?
    private let ownPid = ProcessInfo.processInfo.processIdentifier
    private let ownBundleIdentifier = Bundle.main.bundleIdentifier
    private let ownBundlePath = Bundle.main.bundleIdentifier == nil ? nil : Bundle.main.bundlePath

    public init() {
        AlertNotifier.installDelegate()
    }

    /// Ask for permission to post notifications. Call once at launch.
    public static func requestAuthorization() {
        AlertNotifier.requestAuthorization()
    }

    public func evaluate(snapshot: SystemSnapshot, apps: [AppUsage]) -> [AlertItem] {
        let now = snapshot.date.timeIntervalSince1970 > 0 ? snapshot.date : Date()
        let thresholds = AppSettings.alertThresholds()
        var fired: [(alert: AlertItem, iconPath: String?)] = []

        lock.lock()
        let interval: TimeInterval
        if let lastEvaluation, now > lastEvaluation {
            interval = min(now.timeIntervalSince(lastEvaluation), Self.maximumInterval)
        } else {
            interval = 1
        }
        lastEvaluation = now

        var present = Set<String>()
        for app in apps where !isIgnored(app) {
            present.insert(app.id)
            let findings = trackers[app.id, default: AppTracker(firstSeen: now, mainPid: app.mainPid)]
                .update(with: app, at: now, interval: interval, thresholds: thresholds)
            for finding in findings {
                let cooldownKey = "\(finding.kind.rawValue)|\(app.id)"
                if let last = lastFired[cooldownKey], now.timeIntervalSince(last) < Self.cooldown { continue }
                lastFired[cooldownKey] = now
                let alert = AlertItem(
                    id: "\(finding.kind.rawValue)|\(app.id)|\(Int64(now.timeIntervalSince1970))",
                    kind: finding.kind,
                    appID: app.id,
                    appName: app.name,
                    bundlePath: app.bundlePath,
                    title: Self.title(for: finding.kind, appName: app.name),
                    detail: finding.detail,
                    date: now
                )
                alerts.append(alert)
                fired.append((alert, app.bundlePath ?? Self.executablePath(of: app)))
            }
        }

        let horizon = max(Self.memoryWindow, thresholds.cpuMinutes * 60, Self.sustainedWindow) + Self.slotLength
        let stale = trackers.compactMap { now.timeIntervalSince($0.value.lastSeen) > horizon ? $0.key : nil }
        for key in stale { trackers.removeValue(forKey: key) }
        alerts.removeAll { now.timeIntervalSince($0.date) > Self.lifetime || $0.date > now }
        lastFired = lastFired.filter { now.timeIntervalSince($0.value) < Self.cooldown }
        dismissedUntil = dismissedUntil.filter { now.timeIntervalSince($0.value) <= Self.lifetime }

        var newestPerApp: [String: AlertItem] = [:]
        for alert in alerts where present.contains(alert.appID) {
            if let dismissed = dismissedUntil[alert.appID], alert.date <= dismissed { continue }
            if let existing = newestPerApp[alert.appID], existing.date >= alert.date { continue }
            newestPerApp[alert.appID] = alert
        }
        lock.unlock()

        if thresholds.enabled {
            for entry in fired { AlertNotifier.shared.post(entry.alert, iconPath: entry.iconPath) }
        }
        return newestPerApp.values.sorted { $0.date != $1.date ? $0.date > $1.date : $0.appName < $1.appName }
    }

    /// Hides the app from "Worth a Look" until it misbehaves again.
    public func dismiss(_ alert: AlertItem) {
        lock.lock()
        let previous = dismissedUntil[alert.appID] ?? .distantPast
        dismissedUntil[alert.appID] = max(previous, alert.date)
        lock.unlock()
    }

    private func isIgnored(_ app: AppUsage) -> Bool {
        if app.kind == .system || app.id == "system" { return true }
        if app.mainPid == ownPid { return true }
        if let ownBundleIdentifier, app.bundleIdentifier == ownBundleIdentifier { return true }
        if let ownBundlePath, app.bundlePath == ownBundlePath { return true }
        return app.processes.contains { $0.pid == ownPid }
    }

    private static func executablePath(of app: AppUsage) -> String? {
        let main = app.processes.first { $0.pid == app.mainPid } ?? app.processes.first
        return main?.executablePath
    }

    static func title(for kind: AlertKind, appName: String) -> String {
        let name = shortName(appName)
        return switch kind {
        case .highCPU: "\(name) is using a lot of CPU"
        case .growingMemory: "\(name)'s memory keeps growing"
        case .heavyDisk: "\(name) is writing heavily to disk"
        case .heavyNetwork: "\(name) is using the network heavily"
        }
    }

    /// The name people use for an app whose full name is long: "Chrome" for "Google Chrome".
    static func shortName(_ appName: String) -> String {
        shortNames[appName] ?? appName
    }

    private static let shortNames: [String: String] = [
        "Google Chrome": "Chrome",
        "Google Chrome Beta": "Chrome Beta",
        "Google Chrome Canary": "Chrome Canary",
        "Microsoft Edge": "Edge",
        "Microsoft Teams": "Teams",
        "Microsoft Outlook": "Outlook",
        "Microsoft Word": "Word",
        "Microsoft Excel": "Excel",
        "Microsoft PowerPoint": "PowerPoint",
        "Visual Studio Code": "VS Code",
    ]

    /// "half an hour", "an hour", "12 minutes".
    static func spanText(minutes: Double) -> String {
        switch minutes.rounded() {
        case 30: "half an hour"
        case 60: "an hour"
        default: minutesText(minutes)
        }
    }

    /// "10 minutes", "1 minute", "2.5 minutes".
    static func minutesText(_ minutes: Double) -> String {
        let rounded = (minutes * 10).rounded() / 10
        let number = rounded == rounded.rounded() ? String(format: "%.0f", rounded) : String(format: "%.1f", rounded)
        return rounded == 1 ? "1 minute" : "\(number) minutes"
    }

    /// "85 MB/s", "4.2 MB/s", "730 kB/s".
    static func rateText(_ bytesPerSecond: Double) -> String {
        let megabytes = bytesPerSecond / megabyte
        if megabytes >= 1000 { return String(format: "%.1f GB/s", megabytes / 1000) }
        if megabytes >= 10 { return String(format: "%.0f MB/s", megabytes) }
        if megabytes >= 1 { return String(format: "%.1f MB/s", megabytes) }
        return Format.rate(bytesPerSecond).text
    }

    /// Memory in binary units with one decimal, as in "Up 1.4 GB in half an hour, now 3.3 GB."
    static func memoryText(_ bytes: Double) -> String {
        let gigabytes = bytes / gibibyte
        if gigabytes >= 1 { return String(format: "%.1f GB", gigabytes) }
        return String(format: "%.0f MB", bytes / (1024 * 1024))
    }

    struct Finding {
        var kind: AlertKind
        var detail: String
    }

    /// One slot of an app's rolling window. Levels are integrals (value × seconds), rates are bytes.
    struct Slot {
        var start: TimeInterval
        var seconds: Double = 0
        var cpu: Double = 0
        var diskWrite: Double = 0
        var network: Double = 0
        var memory: UInt64 = 0
    }

    struct AppTracker {
        var firstSeen: Date
        var lastSeen: Date
        var mainPid: Int32?
        var slots: [Slot] = []

        init(firstSeen: Date, mainPid: Int32?) {
            self.firstSeen = firstSeen
            lastSeen = firstSeen
            self.mainPid = mainPid
        }

        mutating func update(with app: AppUsage, at now: Date, interval: TimeInterval, thresholds: AlertThresholds) -> [Finding] {
            // A relaunched app starts over, so its launch is not mistaken for growth.
            if let pid = app.mainPid, let previous = mainPid, pid != previous {
                slots.removeAll()
                firstSeen = now
            }
            mainPid = app.mainPid ?? mainPid
            lastSeen = now
            add(app, at: now, interval: interval)
            trim(before: now.timeIntervalSince1970 - max(AlertEngine.memoryWindow, thresholds.cpuMinutes * 60) - AlertEngine.slotLength)

            // Only apps busy right now are worth the window arithmetic.
            var findings: [Finding] = []
            if app.cpuPercent >= thresholds.cpuPercent * 0.5, let finding = cpuFinding(now: now, thresholds: thresholds) {
                findings.append(finding)
            }
            if let finding = memoryFinding(now: now, current: app.memoryBytes, thresholds: thresholds) {
                findings.append(finding)
            }
            if app.diskWriteBytesPerSecond >= thresholds.diskMBps * AlertEngine.megabyte * 0.25,
               let finding = sustainedFinding(kind: .heavyDisk, value: \.diskWrite, limit: thresholds.diskMBps, now: now) {
                findings.append(finding)
            }
            if app.networkInBytesPerSecond + app.networkOutBytesPerSecond >= thresholds.networkMBps * AlertEngine.megabyte * 0.25,
               let finding = sustainedFinding(kind: .heavyNetwork, value: \.network, limit: thresholds.networkMBps, now: now) {
                findings.append(finding)
            }
            return findings
        }

        private mutating func add(_ app: AppUsage, at now: Date, interval: TimeInterval) {
            let time = now.timeIntervalSince1970
            let start = floor(time / AlertEngine.slotLength) * AlertEngine.slotLength
            if slots.last?.start != start { slots.append(Slot(start: start)) }
            let index = slots.count - 1
            func clean(_ value: Double) -> Double { value.isFinite ? max(0, value) : 0 }
            slots[index].seconds += interval
            slots[index].cpu += clean(app.cpuPercent) * interval
            slots[index].diskWrite += clean(app.diskWriteBytesPerSecond) * interval
            slots[index].network += clean(app.networkInBytesPerSecond + app.networkOutBytesPerSecond) * interval
            slots[index].memory = app.memoryBytes
        }

        private mutating func trim(before cutoff: TimeInterval) {
            guard let first = slots.firstIndex(where: { $0.start + AlertEngine.slotLength > cutoff }) else {
                slots.removeAll()
                return
            }
            if first > 0 { slots.removeFirst(first) }
        }

        /// Slots overlapping the last `length` seconds, oldest first.
        private func window(_ length: TimeInterval, now: Date) -> ArraySlice<Slot> {
            let cutoff = now.timeIntervalSince1970 - length
            let first = slots.lastIndex { $0.start + AlertEngine.slotLength <= cutoff }.map { $0 + 1 } ?? 0
            return slots[first...]
        }

        private func isObserved(for length: TimeInterval, now: Date) -> Bool {
            now.timeIntervalSince(firstSeen) >= length
        }

        private func cpuFinding(now: Date, thresholds: AlertThresholds) -> Finding? {
            let length = max(60, thresholds.cpuMinutes * 60)
            guard thresholds.cpuPercent > 0, isObserved(for: length, now: now) else { return nil }
            let recent = window(length, now: now)
            let seconds = recent.reduce(0) { $0 + $1.seconds }
            guard seconds >= length * AlertEngine.minimumCoverage else { return nil }
            let average = recent.reduce(0) { $0 + $1.cpu } / seconds
            guard average >= thresholds.cpuPercent else { return nil }
            let detail = "Averaged \(Int(average.rounded()))% over the last \(AlertEngine.minutesText(length / 60))."
            return Finding(kind: .highCPU, detail: detail)
        }

        /// Growth above the threshold within 30 minutes that is mostly monotonic and not one sudden jump.
        private func memoryFinding(now: Date, current: UInt64, thresholds: AlertThresholds) -> Finding? {
            let threshold = thresholds.memoryGrowthGB * AlertEngine.gibibyte
            guard threshold > 0, Double(current) >= threshold, isObserved(for: AlertEngine.memoryMinimumSpan, now: now) else { return nil }
            let recent = window(AlertEngine.memoryWindow, now: now)
            guard let baseline = recent.first, recent.count >= 4 else { return nil }
            let span = now.timeIntervalSince1970 - baseline.start
            guard span >= AlertEngine.memoryMinimumSpan else { return nil }
            let growth = Double(current) - Double(baseline.memory)
            guard growth >= threshold else { return nil }

            var rises = 0.0
            var falls = 0.0
            var largestStep = 0.0
            var previous = Double(baseline.memory)
            for slot in recent.dropFirst() {
                let step = Double(slot.memory) - previous
                if step > 0 { rises += step } else { falls -= step }
                largestStep = max(largestStep, step)
                previous = Double(slot.memory)
            }
            guard falls <= rises * 0.25, largestStep <= growth * 0.5 else { return nil }

            let minutes = min(30, max(1, (span / 60).rounded()))
            let detail = "Up \(AlertEngine.memoryText(growth)) in \(AlertEngine.spanText(minutes: minutes)), now \(AlertEngine.memoryText(Double(current)))."
            return Finding(kind: .growingMemory, detail: detail)
        }

        /// At least five minutes of back-to-back slots above half of `limit` MB/s, averaging above `limit` over the last five.
        private func sustainedFinding(kind: AlertKind, value: KeyPath<Slot, Double>, limit: Double, now: Date) -> Finding? {
            let length = AlertEngine.sustainedWindow
            let threshold = limit * AlertEngine.megabyte
            guard threshold > 0, isObserved(for: length, now: now) else { return nil }
            let cutoff = now.timeIntervalSince1970 - length
            var streakSeconds = 0.0
            var streakAmount = 0.0
            var recentSeconds = 0.0
            var recentAmount = 0.0
            var laterStart: TimeInterval?
            for slot in slots.reversed() {
                // Sampling slower than a slot (Low Power Mode) leaves empty slots the next sample covers; longer gaps break.
                if let laterStart, laterStart - slot.start > AlertEngine.maximumInterval { break }
                guard slot.seconds > 0, slot[keyPath: value] / slot.seconds >= threshold * 0.5 else { break }
                streakSeconds += slot.seconds
                streakAmount += slot[keyPath: value]
                if slot.start + AlertEngine.slotLength > cutoff {
                    recentSeconds += slot.seconds
                    recentAmount += slot[keyPath: value]
                }
                laterStart = slot.start
            }
            guard streakSeconds >= length, recentSeconds > 0 else { return nil }
            let average = recentAmount / recentSeconds
            guard average >= threshold else { return nil }
            let minutes = (streakSeconds / 60).rounded(.down)
            let total = Format.total(UInt64(min(streakAmount, 1e18))).text
            let detail = "\(AlertEngine.rateText(average)) for \(AlertEngine.minutesText(minutes)), \(total) in total."
            return Finding(kind: kind, detail: detail)
        }
    }
}
