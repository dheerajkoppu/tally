import SwiftUI
import TallyCore

/// The Projects tab of the main window.
/// Follows only the store's project list, so samples that change nothing here cost nothing.
public struct ProjectsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var projects = TallyStore.shared.projects
    @State private var hasSample = TallyStore.shared.hasSample
    @State private var expanded: Set<String> = []
    @State private var stopRequest: StopRequest?
    /// Processes just asked to stop, hidden until the next scan confirms they are gone.
    @State private var stopping: [Int32: Date] = [:]
    @State private var stopTracker = ProjectStopTracker()

    private static let stoppingGrace: TimeInterval = ProjectStopTracker.grace
    /// How long "4 servers stopped." stays before the idle banner, if any, returns.
    private static let resultDuration: Duration = .seconds(8)

    public init() {}

    public var body: some View {
        let now = Date()
        let visible = visibleProjects(now: now)
        let idleServers = visible.filter { ProjectStatus.isIdleServer($0, now: now) }
        Card(padding: 6) {
            VStack(spacing: 0) {
                if let result = stopTracker.result {
                    StoppedServersBanner(result: result)
                        .transition(.opacity)
                        .task(id: result.id) {
                            try? await Task.sleep(for: Self.resultDuration)
                            guard !Task.isCancelled else { return }
                            withAnimation(reduceMotion ? nil : .snappy(duration: 0.3)) { stopTracker.dismiss() }
                        }
                } else if !idleServers.isEmpty {
                    IdleServersBanner(projects: idleServers) {
                        stopRequest = ProjectActions.stopRequest(forIdle: idleServers)
                    }
                    .transition(.opacity)
                }
                if visible.isEmpty {
                    ProjectsEmptyState(isScanning: !hasSample)
                } else {
                    ForEach(visible) { project in
                        ProjectRow(
                            project: project,
                            isExpanded: expanded.contains(project.id),
                            now: now,
                            onToggle: { toggle(project.id) },
                            onStop: { stopRequest = $0 }
                        )
                    }
                }
            }
            .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: visible.map(\.id))
        }
        .alert(stopRequest?.title ?? "", isPresented: isConfirming, presenting: stopRequest) { request in
            if !request.forceOnly {
                Button(request.stopTitle, role: .destructive) { perform(request, force: false) }
            }
            Button("Force Quit", role: .destructive) { perform(request, force: true) }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            Text(request.message)
        }
        .onReceive(TallyStore.shared.$projects) { latest in
            let running = Set(latest.flatMap { $0.processes.map(\.pid) })
            let now = Date()
            projects = latest
            stopping = stopping.filter { running.contains($0.key) && now.timeIntervalSince($0.value) < Self.stoppingGrace }
            expanded = expanded.intersection(latest.map(\.id))
            if stopTracker.isWaiting {
                let previous = stopTracker.result?.id
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.3)) { stopTracker.update(with: latest, now: now) }
                if let result = stopTracker.result, result.id != previous {
                    AccessibilityNotification.Announcement("\(result.title) \(result.detail)").post()
                }
            }
        }
        .onReceive(TallyStore.shared.$hasSample.removeDuplicates()) { hasSample = $0 }
    }

    private var isConfirming: Binding<Bool> {
        Binding(get: { stopRequest != nil }, set: { if !$0 { stopRequest = nil } })
    }

    private func visibleProjects(now: Date) -> [Project] {
        let hidden = Set(stopping.filter { now.timeIntervalSince($0.value) < Self.stoppingGrace }.keys)
        guard !hidden.isEmpty else { return projects }
        return projects.compactMap { project in
            var trimmed = project
            trimmed.processes.removeAll { hidden.contains($0.pid) }
            return trimmed.processes.isEmpty ? nil : trimmed
        }
    }

    private func toggle(_ id: String) {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) {
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        }
    }

    private func perform(_ request: StopRequest, force: Bool) {
        if force {
            ProcessActions.forceQuit(request.quitRequest)
        } else {
            ProcessActions.quit(request.quitRequest)
        }
        let now = Date()
        stopTracker.begin(stopping: request.pids, in: projects, at: now)
        for pid in request.pids { stopping[pid] = now }
        AppRouter.shared.engine?.sampleNow()
    }
}
