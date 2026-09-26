import SwiftUI
import ServiceManagement
import TallyCore

/// Launch at login through `SMAppService`, with its status read and changed off the main thread.
@MainActor
final class LoginItemModel: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var needsApproval = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var isWorking = false

    init() {
        refresh()
    }

    func refresh() {
        Task.detached(priority: .userInitiated) {
            let status = SMAppService.mainApp.status
            await MainActor.run { self.apply(status) }
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        isEnabled = enabled
        Task.detached(priority: .userInitiated) {
            let message: String?
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try await SMAppService.mainApp.unregister()
                }
                message = nil
            } catch {
                message = Self.describe(error, enabling: enabled)
            }
            let status = SMAppService.mainApp.status
            await MainActor.run {
                self.isWorking = false
                self.errorMessage = message
                self.apply(status)
            }
        }
    }

    private func apply(_ status: SMAppService.Status) {
        isEnabled = status == .enabled || status == .requiresApproval
        needsApproval = status == .requiresApproval
    }

    nonisolated private static func describe(_ error: Error, enabling: Bool) -> String {
        if !Bundle.main.bundlePath.hasSuffix(".app") {
            return "Launch at login works when Tally runs from its app bundle."
        }
        let verb = enabling ? "turn on" : "turn off"
        return "macOS did not let Tally \(verb) launch at login. \(error.localizedDescription)"
    }
}

public struct GeneralSettingsPane: View {
    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var loginItem = LoginItemModel()

    public init() {}

    public var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.setEnabled($0) })) {
                    Text("Launch at Login")
                    Text("Starts Tally when you log in.")
                }
                .disabled(loginItem.isWorking)
                if let message = loginItem.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.secondary)
                } else if loginItem.needsApproval {
                    LabeledContent {
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    } label: {
                        Text("Waiting for Approval")
                        Text("Allow Tally in System Settings, under Login Items.")
                    }
                }
                Toggle(isOn: $settings.showInDock) {
                    Text("Show in Dock")
                    Text("Keeps an icon in the Dock and the app switcher.")
                }
                Toggle(isOn: $settings.showInMenuBar) {
                    Text("Show in Menu Bar")
                    Text("Keeps the Tally item and its panel in the menu bar.")
                }
            } footer: {
                SettingsFootnote(AppPresenceNote.text)
            }

            Section {
                Picker(selection: $settings.updateInterval) {
                    ForEach(AppSettings.updateIntervalChoices, id: \.self) { seconds in
                        Text(Self.intervalLabel(seconds)).tag(seconds)
                    }
                } label: {
                    Text("Update Every")
                    Text("How often Tally refreshes while a window or the menu bar panel is open. Slower uses less energy.")
                }
                Picker(selection: $settings.temperatureUnit) {
                    Text("Celsius (°C)").tag(TemperatureUnit.celsius)
                    Text("Fahrenheit (°F)").tag(TemperatureUnit.fahrenheit)
                } label: {
                    Text("Temperature")
                    Text("Used for the CPU, GPU and battery temperatures.")
                }
            }

            Section {
                LabeledContent {
                    OwnUsageFigures()
                } label: {
                    Text("Tally Itself")
                    Text(cadence)
                }
            }
        }
        .settingsPaneLayout()
    }

    /// The real sampling cadence, matching `SamplingEngine`.
    private var cadence: String {
        let visible = settings.updateInterval
        // With the plain icon the menu bar shows no figures, so the engine checks the Mac only as often as the apps.
        let apps = max(visible, SamplingEngine.minimumBackgroundInterval, 15)
        let background = settings.menuBarStyle == .icon ? apps : max(visible, SamplingEngine.minimumBackgroundInterval)
        return "Refreshes \(Self.every(visible)) while a window or the menu bar panel is open. In the background it checks your Mac \(Self.every(background)) and your apps \(Self.every(apps))."
    }

    static func intervalLabel(_ seconds: Double) -> String {
        seconds == 1 ? "1 second" : "\(Int(seconds)) seconds"
    }

    private static func every(_ seconds: Double) -> String {
        seconds == 1 ? "every second" : "every \(Int(seconds)) seconds"
    }
}

/// Tally' own CPU and memory. The only part of the pane that follows each sample.
private struct OwnUsageFigures: View {
    @ObservedObject private var store = TallyStore.shared
    private static let pid = ProcessInfo.processInfo.processIdentifier

    var body: some View {
        if let own = store.processes.first(where: { $0.pid == Self.pid }) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(Format.precisePercent(own.cpuPercent))
                    .font(.body.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.primary)
                Text(Format.memory(own.memoryBytes).text)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Tally uses \(Format.precisePercent(own.cpuPercent)) CPU and \(Format.memory(own.memoryBytes).text) of memory")
        }
    }
}
