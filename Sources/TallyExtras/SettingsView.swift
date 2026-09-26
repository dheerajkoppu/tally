import SwiftUI
import TallyCore

/// The panes of the Settings window.
public enum SettingsPane: String, CaseIterable, Identifiable, Sendable {
    case general, menuBar, alerts, history, about

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .general: "General"
        case .menuBar: "Menu Bar"
        case .alerts: "Alerts"
        case .history: "History"
        case .about: "About"
        }
    }

    /// The SF Symbol shown above the title in the Settings toolbar.
    public var symbol: String {
        switch self {
        case .general: "gearshape"
        case .menuBar: "menubar.rectangle"
        case .alerts: "bell.badge"
        case .history: "clock.arrow.circlepath"
        case .about: "info.circle"
        }
    }

    static let storageKey = "settingsPane"

    /// The pane shown last, so Settings reopens where it was left.
    public static var stored: SettingsPane {
        get { SettingsPane(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .general }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: storageKey) }
    }
}

/// One pane of Settings: a grouped form at its natural height.
public struct SettingsPaneView: View {
    private let pane: SettingsPane

    public init(_ pane: SettingsPane) {
        self.pane = pane
    }

    public var body: some View {
        switch pane {
        case .general: GeneralSettingsPane()
        case .menuBar: MenuBarSettingsPane()
        case .alerts: AlertSettingsPane()
        case .history: HistorySettingsPane()
        case .about: AboutSettingsPane()
        }
    }
}

/// Every pane behind a segmented picker, for hosts without the Settings window's toolbar.
/// The app itself uses `SettingsTabViewController`.
public struct SettingsView: View {
    @State private var pane: SettingsPane

    public init() {
        _pane = State(initialValue: SettingsPane.stored)
    }

    public init(pane: SettingsPane) {
        _pane = State(initialValue: pane)
    }

    public var body: some View {
        VStack(spacing: 0) {
            Picker("Settings", selection: $pane) {
                ForEach(SettingsPane.allCases) { pane in
                    Text(pane.title).tag(pane)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.top, 14)
            SettingsPaneView(pane)
        }
        .frame(width: SettingsLayout.width)
        .onChange(of: pane) { _, newValue in
            SettingsPane.stored = newValue
        }
    }
}

enum SettingsLayout {
    static let width: CGFloat = 520
}

/// Why one of the Dock icon and the menu bar item always stays on.
enum AppPresenceNote {
    static let text = "The Dock icon or the menu bar item always stays on so you can reach Tally. Turning one off while the other is off turns the other back on."
}

/// Secondary text under a settings section, aligned with the rows.
struct SettingsFootnote: View {
    private let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension View {
    /// A grouped form that takes its content's height, so the Settings window can fit each pane.
    func settingsPaneLayout() -> some View {
        formStyle(.grouped)
            .scrollDisabled(true)
            .frame(width: SettingsLayout.width)
            .fixedSize(horizontal: false, vertical: true)
    }
}
