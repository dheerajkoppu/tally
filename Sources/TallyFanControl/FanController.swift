import Foundation
import AppKit
import Combine
import TallyCore

/// Fan control for the UI. Live speeds come from `TallyStore`; this object only tracks what the user forced.
/// It costs nothing while every fan is automatic: no connection, no timers, no polling.
@MainActor
public final class FanController: ObservableObject {
    public static let shared = FanController()

    public enum HelperState: Equatable {
        case checking, notInstalled, installed, needsUpdate, unreachable
    }

    public enum Mode: String, CaseIterable, Identifiable {
        case automatic, manual

        public var id: String { rawValue }
        public var title: String { self == .automatic ? "Automatic" : "Manual" }
    }

    public enum Preset: String, CaseIterable, Identifiable {
        case automatic, quiet, balanced, max

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .automatic: "Automatic"
            case .quiet: "Quiet"
            case .balanced: "Balanced"
            case .max: "Max"
            }
        }

        public var help: String {
            switch self {
            case .automatic: "Let macOS choose every fan speed"
            case .quiet: "Run every fan at its lowest speed"
            case .balanced: "Run every fan at half of its range"
            case .max: "Run every fan at full speed"
            }
        }

        /// The share of each fan's range, or nil for automatic.
        var fraction: Double? {
            switch self {
            case .automatic: nil
            case .quiet: 0
            case .balanced: 0.5
            case .max: 1
            }
        }
    }

    @Published public private(set) var helperState: HelperState = .checking
    @Published public private(set) var modes: [Int: Mode] = [:]
    @Published public private(set) var targets: [Int: Double] = [:]
    /// Fans in manual mode that Tally did not force, such as ones another fan app controls.
    @Published public private(set) var externallyControlled: Set<Int> = []
    /// Fans as the helper reports them, used when the sensor reader has none.
    @Published public private(set) var helperFans: [FanReading] = []
    @Published public private(set) var isInstalling = false
    @Published public private(set) var isDryRun = false
    @Published public private(set) var errorMessage: String?

    /// Fan apps that also write to the SMC, found once.
    public private(set) lazy var otherFanApps: [String] = Self.findOtherFanApps()

    private static let minimumWriteSpacing: TimeInterval = 0.25

    private let link = FanHelperLink()
    private var pendingTargets: [Int: Double] = [:]
    private var isFlushScheduled = false
    private var lastFlush = Date.distantPast
    private var latestRequest = 0

    private init() {
        link.onConnectionLost = { [weak self] in self?.connectionLost() }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [link] _ in
            link.restoreAutomaticAndClose()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.returnToAutomaticForSleep() }
        }
    }

    /// A Mac asleep in a bag should not keep its fans pinned, so sleep hands every fan back to macOS before it starts.
    private func returnToAutomaticForSleep() {
        guard hasManualFans || !pendingTargets.isEmpty else { return }
        latestRequest += 1
        pendingTargets.removeAll()
        modes.removeAll()
        link.restoreAutomaticAndClose()
    }

    public var hasManualFans: Bool { modes.values.contains(.manual) }
    public var canControl: Bool { helperState == .installed }

    public func mode(for fan: Int) -> Mode { modes[fan] ?? .automatic }

    /// The speed the slider shows: the forced target in manual mode, the live speed otherwise.
    public func target(for fan: FanReading) -> Double {
        let value = mode(for: fan.id) == .manual ? targets[fan.id] ?? fan.rpm : fan.rpm
        return Self.clamp(value, fan)
    }

    /// Checks the helper once, for example when the fan popover opens.
    public func refresh() {
        guard !isInstalling else { return }
        if FanHelperLocation.testSocketPath == nil, !FanHelperLocation.isInstalled {
            helperState = .notInstalled
            return
        }
        request(["command": "status"], updatesState: true)
    }

    public func setManual(_ fan: Int, rpm: Double) {
        guard canControl else { return }
        modes[fan] = .manual
        targets[fan] = rpm.rounded()
        pendingTargets[fan] = rpm.rounded()
        scheduleFlush()
    }

    public func setAuto(_ fan: Int) {
        guard canControl else { return }
        modes[fan] = .automatic
        pendingTargets[fan] = nil
        request(["command": "setAuto", "fan": fan])
    }

    public func setAllAuto() {
        guard canControl else { return }
        for fan in modes.keys { modes[fan] = .automatic }
        pendingTargets.removeAll()
        request(["command": "setAllAuto"])
    }

    public func apply(_ preset: Preset, to fans: [FanReading]) {
        guard let fraction = preset.fraction else {
            setAllAuto()
            return
        }
        for fan in fans where fan.maxRPM > fan.minRPM {
            setManual(fan.id, rpm: fan.minRPM + (fan.maxRPM - fan.minRPM) * fraction)
        }
    }

    /// The preset every fan currently matches, if any.
    public func activePreset(for fans: [FanReading]) -> Preset? {
        guard !fans.isEmpty else { return nil }
        if fans.allSatisfy({ mode(for: $0.id) == .automatic }) { return .automatic }
        return Preset.allCases.first { preset in
            guard let fraction = preset.fraction else { return false }
            return fans.allSatisfy { fan in
                mode(for: fan.id) == .manual && abs((targets[fan.id] ?? 0) - (fan.minRPM + (fan.maxRPM - fan.minRPM) * fraction)) < 1
            }
        }
    }

    public func install() {
        guard !isInstalling else { return }
        isInstalling = true
        errorMessage = nil
        FanHelperInstaller.install { [weak self] outcome in
            guard let self else { return }
            isInstalling = false
            switch outcome {
            case .done:
                helperState = .checking
                request(["command": "status"], updatesState: true)
            case .cancelled:
                break
            case .failed(let message):
                errorMessage = message
            }
        }
    }

    public func uninstall() {
        guard !isInstalling else { return }
        if hasManualFans { setAllAuto() }
        isInstalling = true
        errorMessage = nil
        FanHelperInstaller.uninstall { [weak self] outcome in
            guard let self else { return }
            isInstalling = false
            switch outcome {
            case .done:
                helperState = .notInstalled
                modes.removeAll()
            case .cancelled:
                refresh()
            case .failed(let message):
                errorMessage = message
                refresh()
            }
        }
    }

    /// Sends slider moves at most four times a second, always ending on the latest value.
    private func scheduleFlush() {
        guard !isFlushScheduled else { return }
        isFlushScheduled = true
        let wait = max(0, Self.minimumWriteSpacing - Date().timeIntervalSince(lastFlush))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.flush() }
    }

    private func flush() {
        isFlushScheduled = false
        lastFlush = Date()
        let writes = pendingTargets.sorted { $0.key < $1.key }
        pendingTargets.removeAll()
        for (fan, rpm) in writes {
            request(["command": "setManual", "fan": fan, "rpm": rpm])
        }
    }

    private func request(_ body: [String: Any], updatesState: Bool = false) {
        latestRequest += 1
        let number = latestRequest
        link.send(body) { [weak self] result in
            self?.handle(result, request: number, updatesState: updatesState)
        }
    }

    private func handle(_ result: Result<HelperStatus, HelperFailure>, request number: Int, updatesState: Bool) {
        switch result {
        case .success(let status):
            errorMessage = nil
            helperState = status.version == FanHelperLocation.expectedVersion ? .installed : .needsUpdate
            isDryRun = status.isDryRun
            helperFans = status.fans.enumerated().map { index, fan in
                FanReading(id: fan.id, name: status.fans.count == 1 ? "Fan" : "Fan \(index + 1)", rpm: fan.rpm, minRPM: fan.minimum, maxRPM: fan.maximum)
            }
            externallyControlled = Set(status.fans.filter { $0.isManual && !$0.isForcedByHelper }.map(\.id))
            guard number == latestRequest, pendingTargets.isEmpty, !isFlushScheduled else { return }
            for fan in status.fans {
                modes[fan.id] = fan.isForcedByHelper ? .manual : .automatic
                if fan.isForcedByHelper, targets[fan.id] == nil { targets[fan.id] = fan.target }
            }
        case .failure(.unreachable):
            helperState = FanHelperLocation.testSocketPath == nil && !FanHelperLocation.isInstalled ? .notInstalled : .unreachable
            modes.removeAll()
        case .failure(.refused(let message)):
            if message.contains("may not control") {
                helperState = .needsUpdate
                modes.removeAll()
            } else {
                errorMessage = message
                if !updatesState { refresh() }
            }
        case .failure(.broken):
            errorMessage = "Lost touch with the fan helper."
            modes.removeAll()
            if updatesState {
                helperState = .unreachable
            } else {
                refresh()
            }
        }
    }

    private func connectionLost() {
        modes.removeAll()
        pendingTargets.removeAll()
    }

    private static func clamp(_ value: Double, _ fan: FanReading) -> Double {
        guard fan.maxRPM > fan.minRPM else { return value }
        return min(max(value, fan.minRPM), fan.maxRPM)
    }

    private static func findOtherFanApps() -> [String] {
        let known = [
            "com.crystalidea.macsfancontrol": "Macs Fan Control",
            "com.tunabellysoftware.tgpro": "TG Pro",
            "com.eidac.smcFanControl2": "smcFanControl",
            "eu.exelban.Stats": "Stats",
        ]
        return known.compactMap { identifier, name in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) == nil ? nil : name
        }.sorted()
    }
}
