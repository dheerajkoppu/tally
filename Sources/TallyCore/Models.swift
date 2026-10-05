import Foundation

// MARK: - System-wide metrics

public struct CPUStats: Hashable, Sendable {
    /// 0...100, share of total machine capacity.
    public var totalPercent: Double = 0
    public var userPercent: Double = 0
    public var systemPercent: Double = 0
    /// 0...100 per logical core.
    public var perCorePercent: [Double] = []
    /// 1, 5 and 15 minute load averages.
    public var loadAverage: [Double] = [0, 0, 0]
    public var logicalCores: Int = 0
    public var performanceCores: Int = 0
    public var efficiencyCores: Int = 0
    public var chipName: String = ""

    public init() {}
}

public enum MemoryPressure: String, Hashable, Sendable {
    case normal, warning, critical

    public var label: String {
        switch self {
        case .normal: "Normal"
        case .warning: "Elevated"
        case .critical: "Critical"
        }
    }
}

public struct MemoryStats: Hashable, Sendable {
    public var totalBytes: UInt64 = 0
    public var appBytes: UInt64 = 0
    public var wiredBytes: UInt64 = 0
    public var compressedBytes: UInt64 = 0
    public var cachedBytes: UInt64 = 0
    public var freeBytes: UInt64 = 0
    public var swapUsedBytes: UInt64 = 0
    public var swapTotalBytes: UInt64 = 0
    public var pressure: MemoryPressure = .normal
    /// Memory Used as Activity Monitor shows it: everything that is neither free nor a cached file. That is App, Wired
    /// and Compressed, plus purgeable memory and the RAM macOS keeps out of its page counts.
    public var usedBytes: UInt64 = 0

    public var usedFraction: Double { totalBytes == 0 ? 0 : Double(usedBytes) / Double(totalBytes) }

    public init() {}
}

public struct VolumeInfo: Hashable, Sendable, Identifiable {
    public var id: String { mountPath }
    public var name: String
    public var mountPath: String
    public var totalBytes: UInt64
    public var freeBytes: UInt64
    public var isInternal: Bool
    public var isRoot: Bool

    public init(name: String, mountPath: String, totalBytes: UInt64, freeBytes: UInt64, isInternal: Bool, isRoot: Bool) {
        self.name = name
        self.mountPath = mountPath
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.isInternal = isInternal
        self.isRoot = isRoot
    }
}

/// What an SSD reports about itself: wear, lifetime reads and writes, and any warning it raises.
public struct DriveHealth: Hashable, Sendable, Identifiable {
    public var id: String
    /// e.g. "APPLE SSD AP1024Z"
    public var model: String
    public var isInternal: Bool
    /// The drive's own estimate of its rated life used, 0...255 (it can pass 100).
    public var percentageUsed: Int
    /// Spare blocks left for replacing worn ones, 0...100, and the level below which the drive warns.
    public var availableSparePercent: Int
    public var availableSpareThreshold: Int
    /// Raised for low spare blocks, overheating, degraded reliability or a drive gone read-only.
    public var hasCriticalWarning: Bool
    public var mediaErrors: UInt64
    public var bytesRead: UInt64
    public var bytesWritten: UInt64
    public var powerOnHours: UInt64
    public var powerCycles: UInt64
    public var unsafeShutdowns: UInt64

    public init(
        id: String, model: String, isInternal: Bool, percentageUsed: Int,
        availableSparePercent: Int, availableSpareThreshold: Int, hasCriticalWarning: Bool, mediaErrors: UInt64,
        bytesRead: UInt64, bytesWritten: UInt64, powerOnHours: UInt64, powerCycles: UInt64, unsafeShutdowns: UInt64
    ) {
        self.id = id
        self.model = model
        self.isInternal = isInternal
        self.percentageUsed = percentageUsed
        self.availableSparePercent = availableSparePercent
        self.availableSpareThreshold = availableSpareThreshold
        self.hasCriticalWarning = hasCriticalWarning
        self.mediaErrors = mediaErrors
        self.bytesRead = bytesRead
        self.bytesWritten = bytesWritten
        self.powerOnHours = powerOnHours
        self.powerCycles = powerCycles
        self.unsafeShutdowns = unsafeShutdowns
    }

    /// 0...100, rated life left.
    public var healthPercent: Double { Double(max(0, 100 - percentageUsed)) }

    /// A warning from the drive, data it could not recover, or wear past its rated life.
    public var needsAttention: Bool { hasCriticalWarning || mediaErrors > 0 || percentageUsed >= 100 }

    /// "Internal SSD", or the model for an external drive.
    public var name: String { isInternal ? "Internal SSD" : model }
}

public struct DiskStats: Hashable, Sendable {
    /// Startup volume capacity.
    public var totalBytes: UInt64 = 0
    /// Startup volume free space ("available for important usage", as Finder shows it).
    public var freeBytes: UInt64 = 0
    public var readBytesPerSecond: Double = 0
    public var writeBytesPerSecond: Double = 0
    public var volumes: [VolumeInfo] = []
    /// NVMe drives that report their health, internal first. Empty on Macs whose drives do not.
    public var drives: [DriveHealth] = []

    public var usedBytes: UInt64 { totalBytes > freeBytes ? totalBytes - freeBytes : 0 }

    public init() {}
}

public struct NetworkStats: Hashable, Sendable {
    public var downloadBytesPerSecond: Double = 0
    public var uploadBytesPerSecond: Double = 0
    /// BSD name of the primary interface, e.g. "en0".
    public var interfaceName: String = ""
    /// Human name of the primary interface, e.g. "Wi-Fi", "Ethernet".
    public var interfaceKind: String = ""
    public var isConnected: Bool = false
    /// Bytes moved since Tally started.
    public var sessionDownloadedBytes: UInt64 = 0
    public var sessionUploadedBytes: UInt64 = 0
    /// Each connected port (Ethernet, Wi-Fi, iPhone USB…) with its own throughput, the primary one first.
    public var connections: [NetworkConnection] = []

    public init() {}
}

/// One connected network port and the traffic through it.
public struct NetworkConnection: Hashable, Sendable, Identifiable {
    public var id: String { interfaceName }
    /// BSD name, e.g. "en8".
    public var interfaceName: String
    /// Human name, e.g. "Ethernet", "Wi-Fi", "iPhone USB".
    public var kind: String
    public var isWireless: Bool
    /// The connection macOS routes through by default.
    public var isPrimary: Bool = false
    public var downloadBytesPerSecond: Double = 0
    public var uploadBytesPerSecond: Double = 0
    /// Negotiated link rate; for Wi-Fi, the current transmit rate. Nil when the driver does not say.
    public var linkSpeedBitsPerSecond: Double?

    public init(interfaceName: String, kind: String, isWireless: Bool = false) {
        self.interfaceName = interfaceName
        self.kind = kind
        self.isWireless = isWireless
    }

    public var symbol: String {
        if isWireless { return Symbols.wifi }
        if kind.localizedCaseInsensitiveContains("iPhone") { return "iphone" }
        if kind.localizedCaseInsensitiveContains("iPad") { return "ipad" }
        return "cable.connector.horizontal"
    }

    /// "1 Gb/s", "2.5 Gb/s", "866 Mb/s", or nil when unknown.
    public var linkSpeedText: String? {
        guard let bitsPerSecond = linkSpeedBitsPerSecond, bitsPerSecond > 0 else { return nil }
        let gigabits = bitsPerSecond / 1_000_000_000
        if gigabits >= 1 {
            return String(format: abs(gigabits - gigabits.rounded()) < 0.05 ? "%.0f Gb/s" : "%.1f Gb/s", gigabits)
        }
        let megabits = bitsPerSecond / 1_000_000
        return String(format: megabits < 10 && abs(megabits - megabits.rounded()) >= 0.05 ? "%.1f Mb/s" : "%.0f Mb/s", megabits)
    }
}

public struct GPUStats: Hashable, Sendable {
    public var name: String = ""
    /// 0...100
    public var utilizationPercent: Double = 0
    public var memoryUsedBytes: UInt64 = 0

    public init() {}
}

public struct BatteryStats: Hashable, Sendable {
    public var hasBattery: Bool = false
    /// 0...100
    public var percent: Double = 0
    public var isCharging: Bool = false
    public var isPluggedIn: Bool = false
    /// Minutes to empty (on battery) or to full (charging); nil while macOS is still estimating.
    public var timeRemainingMinutes: Int?
    /// Watts drawn by the whole Mac (battery discharge rate, or adapter input when plugged in).
    public var powerDrawWatts: Double = 0
    /// 0...100, maximum capacity compared with design capacity.
    public var healthPercent: Double = 0
    public var cycleCount: Int = 0
    public var temperatureCelsius: Double = 0
    public var designCapacitymAh: Int = 0
    public var maxCapacitymAh: Int = 0
    public var adapterWatts: Int?

    public init() {}
}

public struct FanReading: Hashable, Sendable, Identifiable {
    public var id: Int
    public var name: String
    public var rpm: Double
    public var minRPM: Double
    public var maxRPM: Double

    public init(id: Int, name: String, rpm: Double, minRPM: Double, maxRPM: Double) {
        self.id = id
        self.name = name
        self.rpm = rpm
        self.minRPM = minRPM
        self.maxRPM = maxRPM
    }
}

public enum PeripheralKind: String, Hashable, Sendable {
    case headphones, mouse, keyboard, trackpad, gameController, other

    public var symbol: String {
        switch self {
        case .headphones: "airpods"
        case .mouse: "computermouse"
        case .keyboard: "keyboard"
        case .trackpad: "rectangle.and.hand.point.up.left"
        case .gameController: "gamecontroller"
        case .other: "dot.radiowaves.left.and.right"
        }
    }
}

public struct PeripheralBattery: Hashable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    /// 0...100
    public var percent: Double
    public var kind: PeripheralKind

    public init(name: String, percent: Double, kind: PeripheralKind) {
        self.name = name
        self.percent = percent
        self.kind = kind
    }
}

public struct TemperatureReading: Hashable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var celsius: Double

    public init(name: String, celsius: Double) {
        self.name = name
        self.celsius = celsius
    }
}

/// How warm a chip runs, in words.
public enum TemperatureRange: String, Hashable, Sendable {
    case normal, moderate, high

    /// The reading a full gauge or chart stands for.
    public static let scaleTop: Double = 110

    public init(celsius: Double) {
        self = celsius < 55 ? .normal : (celsius < 85 ? .moderate : .high)
    }

    public var label: String {
        switch self {
        case .normal: "Normal"
        case .moderate: "Moderate"
        case .high: "High"
        }
    }

    /// Where a reading sits on a gauge that runs from room temperature to `scaleTop`.
    public static func level(_ celsius: Double) -> Double {
        min(max((celsius - 20) / (scaleTop - 20), 0), 1)
    }
}

public struct SensorStats: Hashable, Sendable {
    public var cpuTemperatureCelsius: Double?
    public var gpuTemperatureCelsius: Double?
    /// Every sensor that could be read, for the detail list.
    public var temperatures: [TemperatureReading] = []
    public var fans: [FanReading] = []
    public var peripheralBatteries: [PeripheralBattery] = []

    public init() {}
}

public struct SystemSnapshot: Hashable, Sendable {
    public var date: Date = .distantPast
    public var cpu = CPUStats()
    public var memory = MemoryStats()
    public var disk = DiskStats()
    public var network = NetworkStats()
    public var gpu = GPUStats()
    public var battery = BatteryStats()
    public var sensors = SensorStats()
    public var uptime: TimeInterval = 0
    /// e.g. "MacBook Pro"
    public var machineName: String = ""

    public init() {}
}

// MARK: - Processes and apps

public struct ProcessSample: Hashable, Sendable, Identifiable {
    public var id: Int32 { pid }
    public var pid: Int32
    public var parentPid: Int32
    /// The process macOS holds responsible for this one (the app that launched it), if known.
    public var responsiblePid: Int32
    public var uid: UInt32
    public var name: String
    public var executablePath: String?
    /// Per-core percent, as Activity Monitor shows it: 100 is one full core.
    public var cpuPercent: Double = 0
    /// Physical footprint, the figure Activity Monitor calls Memory.
    public var memoryBytes: UInt64 = 0
    public var diskReadBytesPerSecond: Double = 0
    public var diskWriteBytesPerSecond: Double = 0
    public var networkInBytesPerSecond: Double = 0
    public var networkOutBytesPerSecond: Double = 0
    /// 0...100 share of the GPU.
    public var gpuPercent: Double = 0
    public var powerWatts: Double = 0
    public var threadCount: Int = 0
    public var startDate: Date?
    /// Total CPU seconds used since launch.
    public var cpuTimeSeconds: Double = 0
    /// True when the figures came from a limited source (a process owned by another user).
    public var isRestricted: Bool = false

    public init(pid: Int32, parentPid: Int32, responsiblePid: Int32, uid: UInt32, name: String, executablePath: String?) {
        self.pid = pid
        self.parentPid = parentPid
        self.responsiblePid = responsiblePid
        self.uid = uid
        self.name = name
        self.executablePath = executablePath
    }
}

public enum AppKind: String, Hashable, Sendable {
    /// A bundled .app.
    case app
    /// A command-line tool or daemon not inside an app bundle.
    case tool
    /// macOS system processes, grouped into one "macOS" row.
    case system
}

public struct AppUsage: Hashable, Sendable, Identifiable {
    /// Stable key: the bundle path for apps, "system" for macOS, the executable path for tools.
    public var id: String
    public var name: String
    public var kind: AppKind
    public var bundleIdentifier: String?
    public var bundlePath: String?
    public var processes: [ProcessSample]

    public var cpuPercent: Double = 0
    public var memoryBytes: UInt64 = 0
    public var diskReadBytesPerSecond: Double = 0
    public var diskWriteBytesPerSecond: Double = 0
    public var networkInBytesPerSecond: Double = 0
    public var networkOutBytesPerSecond: Double = 0
    public var gpuPercent: Double = 0
    public var powerWatts: Double = 0

    public var processCount: Int { processes.count }
    /// The pid of the main process (the app itself), used for Quit.
    public var mainPid: Int32?

    public init(id: String, name: String, kind: AppKind, bundleIdentifier: String?, bundlePath: String?, processes: [ProcessSample], mainPid: Int32?) {
        self.id = id
        self.name = name
        self.kind = kind
        self.bundleIdentifier = bundleIdentifier
        self.bundlePath = bundlePath
        self.processes = processes
        self.mainPid = mainPid
        recomputeTotals()
    }

    public mutating func recomputeTotals() {
        cpuPercent = processes.reduce(0) { $0 + $1.cpuPercent }
        memoryBytes = processes.reduce(0) { $0 + $1.memoryBytes }
        diskReadBytesPerSecond = processes.reduce(0) { $0 + $1.diskReadBytesPerSecond }
        diskWriteBytesPerSecond = processes.reduce(0) { $0 + $1.diskWriteBytesPerSecond }
        networkInBytesPerSecond = processes.reduce(0) { $0 + $1.networkInBytesPerSecond }
        networkOutBytesPerSecond = processes.reduce(0) { $0 + $1.networkOutBytesPerSecond }
        gpuPercent = processes.reduce(0) { $0 + $1.gpuPercent }
        powerWatts = processes.reduce(0) { $0 + $1.powerWatts }
    }

    /// The figure for a metric, used to sort and draw app lists.
    public func value(for metric: AppMetric) -> Double {
        switch metric {
        case .cpu: cpuPercent
        case .memory: Double(memoryBytes)
        case .diskRead: diskReadBytesPerSecond
        case .diskWrite: diskWriteBytesPerSecond
        case .disk: diskReadBytesPerSecond + diskWriteBytesPerSecond
        case .networkIn: networkInBytesPerSecond
        case .networkOut: networkOutBytesPerSecond
        case .network: networkInBytesPerSecond + networkOutBytesPerSecond
        case .gpu: gpuPercent
        case .power: powerWatts
        }
    }
}

public enum AppMetric: String, CaseIterable, Hashable, Sendable {
    case cpu, memory, diskRead, diskWrite, disk, networkIn, networkOut, network, gpu, power
}

public struct ProcessSnapshot: Sendable {
    public var processes: [ProcessSample]
    public var apps: [AppUsage]

    public init(processes: [ProcessSample], apps: [AppUsage]) {
        self.processes = processes
        self.apps = apps
    }
}

// MARK: - History

public enum HistoryMetric: String, CaseIterable, Hashable, Sendable {
    /// Percent of machine.
    case cpu
    /// Bytes used.
    case memory
    /// Percent.
    case gpu
    /// Bytes per second.
    case diskRead, diskWrite, networkIn, networkOut
    /// Percent.
    case battery
    /// Watts for the whole Mac.
    case power
    /// Celsius.
    case cpuTemperature
}

public enum HistoryRange: String, CaseIterable, Hashable, Sendable, Identifiable {
    case hours12, hours24, days7, days30

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .hours12: "12 h"
        case .hours24: "24 h"
        case .days7: "7 d"
        case .days30: "30 d"
        }
    }

    public var duration: TimeInterval {
        switch self {
        case .hours12: 12 * 3600
        case .hours24: 24 * 3600
        case .days7: 7 * 86400
        case .days30: 30 * 86400
        }
    }
}

public struct HistoryPoint: Hashable, Sendable {
    public var date: Date
    public var value: Double

    public init(date: Date, value: Double) {
        self.date = date
        self.value = value
    }
}

public struct HistoryAppTotal: Hashable, Sendable, Identifiable {
    public var id: String { appID }
    public var appID: String
    public var name: String
    public var bundlePath: String?
    /// Average for percent/bytes metrics, total bytes for rate metrics, average watts for power.
    public var value: Double

    public init(appID: String, name: String, bundlePath: String?, value: Double) {
        self.appID = appID
        self.name = name
        self.bundlePath = bundlePath
        self.value = value
    }
}

/// Totals the history store integrates over time, published to the UI.
public struct UsageTotals: Hashable, Sendable {
    public var networkInToday: UInt64 = 0
    public var networkOutToday: UInt64 = 0
    public var networkInLast7Days: UInt64 = 0
    public var networkInLast30Days: UInt64 = 0
    public var diskWrittenToday: UInt64 = 0
    /// 0...100
    public var cpuAverageToday: Double = 0
    public var gpuAverageToday: Double = 0
    public var gpuPeakToday: Double = 0

    public init() {}
}

/// A calendar year of history summed up, for Tally Wrapped.
public struct YearSummary: Hashable, Sendable {
    public var year: Int
    /// The first and last moments with history in the year.
    public var firstDate: Date
    public var lastDate: Date
    /// Seconds Tally was sampling: the Mac awake with Tally running.
    public var activeSeconds: Double = 0
    public var activeDays = 0
    /// Hours sampled in each month, January first.
    public var monthlyHours = [Double](repeating: 0, count: 12)
    /// 0...100
    public var cpuAverage: Double = 0
    /// The day with the highest average CPU, and that average.
    public var busiestDay: Date?
    public var busiestDayCPU: Double = 0
    /// The hour of the day, 0...23, with the highest average CPU.
    public var busiestHour: Int?
    public var hottestCelsius: Double?
    public var networkInBytes: UInt64 = 0
    public var networkOutBytes: UInt64 = 0
    public var diskWrittenBytes: UInt64 = 0
    /// Apps and tools with history in the year, not counting macOS itself.
    public var appCount = 0
    /// The apps with the most CPU time, in seconds of one core.
    public var topByCPU: [HistoryAppTotal] = []
    /// The app that held the most memory on average, in bytes.
    public var topByMemory: HistoryAppTotal?
    /// The app that moved the most data, in bytes down and up.
    public var topByNetwork: HistoryAppTotal?
    /// The app that used the most energy, in watt-hours.
    public var topByEnergy: HistoryAppTotal?

    public init(year: Int, firstDate: Date, lastDate: Date) {
        self.year = year
        self.firstDate = firstDate
        self.lastDate = lastDate
    }
}

// MARK: - Alerts

public enum AlertKind: String, Hashable, Sendable, Codable {
    case highCPU, growingMemory, heavyDisk, heavyNetwork

    public var symbol: String {
        switch self {
        case .highCPU: "cpu"
        case .growingMemory: "memorychip"
        case .heavyDisk: "internaldrive"
        case .heavyNetwork: "globe"
        }
    }
}

public struct AlertItem: Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: AlertKind
    public var appID: String
    public var appName: String
    public var bundlePath: String?
    /// e.g. "Google Chrome is using a lot of CPU"
    public var title: String
    /// e.g. "Averaged 70% over the last 10 minutes."
    public var detail: String
    public var date: Date

    public init(id: String, kind: AlertKind, appID: String, appName: String, bundlePath: String?, title: String, detail: String, date: Date) {
        self.id = id
        self.kind = kind
        self.appID = appID
        self.appName = appName
        self.bundlePath = bundlePath
        self.title = title
        self.detail = detail
        self.date = date
    }
}

// MARK: - Projects

public enum DevServerKind: String, Hashable, Sendable {
    case node, bun, deno, python, ruby, go, rust, java, php, elixir, dotnet, docker, other

    public var label: String { rawValue }
}

public enum DevActivity: Hashable, Sendable {
    /// Used CPU recently.
    case working
    /// No meaningful CPU for this long, while running for less than a day.
    case idle(since: Date)
    /// Up for a day or more with almost no CPU in that time.
    case barelyUsed(upSince: Date)
}

public struct DevProcess: Hashable, Sendable, Identifiable {
    public var id: Int32 { pid }
    public var pid: Int32
    public var name: String
    public var kind: DevServerKind
    public var commandLine: String
    public var ports: [Int]
    public var memoryBytes: UInt64
    public var cpuPercent: Double
    public var startDate: Date?
    public var lastActiveDate: Date?
    public var activity: DevActivity

    public init(pid: Int32, name: String, kind: DevServerKind, commandLine: String, ports: [Int], memoryBytes: UInt64, cpuPercent: Double, startDate: Date?, lastActiveDate: Date?, activity: DevActivity) {
        self.pid = pid
        self.name = name
        self.kind = kind
        self.commandLine = commandLine
        self.ports = ports
        self.memoryBytes = memoryBytes
        self.cpuPercent = cpuPercent
        self.startDate = startDate
        self.lastActiveDate = lastActiveDate
        self.activity = activity
    }

    public var isIdle: Bool {
        if case .working = activity { return false }
        return true
    }
}

public struct Project: Hashable, Sendable, Identifiable {
    /// The project folder path.
    public var id: String { path }
    public var name: String
    public var path: String
    public var processes: [DevProcess]

    public init(name: String, path: String, processes: [DevProcess]) {
        self.name = name
        self.path = path
        self.processes = processes
    }

    public var memoryBytes: UInt64 { processes.reduce(0) { $0 + $1.memoryBytes } }
    public var ports: [Int] { processes.flatMap(\.ports).sorted() }
    public var isWorking: Bool { processes.contains { !$0.isIdle } }
    /// A project counts as an idle dev server when it listens on a port and every process in it is idle.
    public var isIdleServer: Bool { !ports.isEmpty && !isWorking }
}
