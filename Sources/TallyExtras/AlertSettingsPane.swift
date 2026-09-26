import SwiftUI
import UserNotifications
import TallyCore

public struct AlertSettingsPane: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var testState: TestNotificationState = .idle

    private static let cpuPercents: [Double] = [30, 40, 50, 60, 70, 80, 90, 100, 150, 200, 300, 400]
    private static let cpuMinutes: [Double] = [1, 2, 3, 5, 10, 15, 20, 30, 45, 60]
    private static let memoryGrowth: [Double] = [0.5, 1, 1.5, 2, 3, 4, 6, 8, 12, 16]
    private static let diskRates: [Double] = [10, 20, 30, 50, 75, 100, 150, 200, 300, 500]
    private static let networkRates: [Double] = [1, 2, 5, 10, 20, 30, 50, 100, 200]

    public init() {}

    public var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.alertsEnabled) {
                    Text("Alerts for Misbehaving Apps")
                    Text("Get notified when an app stays busy on the CPU, grows steadily in memory, or moves a lot of data on disk or the network.")
                }
            }

            Section {
                choicePicker(Self.cpuPercents, selection: $settings.cpuAlertPercent, format: { "\(Int($0))%" }) {
                    Text("Keeps the CPU Busy")
                    Text(cpuDescription)
                }
                choicePicker(Self.cpuMinutes, selection: $settings.cpuAlertMinutes, format: minutes) {
                    Text("Averaged Over")
                }
                choicePicker(Self.memoryGrowth, selection: $settings.memoryGrowthAlertGB, format: gigabytes) {
                    Text("Keeps Growing in Memory")
                    Text("Grows by more than \(gigabytes(settings.memoryGrowthAlertGB)) within 30 minutes.")
                }
                choicePicker(Self.diskRates, selection: $settings.diskAlertMBps, format: { "\(Int($0)) MB/s" }) {
                    Text("Hammers the Disk")
                    Text("Writes more than \(Int(settings.diskAlertMBps)) MB/s for 5 minutes.")
                }
                choicePicker(Self.networkRates, selection: $settings.networkAlertMBps, format: { "\(Int($0)) MB/s" }) {
                    Text("Hammers the Network")
                    Text("Moves more than \(Int(settings.networkAlertMBps)) MB/s for 5 minutes.")
                }
            } header: {
                Text("When an App")
            }
            .disabled(!settings.alertsEnabled)

            Section {
                LabeledContent {
                    Button("Send Test Notification") { sendTestNotification() }
                        .disabled(!canNotify || testState == .sending)
                } label: {
                    Text("Test")
                    testStatus
                }
            }
        }
        .settingsPaneLayout()
    }

    /// A menu of fixed choices that still shows a stored value that is not one of them.
    private func choicePicker<Label: View>(_ choices: [Double], selection: Binding<Double>, format: @escaping (Double) -> String, @ViewBuilder label: () -> Label) -> some View {
        let values = choices.contains(selection.wrappedValue) ? choices : (choices + [selection.wrappedValue]).sorted()
        return Picker(selection: selection) {
            ForEach(values, id: \.self) { value in
                Text(format(value)).tag(value)
            }
        } label: {
            label()
        }
    }

    private var cpuDescription: String {
        let percent = settings.cpuAlertPercent
        let share = percent < 100
            ? "\(Int(percent))% of one core"
            : (percent == 100 ? "one full core" : "\(String(format: "%g", percent / 100)) cores")
        return "Uses more than \(share) on average for \(minutes(settings.cpuAlertMinutes))."
    }

    private func minutes(_ value: Double) -> String {
        value == 1 ? "1 minute" : "\(Int(value)) minutes"
    }

    private func gigabytes(_ value: Double) -> String {
        "\(String(format: "%g", value)) GB"
    }

    private var canNotify: Bool { Bundle.main.bundleIdentifier != nil }

    private var testStatus: Text {
        switch testState {
        case .idle where !canNotify: Text("Notifications work when Tally runs from its app bundle.")
        case .idle, .sending: Text("Alerts appear as macOS notifications.")
        case .sent: Text("Sent. It should appear in a moment.")
        case .denied: Text("Notifications are off for Tally in System Settings.")
        case .failed(let message): Text(message)
        }
    }

    private func sendTestNotification() {
        guard canNotify else { return }
        testState = .sending
        let percent = Int(settings.cpuAlertPercent)
        let duration = minutes(settings.cpuAlertMinutes)
        Task {
            let center = UNUserNotificationCenter.current()
            var status = await center.notificationSettings().authorizationStatus
            if status == .notDetermined {
                let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
                status = granted ? .authorized : .denied
            }
            guard status != .denied else {
                testState = .denied
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "This is how Tally alerts look"
            content.body = "You will see one when an app uses more than \(percent)% of a core for \(duration), grows steadily in memory, or moves a lot of data on disk or the network."
            content.sound = .default
            let request = UNNotificationRequest(identifier: "tally.test.\(UUID().uuidString)", content: content, trigger: nil)
            do {
                try await center.add(request)
                testState = .sent
            } catch {
                testState = .failed(error.localizedDescription)
            }
        }
    }
}

private enum TestNotificationState: Equatable {
    case idle, sending, sent, denied
    case failed(String)
}
