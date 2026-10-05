import Foundation
import SQLite3
import TallyCore

struct AppTotalRow {
    var key: String
    var name: String
    var bundlePath: String?
    var amount: Double
}

struct TotalsRow {
    var networkInToday: Double = 0
    var networkOutToday: Double = 0
    var networkInWeek: Double = 0
    var networkInMonth: Double = 0
    var diskWrittenToday: Double = 0
    var cpuToday = Ratio()
    var gpuToday = Ratio()
    var gpuPeakToday: Double = 0
}

/// The history file. Every method must be called on the history store's serial queue.
final class HistoryDatabase {
    static let schemaVersion: Int64 = 1
    /// Minute rows per app are kept long enough for the 24 hour range; older ranges read hourly rows.
    static let appMinuteRetention: Int64 = 50 * 3600
    /// The longest chart range. Whole-Mac minutes and hourly rows per app outlive it and are kept for good, except
    /// that past it an app needs at least `lastingAppHours` hourly rows to stay: one-off tools (build products,
    /// temporary binaries) would otherwise fill the file with their paths.
    static let chartRetention: Int64 = 30 * 86400
    static let lastingAppHours: Int64 = 3
    static let pruneInterval: Int64 = 3600
    static let vacuumInterval: Double = 7 * 86400
    static let appsPerMetric = 15

    let fileURL: URL
    private var connection: SQLiteConnection?
    private var didAttemptOpen = false
    private var appIDs: [String: CachedApp] = [:]
    private var lastPrune: Int64 = 0

    private struct CachedApp {
        var id: Int64
        var name: String
        var bundlePath: String?
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    private enum OpenResult {
        case opened(SQLiteConnection)
        case damaged
        case failed
    }

    private var database: SQLiteConnection? {
        if let connection { return connection }
        guard !didAttemptOpen else { return nil }
        didAttemptOpen = true
        switch openAndMigrate() {
        case .opened(let opened):
            connection = opened
        case .damaged:
            replaceDamagedFile()
        case .failed:
            NSLog("Tally history: %@ could not be opened, keeping history in memory only", fileURL.path)
        }
        return connection
    }

    private func openAndMigrate() -> OpenResult {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let opened = SQLiteConnection(path: fileURL.path) else { return .failed }
        func failure() -> OpenResult {
            let code = opened.primaryErrorCode
            opened.close()
            return Self.isDamage(code) ? .damaged : .failed
        }
        guard let version = opened.scalar("PRAGMA user_version") else { return failure() }
        if version != 0 && version != Self.schemaVersion {
            for table in ["app_hour", "app_minute", "apps", "system_minute", "meta"] {
                opened.execute("DROP TABLE IF EXISTS \(table)")
            }
        }
        let setup = """
        PRAGMA auto_vacuum = INCREMENTAL;
        PRAGMA journal_mode = WAL;
        PRAGMA synchronous = NORMAL;
        PRAGMA journal_size_limit = 1048576;
        PRAGMA wal_autocheckpoint = 256;
        PRAGMA temp_store = MEMORY;
        CREATE TABLE IF NOT EXISTS system_minute (
            minute INTEGER PRIMARY KEY,
            seconds REAL NOT NULL,
            cpu REAL NOT NULL,
            memory REAL NOT NULL,
            gpu REAL NOT NULL,
            gpu_peak REAL NOT NULL,
            battery REAL,
            power REAL,
            cpu_temperature REAL,
            disk_read INTEGER NOT NULL,
            disk_write INTEGER NOT NULL,
            network_in INTEGER NOT NULL,
            network_out INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS apps (
            id INTEGER PRIMARY KEY,
            key TEXT NOT NULL UNIQUE,
            name TEXT NOT NULL,
            bundle_path TEXT
        );
        CREATE TABLE IF NOT EXISTS app_minute (
            minute INTEGER NOT NULL,
            app_id INTEGER NOT NULL,
            cpu REAL NOT NULL,
            memory REAL NOT NULL,
            gpu REAL NOT NULL,
            power REAL NOT NULL,
            disk_read INTEGER NOT NULL,
            disk_write INTEGER NOT NULL,
            network_in INTEGER NOT NULL,
            network_out INTEGER NOT NULL,
            PRIMARY KEY (minute, app_id)
        ) WITHOUT ROWID;
        CREATE INDEX IF NOT EXISTS app_minute_by_app ON app_minute (app_id, minute);
        CREATE TABLE IF NOT EXISTS app_hour (
            hour INTEGER NOT NULL,
            app_id INTEGER NOT NULL,
            cpu REAL NOT NULL,
            memory REAL NOT NULL,
            gpu REAL NOT NULL,
            power REAL NOT NULL,
            disk_read INTEGER NOT NULL,
            disk_write INTEGER NOT NULL,
            network_in INTEGER NOT NULL,
            network_out INTEGER NOT NULL,
            PRIMARY KEY (hour, app_id)
        ) WITHOUT ROWID;
        CREATE INDEX IF NOT EXISTS app_hour_by_app ON app_hour (app_id, hour);
        CREATE TABLE IF NOT EXISTS meta (
            key TEXT PRIMARY KEY,
            value REAL NOT NULL
        );
        PRAGMA user_version = \(Self.schemaVersion);
        """
        guard opened.execute(setup), opened.scalar("SELECT COUNT(*) FROM system_minute") != nil else { return failure() }
        return .opened(opened)
    }

    private static func isDamage(_ code: Int32) -> Bool {
        code == SQLITE_CORRUPT || code == SQLITE_NOTADB
    }

    /// Keeps one copy of the damaged file beside a new one, in case it is worth recovering by hand.
    private func replaceDamagedFile() {
        NSLog("Tally history: %@ is damaged, moving it aside and starting a new file", fileURL.path)
        connection?.close()
        connection = nil
        appIDs.removeAll()
        let manager = FileManager.default
        let damaged = fileURL.deletingPathExtension().appendingPathExtension("damaged.sqlite")
        try? manager.removeItem(at: damaged)
        try? manager.moveItem(at: fileURL, to: damaged)
        for suffix in ["-wal", "-shm"] {
            try? manager.removeItem(atPath: fileURL.path + suffix)
        }
        didAttemptOpen = true
        if case .opened(let opened) = openAndMigrate() { connection = opened }
    }

    func close() {
        connection?.close()
        connection = nil
        didAttemptOpen = false
        appIDs.removeAll()
    }

    func insert(_ record: MinuteRecord) {
        guard record.seconds > 0, let database else { return }
        guard database.execute("BEGIN IMMEDIATE") else { return }
        // A failed COMMIT (a full disk) can leave the transaction open, and every later BEGIN would then fail.
        if !write(record, to: database) || !database.execute("COMMIT") {
            NSLog("Tally history: write failed: %@", database.errorMessage)
            let code = database.primaryErrorCode
            database.execute("ROLLBACK")
            appIDs.removeAll()
            if Self.isDamage(code) {
                replaceDamagedFile()
                return
            }
        }
        if abs(record.minute - lastPrune) >= Self.pruneInterval {
            prune(now: record.minute)
        }
    }

    private func write(_ record: MinuteRecord, to database: SQLiteConnection) -> Bool {
        var previousSeconds = 0.0
        if let lookup = database.prepared("SELECT seconds FROM system_minute WHERE minute = ?1") {
            lookup.bind(record.minute, at: 1)
            lookup.forEachRow { previousSeconds = lookup.double(at: 0) }
        }
        let totalSeconds = previousSeconds + record.seconds

        let systemSQL = """
        INSERT INTO system_minute (minute, seconds, cpu, memory, gpu, gpu_peak, battery, power, cpu_temperature,
            disk_read, disk_write, network_in, network_out)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)
        ON CONFLICT (minute) DO UPDATE SET
            seconds = seconds + excluded.seconds,
            cpu = (cpu * seconds + excluded.cpu * excluded.seconds) / (seconds + excluded.seconds),
            memory = (memory * seconds + excluded.memory * excluded.seconds) / (seconds + excluded.seconds),
            gpu = (gpu * seconds + excluded.gpu * excluded.seconds) / (seconds + excluded.seconds),
            gpu_peak = max(gpu_peak, excluded.gpu_peak),
            battery = CASE WHEN battery IS NULL THEN excluded.battery WHEN excluded.battery IS NULL THEN battery
                ELSE (battery * seconds + excluded.battery * excluded.seconds) / (seconds + excluded.seconds) END,
            power = CASE WHEN power IS NULL THEN excluded.power WHEN excluded.power IS NULL THEN power
                ELSE (power * seconds + excluded.power * excluded.seconds) / (seconds + excluded.seconds) END,
            cpu_temperature = CASE WHEN cpu_temperature IS NULL THEN excluded.cpu_temperature
                WHEN excluded.cpu_temperature IS NULL THEN cpu_temperature
                ELSE (cpu_temperature * seconds + excluded.cpu_temperature * excluded.seconds) / (seconds + excluded.seconds) END,
            disk_read = disk_read + excluded.disk_read,
            disk_write = disk_write + excluded.disk_write,
            network_in = network_in + excluded.network_in,
            network_out = network_out + excluded.network_out
        """
        guard let system = database.prepared(systemSQL) else { return false }
        let seconds = record.seconds
        system.bind(record.minute, at: 1)
        system.bind(seconds, at: 2)
        system.bind(record.cpu / seconds, at: 3)
        system.bind((record.memory / seconds).rounded(), at: 4)
        system.bind(record.gpu / seconds, at: 5)
        system.bind(record.gpuPeak, at: 6)
        system.bind(record.average(record.battery, over: record.batterySeconds), at: 7)
        system.bind(record.average(record.power, over: record.powerSeconds), at: 8)
        system.bind(record.average(record.temperature, over: record.temperatureSeconds), at: 9)
        system.bind(Int64(record.diskRead.rounded()), at: 10)
        system.bind(Int64(record.diskWrite.rounded()), at: 11)
        system.bind(Int64(record.networkIn.rounded()), at: 12)
        system.bind(Int64(record.networkOut.rounded()), at: 13)
        guard system.run() else { return false }

        // A second write for the same minute: existing averages now cover a longer span.
        if previousSeconds > 0 {
            guard let dilute = database.prepared("""
            UPDATE app_minute SET cpu = cpu * ?2, memory = memory * ?2, gpu = gpu * ?2, power = power * ?2 WHERE minute = ?1
            """) else { return false }
            dilute.bind(record.minute, at: 1)
            dilute.bind(previousSeconds / totalSeconds, at: 2)
            guard dilute.run() else { return false }
        }

        let minuteSQL = """
        INSERT INTO app_minute (minute, app_id, cpu, memory, gpu, power, disk_read, disk_write, network_in, network_out)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
        ON CONFLICT (minute, app_id) DO UPDATE SET
            cpu = cpu + excluded.cpu, memory = memory + excluded.memory, gpu = gpu + excluded.gpu, power = power + excluded.power,
            disk_read = disk_read + excluded.disk_read, disk_write = disk_write + excluded.disk_write,
            network_in = network_in + excluded.network_in, network_out = network_out + excluded.network_out
        """
        let hourSQL = """
        INSERT INTO app_hour (hour, app_id, cpu, memory, gpu, power, disk_read, disk_write, network_in, network_out)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
        ON CONFLICT (hour, app_id) DO UPDATE SET
            cpu = cpu + excluded.cpu, memory = memory + excluded.memory, gpu = gpu + excluded.gpu, power = power + excluded.power,
            disk_read = disk_read + excluded.disk_read, disk_write = disk_write + excluded.disk_write,
            network_in = network_in + excluded.network_in, network_out = network_out + excluded.network_out
        """
        let hour = (record.minute / 3600) * 3600
        for (key, usage) in record.retainedApps(limit: Self.appsPerMetric) {
            guard let appID = appID(for: key, name: usage.name, bundlePath: usage.bundlePath, in: database) else { return false }
            guard let minuteRow = database.prepared(minuteSQL) else { return false }
            minuteRow.bind(record.minute, at: 1)
            minuteRow.bind(appID, at: 2)
            minuteRow.bind(usage.cpu / totalSeconds, at: 3)
            minuteRow.bind((usage.memory / totalSeconds).rounded(), at: 4)
            minuteRow.bind(usage.gpu / totalSeconds, at: 5)
            minuteRow.bind(usage.power / totalSeconds, at: 6)
            bindBytes(usage, to: minuteRow)
            guard minuteRow.run() else { return false }

            guard let hourRow = database.prepared(hourSQL) else { return false }
            hourRow.bind(hour, at: 1)
            hourRow.bind(appID, at: 2)
            hourRow.bind(usage.cpu, at: 3)
            hourRow.bind(usage.memory.rounded(), at: 4)
            hourRow.bind(usage.gpu, at: 5)
            hourRow.bind(usage.power, at: 6)
            bindBytes(usage, to: hourRow)
            guard hourRow.run() else { return false }
        }
        return true
    }

    private func bindBytes(_ usage: AppMinute, to statement: SQLiteStatement) {
        statement.bind(Int64(usage.diskRead.rounded()), at: 7)
        statement.bind(Int64(usage.diskWrite.rounded()), at: 8)
        statement.bind(Int64(usage.networkIn.rounded()), at: 9)
        statement.bind(Int64(usage.networkOut.rounded()), at: 10)
    }

    private func appID(for key: String, name: String, bundlePath: String?, in database: SQLiteConnection) -> Int64? {
        if let cached = appIDs[key], cached.name == name, cached.bundlePath == bundlePath {
            return cached.id
        }
        guard let upsert = database.prepared("""
        INSERT INTO apps (key, name, bundle_path) VALUES (?1, ?2, ?3)
        ON CONFLICT (key) DO UPDATE SET name = excluded.name, bundle_path = excluded.bundle_path
        RETURNING id
        """) else { return nil }
        upsert.bind(key, at: 1)
        upsert.bind(name, at: 2)
        upsert.bind(bundlePath, at: 3)
        var identifier: Int64?
        upsert.forEachRow { identifier = upsert.int64(at: 0) }
        if let identifier {
            appIDs[key] = CachedApp(id: identifier, name: name, bundlePath: bundlePath)
        }
        return identifier
    }

    /// Drops what is not kept for good, relative to `now` (Unix seconds): per-app minutes past their retention and
    /// apps that came and went before the chart ranges begin.
    func prune(now: Int64) {
        guard let database else { return }
        lastPrune = now
        let chartStart = ((now - Self.chartRetention) / 3600) * 3600
        database.execute("BEGIN IMMEDIATE")
        if let minutes = database.prepared("DELETE FROM app_minute WHERE minute < ?1") {
            minutes.bind(now - Self.appMinuteRetention, at: 1)
            minutes.run()
        }
        // Only an app with an hour that left the chart ranges since the last pass can have become a passing one.
        let passingSQL = """
        DELETE FROM app_hour WHERE app_id IN (
            SELECT app_id FROM app_hour
            WHERE app_id IN (SELECT app_id FROM app_hour WHERE hour >= ?1 AND hour < ?2)
            GROUP BY app_id HAVING COUNT(*) < ?3 AND MAX(hour) < ?2
        )
        """
        if let passing = database.prepared(passingSQL) {
            passing.bind(Int64(metaValue("compacted_through", in: database) ?? 0), at: 1)
            passing.bind(chartStart, at: 2)
            passing.bind(Self.lastingAppHours, at: 3)
            if passing.run() { setMeta("compacted_through", Double(chartStart), in: database) }
        }
        // Probes each app's index entries rather than reading every hourly row ever kept.
        database.execute("""
        DELETE FROM apps WHERE NOT EXISTS (SELECT 1 FROM app_hour WHERE app_id = apps.id)
            AND NOT EXISTS (SELECT 1 FROM app_minute WHERE app_id = apps.id)
        """)
        if !database.execute("COMMIT") { database.execute("ROLLBACK") }
        appIDs.removeAll()
        if let free = database.scalar("PRAGMA freelist_count"), free > 256 {
            database.execute("PRAGMA incremental_vacuum")
        }
    }

    /// Rebuilds the file about once a week, when a good share of it is free pages.
    func vacuumIfDue(now: Date) {
        guard let database else { return }
        let last = metaValue("last_vacuum", in: database)
        guard let last else {
            setMeta("last_vacuum", now.timeIntervalSince1970, in: database)
            return
        }
        guard now.timeIntervalSince1970 - last >= Self.vacuumInterval else { return }
        let pages = database.scalar("PRAGMA page_count") ?? 0
        let free = database.scalar("PRAGMA freelist_count") ?? 0
        if pages > 0, Double(free) / Double(pages) > 0.2 {
            database.execute("VACUUM")
            database.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        }
        setMeta("last_vacuum", now.timeIntervalSince1970, in: database)
    }

    private func metaValue(_ key: String, in database: SQLiteConnection) -> Double? {
        guard let statement = database.prepared("SELECT value FROM meta WHERE key = ?1") else { return nil }
        statement.bind(key, at: 1)
        var value: Double?
        statement.forEachRow { value = statement.double(at: 0) }
        return value
    }

    private func setMeta(_ key: String, _ value: Double, in database: SQLiteConnection) {
        guard let statement = database.prepared("INSERT OR REPLACE INTO meta (key, value) VALUES (?1, ?2)") else { return }
        statement.bind(key, at: 1)
        statement.bind(value, at: 2)
        statement.run()
    }

    func clear() {
        guard let database else { return }
        if !database.execute("BEGIN IMMEDIATE; DELETE FROM app_hour; DELETE FROM app_minute; DELETE FROM apps; DELETE FROM system_minute; COMMIT;") {
            database.execute("ROLLBACK")
        }
        appIDs.removeAll()
        database.execute("VACUUM")
        database.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        setMeta("last_vacuum", Date().timeIntervalSince1970, in: database)
    }

    func checkpoint() {
        connection?.execute("PRAGMA wal_checkpoint(PASSIVE)")
    }

    func systemBuckets(_ metric: HistoryMetric, window: BucketWindow) -> [Int: Ratio] {
        guard let database else { return [:] }
        let column = metric.systemColumn
        let sums = metric.isRate
            ? "SUM(\(column)), SUM(seconds)"
            : "SUM(\(column) * seconds), SUM(CASE WHEN \(column) IS NULL THEN 0 ELSE seconds END)"
        let sql = """
        SELECT CAST((minute - ?1) / ?2 AS INTEGER) AS bucket, \(sums)
        FROM system_minute WHERE minute >= ?3 AND minute < ?4 GROUP BY bucket
        """
        guard let statement = database.prepared(sql) else { return [:] }
        bind(window, to: statement)
        var result: [Int: Ratio] = [:]
        statement.forEachRow {
            let index = window.clamp(Int(statement.int64(at: 0)))
            result[index, default: Ratio()].add(Ratio(numerator: statement.double(at: 1), denominator: statement.double(at: 2)))
        }
        return result
    }

    /// Seconds of sampling per bucket, placing each minute by the start of its minute or hour slot.
    func secondsBuckets(window: BucketWindow) -> [Int: Double] {
        guard let database else { return [:] }
        let sql = """
        SELECT CAST(((minute / ?5) * ?5 - ?1) / ?2 AS INTEGER) AS bucket, SUM(seconds)
        FROM system_minute WHERE minute >= ?3 AND minute < ?4 GROUP BY bucket
        """
        guard let statement = database.prepared(sql) else { return [:] }
        bind(window, to: statement)
        statement.bind(window.granularity, at: 5)
        var result: [Int: Double] = [:]
        statement.forEachRow {
            result[window.clamp(Int(statement.int64(at: 0))), default: 0] += statement.double(at: 1)
        }
        return result
    }

    /// Integrals (levels) or bytes (rates) for one app per bucket.
    func appBuckets(key: String, metric: HistoryMetric, window: BucketWindow) -> [Int: Double] {
        guard let database, let column = metric.appColumn, let appID = storedAppID(for: key, in: database) else { return [:] }
        let sql: String
        if window.granularity >= 3600 {
            sql = """
            SELECT CAST((hour - ?1) / ?2 AS INTEGER) AS bucket, SUM(\(column))
            FROM app_hour WHERE app_id = ?5 AND hour >= ?3 AND hour < ?4 GROUP BY bucket
            """
        } else if metric.isRate {
            sql = """
            SELECT CAST((minute - ?1) / ?2 AS INTEGER) AS bucket, SUM(\(column))
            FROM app_minute WHERE app_id = ?5 AND minute >= ?3 AND minute < ?4 GROUP BY bucket
            """
        } else {
            sql = """
            SELECT CAST((a.minute - ?1) / ?2 AS INTEGER) AS bucket, SUM(a.\(column) * s.seconds)
            FROM app_minute a JOIN system_minute s ON s.minute = a.minute
            WHERE a.app_id = ?5 AND a.minute >= ?3 AND a.minute < ?4 GROUP BY bucket
            """
        }
        guard let statement = database.prepared(sql) else { return [:] }
        bind(window, to: statement)
        statement.bind(appID, at: 5)
        var result: [Int: Double] = [:]
        statement.forEachRow {
            result[window.clamp(Int(statement.int64(at: 0))), default: 0] += statement.double(at: 1)
        }
        return result
    }

    /// Per-app integrals (levels) or bytes (rates) since `start`, read from hourly rows when `hourly`.
    /// `+app_id` keeps SQLite on the time-ordered primary key instead of walking the per-app index.
    func appTotals(metric: HistoryMetric, from start: Int64, hourly: Bool) -> [AppTotalRow] {
        guard let database, let column = metric.appColumn else { return [] }
        let inner: String
        if hourly {
            inner = "SELECT app_id, SUM(\(column)) AS total FROM app_hour WHERE hour >= ?1 GROUP BY +app_id"
        } else if metric.isRate {
            inner = "SELECT app_id, SUM(\(column)) AS total FROM app_minute WHERE minute >= ?1 GROUP BY +app_id"
        } else {
            inner = """
            SELECT a.app_id AS app_id, SUM(a.\(column) * s.seconds) AS total
            FROM app_minute a JOIN system_minute s ON s.minute = a.minute WHERE a.minute >= ?1 GROUP BY +a.app_id
            """
        }
        let sql = "SELECT p.key, p.name, p.bundle_path, t.total FROM (\(inner)) t JOIN apps p ON p.id = t.app_id"
        guard let statement = database.prepared(sql) else { return [] }
        statement.bind(start, at: 1)
        var rows: [AppTotalRow] = []
        statement.forEachRow {
            guard let key = statement.string(at: 0) else { return }
            rows.append(AppTotalRow(key: key, name: statement.string(at: 1) ?? key, bundlePath: statement.string(at: 2), amount: statement.double(at: 3)))
        }
        return rows
    }

    func sampledSeconds(from start: Int64) -> Double {
        guard let database, let statement = database.prepared("SELECT SUM(seconds) FROM system_minute WHERE minute >= ?1") else { return 0 }
        statement.bind(start, at: 1)
        var seconds = 0.0
        statement.forEachRow { seconds = statement.double(at: 0) }
        return seconds
    }

    func totals(today: Int64, week: Int64, month: Int64) -> TotalsRow {
        var row = TotalsRow()
        guard let database else { return row }
        let sql = """
        SELECT
            SUM(CASE WHEN minute >= ?1 THEN network_in ELSE 0 END),
            SUM(CASE WHEN minute >= ?1 THEN network_out ELSE 0 END),
            SUM(CASE WHEN minute >= ?2 THEN network_in ELSE 0 END),
            SUM(network_in),
            SUM(CASE WHEN minute >= ?1 THEN disk_write ELSE 0 END),
            SUM(CASE WHEN minute >= ?1 THEN cpu * seconds ELSE 0 END),
            SUM(CASE WHEN minute >= ?1 THEN gpu * seconds ELSE 0 END),
            SUM(CASE WHEN minute >= ?1 THEN seconds ELSE 0 END),
            MAX(CASE WHEN minute >= ?1 THEN gpu_peak END)
        FROM system_minute WHERE minute >= ?3
        """
        guard let statement = database.prepared(sql) else { return row }
        statement.bind(today, at: 1)
        statement.bind(week, at: 2)
        statement.bind(month, at: 3)
        statement.forEachRow {
            row.networkInToday = statement.double(at: 0)
            row.networkOutToday = statement.double(at: 1)
            row.networkInWeek = statement.double(at: 2)
            row.networkInMonth = statement.double(at: 3)
            row.diskWrittenToday = statement.double(at: 4)
            let seconds = statement.double(at: 7)
            row.cpuToday = Ratio(numerator: statement.double(at: 5), denominator: seconds)
            row.gpuToday = Ratio(numerator: statement.double(at: 6), denominator: seconds)
            row.gpuPeakToday = statement.double(at: 8)
        }
        return row
    }

    /// Whole-Mac history in [start, end) by the hour, with hours counted in local time, `offset` seconds from UTC.
    func yearHours(from start: Int64, to end: Int64, offset: Int64) -> [YearHourRow] {
        let sql = """
        SELECT (minute + ?3) / 3600 AS hour, SUM(seconds), SUM(cpu * seconds), MAX(cpu_temperature),
            SUM(network_in), SUM(network_out), SUM(disk_write), MIN(minute), MAX(minute)
        FROM system_minute WHERE minute >= ?1 AND minute < ?2 GROUP BY hour
        """
        guard let database, let statement = database.prepared(sql) else { return [] }
        statement.bind(start, at: 1)
        statement.bind(end, at: 2)
        statement.bind(offset, at: 3)
        var rows: [YearHourRow] = []
        statement.forEachRow {
            rows.append(YearHourRow(
                hour: statement.int64(at: 0),
                seconds: statement.double(at: 1),
                cpuSeconds: statement.double(at: 2),
                hottest: statement.isNull(at: 3) ? nil : statement.double(at: 3),
                networkIn: statement.double(at: 4),
                networkOut: statement.double(at: 5),
                diskWrite: statement.double(at: 6),
                firstMinute: statement.int64(at: 7),
                lastMinute: statement.int64(at: 8)
            ))
        }
        return rows
    }

    /// Every app's sums over the hours in [start, end).
    func yearApps(from start: Int64, to end: Int64) -> [YearAppRow] {
        let sql = """
        SELECT p.key, p.name, p.bundle_path, t.cpu, t.memory, t.power, t.network FROM (
            SELECT app_id, SUM(cpu) AS cpu, SUM(memory) AS memory, SUM(power) AS power, SUM(network_in + network_out) AS network
            FROM app_hour WHERE hour >= ?1 AND hour < ?2 GROUP BY +app_id
        ) t JOIN apps p ON p.id = t.app_id
        """
        guard let database, let statement = database.prepared(sql) else { return [] }
        statement.bind(start, at: 1)
        statement.bind(end, at: 2)
        var rows: [YearAppRow] = []
        statement.forEachRow {
            guard let key = statement.string(at: 0) else { return }
            rows.append(YearAppRow(
                key: key,
                name: statement.string(at: 1) ?? key,
                bundlePath: statement.string(at: 2),
                cpu: statement.double(at: 3),
                memory: statement.double(at: 4),
                power: statement.double(at: 5),
                network: statement.double(at: 6)
            ))
        }
        return rows
    }

    private func bind(_ window: BucketWindow, to statement: SQLiteStatement) {
        statement.bind(window.start, at: 1)
        statement.bind(window.width, at: 2)
        statement.bind(window.queryStart, at: 3)
        statement.bind(window.queryEnd, at: 4)
    }

    private func storedAppID(for key: String, in database: SQLiteConnection) -> Int64? {
        if let cached = appIDs[key] { return cached.id }
        guard let statement = database.prepared("SELECT id FROM apps WHERE key = ?1") else { return nil }
        statement.bind(key, at: 1)
        var identifier: Int64?
        statement.forEachRow { identifier = statement.int64(at: 0) }
        return identifier
    }
}
