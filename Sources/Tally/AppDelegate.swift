import AppKit
import SwiftUI
import Combine
import TallyCore
import TallySystem
import TallyProcesses
import TallySensors
import TallyHistory
import TallyProjects
import TallyMenuBar
import TallyExtras

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var engine: SamplingEngine?
    private var statusItemController: StatusItemController?
    private let windows = WindowManager()
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = AppSettings.shared
        windows.updateActivationPolicy()
        NSApp.mainMenu = MainMenu.build()

        let store = TallyStore.shared
        let historyDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tally", isDirectory: true)
        let history = HistoryStore(directory: historyDirectory)
        let alerts = AlertEngine()
        store.history = history
        store.alertEvaluator = alerts

        let engine = SamplingEngine(
            store: store,
            system: SystemSampler(),
            processes: ProcessSampler(),
            sensors: SensorReader(),
            history: history,
            alerts: alerts,
            projects: ProjectScanner()
        )
        self.engine = engine
        windows.engine = engine

        let router = AppRouter.shared
        router.engine = engine
        router.showMainWindow = { [weak self] in self?.windows.showMain() }
        router.showSettings = { [weak self] in self?.windows.showSettings() }

        engine.setUpdateInterval(settings.updateInterval)
        engine.start()
        if RenderHarness.isRequested {
            NSApp.setActivationPolicy(.accessory)
            RenderHarness.run(engine: engine)
            return
        }
        AlertEngine.requestAuthorization()
        statusItemController = StatusItemController()

        settings.$updateInterval
            .dropFirst()
            .sink { interval in engine.setUpdateInterval(interval) }
            .store(in: &cancellables)

        // Published values change after their publisher fires, so the policy is worked out on the next turn.
        Publishers.Merge3(settings.$showInDock.dropFirst(), settings.$showInMenuBar.dropFirst(), settings.$opensInBackground.dropFirst())
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.windows.updateActivationPolicy() }
            .store(in: &cancellables)

        if SnapshotMode.isRequested {
            SnapshotMode.run(windows: windows, statusItem: statusItemController)
            return
        }

        if Self.isMeasuringInstance {
            // Out of the Dock, so a Dock click meant for another copy of Tally cannot open this one's window.
            NSApp.setActivationPolicy(.accessory)
            return
        }

        if !settings.hasCompletedWelcome {
            windows.showWelcome {
                AppSettings.shared.hasCompletedWelcome = true
            }
        } else if !settings.opensInBackground {
            windows.showMain()
        }
    }

    /// `--no-window` starts an instance for measuring background cost, which must stay windowless.
    private static let isMeasuringInstance = CommandLine.arguments.contains("--no-window")

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, !Self.isMeasuringInstance { windows.showMain() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @objc func showSettingsWindow(_ sender: Any?) {
        windows.showSettings()
    }

    @objc func showMainWindow(_ sender: Any?) {
        windows.showMain()
    }

    @objc func showExport(_ sender: Any?) {
        windows.showMain()
        AppRouter.shared.isExportPresented = true
    }

    @objc func selectTab(_ sender: NSMenuItem) {
        guard let tab = sender.representedObject as? String, let value = TallyTab(rawValue: tab) else { return }
        AppRouter.shared.open(value)
    }

    /// Checks the tab the main window shows. Runs only while a menu is open.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(selectTab(_:)) {
            let isCurrent = (menuItem.representedObject as? String) == AppRouter.shared.tab.rawValue
            menuItem.state = isCurrent ? .on : .off
        }
        return true
    }
}
