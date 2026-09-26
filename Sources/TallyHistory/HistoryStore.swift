import AppKit
import Foundation
import TallyCore

/// 30 days of history in one SQLite file.
///
/// `record` adds each sample to the minute in progress and hands a finished minute to the database queue,
/// so it stays well under a millisecond and the file is written about once a minute. Queries read the file and add
/// the minutes still in memory. Whole-Mac figures and per-app figures keep their own clocks, because in the
/// background the engine samples apps less often than the Mac.
public final class HistoryStore: HistoryProviding, SystemHistoryRecording {
    /// The longest gap between two records integrated as continuous sampling; longer gaps (sleep, pauses) are capped.
    /// Covers the slowest background cadence (15 s, doubled in Low Power Mode) with room to spare.
    static let maximumInterval: TimeInterval = 60
    /// The weight of a record with no earlier one to measure from.
    static let firstInterval: TimeInterval = 1
    /// Ranges longer than this read per-app history from hourly rows.
    static let hourlyThreshold: TimeInterval = 2 * 86400

    public let fileURL: URL

    private let queue = DispatchQueue(label: "tally.history", qos: .utility)
    private let database: HistoryDatabase
    private let tail = Tail()
    private var terminationObserver: NSObjectProtocol?

    /// Minutes not yet in the file: the one in progress and finished ones waiting for the queue.
    private final class Tail {
        let lock = NSLock()
        var current: MinuteRecord?
        var pending: [MinuteRecord] = []
        var lastRecordDate: Date?
        var lastAppRecordDate: Date?
        var sequence: UInt64 = 0
        /// Bumped by `clearAll` so writes queued before it are dropped.
        var generation = 0

        func records() -> [MinuteRecord] {
            lock.lock()
            defer { lock.unlock() }
            guard let current else { return pending }
            return pending + [current]
        }
    }

    public init(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("history.sqlite")
        database = HistoryDatabase(fileURL: fileURL)
        queue.async { [database] in
            let now = Date()
            database.prune(now: Int64(now.timeIntervalSince1970))
            database.vacuumIfDue(now: now)
        }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { [weak self] _ in
            self?.flush()
        }
    }

    deinit {
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
        flush()
        queue.sync { database.close() }
    }

    public func record(snapshot: SystemSnapshot, apps: [AppUsage]) {
        record(snapshot, apps: apps)
    }

    public func recordSystem(snapshot: SystemSnapshot) {
        record(snapshot, apps: nil)
    }

    private func record(_ snapshot: SystemSnapshot, apps: [AppUsage]?) {
        let date = snapshot.date
        let time = date.timeIntervalSince1970
        guard time.isFinite, time > 0 else { return }
        let minute = Int64(floor(time / 60)) * 60
        var finished: MinuteRecord?
        var generation = 0

        tail.lock.lock()
        guard let interval = Self.interval(since: tail.lastRecordDate, to: date) else {
            tail.lock.unlock()
            return
        }
        tail.lastRecordDate = date
        if let current = tail.current, current.minute != minute {
            tail.pending.append(current)
            finished = current
            generation = tail.generation
            tail.current = nil
        }
        if tail.current == nil {
            tail.sequence += 1
            tail.current = MinuteRecord(minute: minute, sequence: tail.sequence)
        }
        tail.current?.add(snapshot, interval: interval)
        if let apps, let appInterval = Self.interval(since: tail.lastAppRecordDate, to: date) {
            tail.lastAppRecordDate = date
            tail.current?.add(apps: apps, interval: appInterval)
        }
        tail.lock.unlock()

        if let finished { write(finished, generation: generation) }
    }

    /// Seconds a record stands for, or nil for a repeat of the previous record's moment.
    private static func interval(since last: Date?, to date: Date) -> TimeInterval? {
        guard let last else { return firstInterval }
        let delta = date.timeIntervalSince(last)
        guard delta != 0 else { return nil }
        return delta > 0 ? min(delta, maximumInterval) : firstInterval
    }

    private func write(_ record: MinuteRecord, generation: Int) {
        queue.async { [database, tail] in
            tail.lock.lock()
            let isCurrent = tail.generation == generation
            tail.lock.unlock()
            if isCurrent { database.insert(record) }
            tail.lock.lock()
            if tail.pending.first?.sequence == record.sequence {
                tail.pending.removeFirst()
            } else {
                tail.pending.removeAll { $0.sequence == record.sequence }
            }
            tail.lock.unlock()
        }
    }

    /// Writes the minute in progress now rather than when the next one starts. Runs on quit.
    public func flush() {
        queue.sync {
            tail.lock.lock()
            let current = tail.current
            tail.current = nil
            tail.lock.unlock()
            if let current { database.insert(current) }
            database.checkpoint()
        }
    }

    /// Bytes on disk: the database and its write-ahead log.
    public var fileSize: UInt64 {
        ["", "-wal"].reduce(0) { total, suffix in
            let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path + suffix)
            return total + ((attributes?[.size] as? NSNumber)?.uint64Value ?? 0)
        }
    }

    public func series(_ metric: HistoryMetric, range: HistoryRange, buckets: Int) -> [HistoryPoint] {
        let window = BucketWindow(range: range, buckets: buckets, now: Date(), granularity: 60)
        return queue.sync {
            var ratios = database.systemBuckets(metric, window: window)
            for record in tail.records() {
                guard let index = window.index(forMinute: record.minute) else { continue }
                ratios[index, default: Ratio()].add(record.systemRatio(for: metric))
            }
            return window.points(from: ratios, zeroFillGaps: metric.isRate)
        }
    }

    public func appSeries(appID: String, metric: HistoryMetric, range: HistoryRange, buckets: Int) -> [HistoryPoint] {
        guard metric.appColumn != nil else { return [] }
        let granularity: Int64 = range.duration > Self.hourlyThreshold ? 3600 : 60
        let window = BucketWindow(range: range, buckets: buckets, now: Date(), granularity: granularity)
        return queue.sync {
            let amounts = database.appBuckets(key: appID, metric: metric, window: window)
            var ratios: [Int: Ratio] = [:]
            var hasUsage = !amounts.isEmpty
            for (index, seconds) in database.secondsBuckets(window: window) {
                ratios[index, default: Ratio()].denominator += seconds
            }
            for (index, amount) in amounts {
                ratios[index, default: Ratio()].numerator += amount
            }
            for record in tail.records() {
                guard let index = window.index(forMinute: record.minute) else { continue }
                ratios[index, default: Ratio()].denominator += record.seconds
                if let usage = record.apps[appID] {
                    ratios[index, default: Ratio()].numerator += usage.amount(for: metric)
                    hasUsage = true
                }
            }
            guard hasUsage else { return [] }
            return window.points(from: ratios, zeroFillGaps: metric.isRate)
        }
    }

    public func topApps(_ metric: HistoryMetric, range: HistoryRange, limit: Int) -> [HistoryAppTotal] {
        guard metric.appColumn != nil, limit > 0 else { return [] }
        let hourly = range.duration > Self.hourlyThreshold
        let granularity: Int64 = hourly ? 3600 : 60
        let start = (Int64(floor(Date().timeIntervalSince1970 - range.duration)) / granularity) * granularity
        return queue.sync {
            var rows: [String: AppTotalRow] = [:]
            for row in database.appTotals(metric: metric, from: start, hourly: hourly) {
                rows[row.key] = row
            }
            var seconds = metric.isRate ? 0 : database.sampledSeconds(from: start)
            for record in tail.records() where record.minute >= start {
                seconds += record.seconds
                for (key, usage) in record.apps {
                    let amount = usage.amount(for: metric)
                    if var existing = rows[key] {
                        existing.amount += amount
                        existing.name = usage.name
                        existing.bundlePath = usage.bundlePath
                        rows[key] = existing
                    } else if amount > 0 {
                        rows[key] = AppTotalRow(key: key, name: usage.name, bundlePath: usage.bundlePath, amount: amount)
                    }
                }
            }
            let totals = rows.values.compactMap { row -> HistoryAppTotal? in
                let value = metric.isRate ? row.amount : (seconds > 0 ? row.amount / seconds : 0)
                guard value > 0, value.isFinite else { return nil }
                return HistoryAppTotal(appID: row.key, name: row.name, bundlePath: row.bundlePath, value: value)
            }
            let sorted = totals.sorted { $0.value != $1.value ? $0.value > $1.value : $0.name < $1.name }
            return Array(sorted.prefix(limit))
        }
    }

    public func totals() -> UsageTotals {
        let now = Date()
        let today = Int64(Calendar.current.startOfDay(for: now).timeIntervalSince1970)
        let week = Int64(now.timeIntervalSince1970) - 7 * 86400
        let month = Int64(now.timeIntervalSince1970) - 30 * 86400
        return queue.sync {
            var row = database.totals(today: today, week: week, month: month)
            for record in tail.records() {
                if record.minute >= month { row.networkInMonth += record.networkIn }
                if record.minute >= week { row.networkInWeek += record.networkIn }
                guard record.minute >= today else { continue }
                row.networkInToday += record.networkIn
                row.networkOutToday += record.networkOut
                row.diskWrittenToday += record.diskWrite
                row.cpuToday.add(Ratio(numerator: record.cpu, denominator: record.seconds))
                row.gpuToday.add(Ratio(numerator: record.gpu, denominator: record.seconds))
                row.gpuPeakToday = max(row.gpuPeakToday, record.gpuPeak)
            }
            var totals = UsageTotals()
            totals.networkInToday = Self.bytes(row.networkInToday)
            totals.networkOutToday = Self.bytes(row.networkOutToday)
            totals.networkInLast7Days = Self.bytes(row.networkInWeek)
            totals.networkInLast30Days = Self.bytes(row.networkInMonth)
            totals.diskWrittenToday = Self.bytes(row.diskWrittenToday)
            totals.cpuAverageToday = row.cpuToday.value ?? 0
            totals.gpuAverageToday = row.gpuToday.value ?? 0
            totals.gpuPeakToday = row.gpuPeakToday
            return totals
        }
    }

    public func clearAll() {
        tail.lock.lock()
        tail.generation += 1
        tail.current = nil
        tail.pending.removeAll()
        tail.lock.unlock()
        queue.async { [database] in database.clear() }
    }

    private static func bytes(_ value: Double) -> UInt64 {
        value.isFinite && value > 0 ? UInt64(value.rounded()) : 0
    }
}
