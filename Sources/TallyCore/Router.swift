import Foundation
import Combine

public enum TallyTab: String, CaseIterable, Identifiable, Sendable {
    case overview, cpu, memory, disk, network, gpu, battery, sensors, projects

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .overview: "Overview"
        case .cpu: "CPU"
        case .memory: "Memory"
        case .disk: "Disk"
        case .network: "Network"
        case .gpu: "GPU"
        case .battery: "Battery"
        case .sensors: "Sensors"
        case .projects: "Projects"
        }
    }
}

/// Navigation shared by the main window, the menu bar panel and notifications.
@MainActor
public final class AppRouter: ObservableObject {
    public static let shared = AppRouter()

    @Published public var tab: TallyTab = .overview
    /// The app whose processes are shown in the detail sheet, if any.
    @Published public var inspectedAppID: String?
    @Published public var isExportPresented = false

    /// Installed by the app target.
    public var showMainWindow: () -> Void = {}
    public var showSettings: () -> Void = {}
    public var engine: SamplingEngine?

    private init() {}

    public func open(_ tab: TallyTab, inspecting appID: String? = nil) {
        self.tab = tab
        inspectedAppID = appID
        showMainWindow()
    }
}
