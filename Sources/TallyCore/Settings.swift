import Foundation
import Combine

public enum MenuBarStyle: String, CaseIterable, Identifiable, Sendable {
    case icon, figure, graph, stacked

    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }
}

public enum MenuBarMetric: String, CaseIterable, Identifiable, Sendable {
    case cpu, memory, gpu, network, temperature, battery

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .gpu: "GPU"
        case .network: "Network"
        case .temperature: "Temperature"
        case .battery: "Battery"
        }
    }

    /// The short caption used in the stacked menu bar style.
    public var shortLabel: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "MEM"
        case .gpu: "GPU"
        case .network: "NET"
        case .temperature: "TEMP"
        case .battery: "BAT"
        }
    }
}

public enum TemperatureUnit: String, CaseIterable, Identifiable, Sendable {
    case celsius, fahrenheit

    public var id: String { rawValue }
}

/// User preferences, persisted in UserDefaults.
@MainActor
public final class AppSettings: ObservableObject {
    public static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    @Published public var menuBarStyle: MenuBarStyle { didSet { defaults.set(menuBarStyle.rawValue, forKey: "menuBarStyle") } }
    /// The figure and graph styles use the first metric; stacked shows up to three.
    @Published public var menuBarMetrics: [MenuBarMetric] { didSet { defaults.set(menuBarMetrics.map(\.rawValue), forKey: "menuBarMetrics") } }
    /// Turn the menu bar item into a warning sign when the Mac is under strain.
    @Published public var menuBarWarnings: Bool { didSet { defaults.set(menuBarWarnings, forKey: "menuBarWarnings") } }
    /// Show memory in the menu bar as the amount in use, "12.3 GB", instead of a percentage.
    @Published public var menuBarMemoryInGB: Bool { didSet { defaults.set(menuBarMemoryInGB, forKey: "menuBarMemoryInGB") } }
    /// Turning off the Dock icon while the menu bar item is hidden brings the menu bar item back, so Tally stays reachable.
    @Published public var showInDock: Bool {
        didSet {
            defaults.set(showInDock, forKey: "showInDock")
            if !showInDock, !showInMenuBar { showInMenuBar = true }
        }
    }
    /// Keep the Tally item in the menu bar. Hiding it while the Dock icon is off turns the Dock icon back on.
    @Published public var showInMenuBar: Bool {
        didSet {
            defaults.set(showInMenuBar, forKey: "showInMenuBar")
            if !showInMenuBar, !showInDock { showInDock = true }
        }
    }
    /// Start without a window, and keep the Dock icon and menus away while no Tally window is open.
    @Published public var opensInBackground: Bool { didSet { defaults.set(opensInBackground, forKey: "opensInBackground") } }
    @Published public var temperatureUnit: TemperatureUnit { didSet { defaults.set(temperatureUnit.rawValue, forKey: "temperatureUnit") } }

    @Published public var alertsEnabled: Bool { didSet { defaults.set(alertsEnabled, forKey: "alertsEnabled") } }
    /// Per-core percent an app must average over `cpuAlertMinutes` to trigger an alert.
    @Published public var cpuAlertPercent: Double { didSet { defaults.set(cpuAlertPercent, forKey: "cpuAlertPercent") } }
    @Published public var cpuAlertMinutes: Double { didSet { defaults.set(cpuAlertMinutes, forKey: "cpuAlertMinutes") } }
    /// Growth in GB within 30 minutes that counts as a growing memory footprint.
    @Published public var memoryGrowthAlertGB: Double { didSet { defaults.set(memoryGrowthAlertGB, forKey: "memoryGrowthAlertGB") } }
    /// Sustained MB/s written to disk over 5 minutes.
    @Published public var diskAlertMBps: Double { didSet { defaults.set(diskAlertMBps, forKey: "diskAlertMBps") } }
    /// Sustained MB/s over the network over 5 minutes.
    @Published public var networkAlertMBps: Double { didSet { defaults.set(networkAlertMBps, forKey: "networkAlertMBps") } }

    @Published public var hasCompletedWelcome: Bool { didSet { defaults.set(hasCompletedWelcome, forKey: "hasCompletedWelcome") } }
    /// Seconds between samples while a window or the menu bar panel is open. One of `updateIntervalChoices`.
    @Published public var updateInterval: Double { didSet { defaults.set(updateInterval, forKey: "updateInterval") } }

    public static let updateIntervalChoices: [Double] = [1, 2, 5, 10]

    private init() {
        let defaults = UserDefaults.standard
        menuBarStyle = MenuBarStyle(rawValue: defaults.string(forKey: "menuBarStyle") ?? "") ?? .figure
        let storedMetrics = (defaults.stringArray(forKey: "menuBarMetrics") ?? []).compactMap(MenuBarMetric.init(rawValue:))
        menuBarMetrics = storedMetrics.isEmpty ? [.cpu, .memory] : storedMetrics
        menuBarWarnings = defaults.object(forKey: "menuBarWarnings") as? Bool ?? true
        menuBarMemoryInGB = defaults.bool(forKey: "menuBarMemoryInGB")
        let storedShowInDock = defaults.object(forKey: "showInDock") as? Bool ?? true
        showInDock = storedShowInDock
        showInMenuBar = (defaults.object(forKey: "showInMenuBar") as? Bool ?? true) || !storedShowInDock
        opensInBackground = defaults.bool(forKey: "opensInBackground")
        temperatureUnit = TemperatureUnit(rawValue: defaults.string(forKey: "temperatureUnit") ?? "") ?? .celsius
        alertsEnabled = defaults.object(forKey: "alertsEnabled") as? Bool ?? true
        cpuAlertPercent = defaults.object(forKey: "cpuAlertPercent") as? Double ?? 70
        cpuAlertMinutes = defaults.object(forKey: "cpuAlertMinutes") as? Double ?? 10
        memoryGrowthAlertGB = defaults.object(forKey: "memoryGrowthAlertGB") as? Double ?? 2
        diskAlertMBps = defaults.object(forKey: "diskAlertMBps") as? Double ?? 50
        networkAlertMBps = defaults.object(forKey: "networkAlertMBps") as? Double ?? 10
        hasCompletedWelcome = defaults.bool(forKey: "hasCompletedWelcome")
        updateInterval = defaults.object(forKey: "updateInterval") as? Double ?? 5
    }

    /// Thread-safe read of the alert settings for the background alert engine.
    public nonisolated static func alertThresholds() -> AlertThresholds {
        let defaults = UserDefaults.standard
        return AlertThresholds(
            enabled: defaults.object(forKey: "alertsEnabled") as? Bool ?? true,
            cpuPercent: defaults.object(forKey: "cpuAlertPercent") as? Double ?? 70,
            cpuMinutes: defaults.object(forKey: "cpuAlertMinutes") as? Double ?? 10,
            memoryGrowthGB: defaults.object(forKey: "memoryGrowthAlertGB") as? Double ?? 2,
            diskMBps: defaults.object(forKey: "diskAlertMBps") as? Double ?? 50,
            networkMBps: defaults.object(forKey: "networkAlertMBps") as? Double ?? 10
        )
    }
}

public struct AlertThresholds: Sendable {
    public var enabled: Bool
    public var cpuPercent: Double
    public var cpuMinutes: Double
    public var memoryGrowthGB: Double
    public var diskMBps: Double
    public var networkMBps: Double
}
