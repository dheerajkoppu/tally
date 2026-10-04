import SwiftUI
import TallyCore

/// Projects with dev servers or open ports, largest first, with a way to stop the idle ones.
struct ProjectsPanel: View {
    static let visibleLimit = 6

    /// How long "4 servers stopped." stays before the idle banner, if any, returns.
    private static let resultDuration: Duration = .seconds(8)

    @ObservedObject private var store = TallyStore.shared
    @State private var pendingStop: QuitRequest?
    @State private var stopTracker = ProjectStopTracker()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let projects = store.projects.sorted { $0.memoryBytes > $1.memoryBytes }
        VStack(spacing: 0) {
            PanelSectionTitle("Projects")
            Group {
                if projects.isEmpty {
                    emptyState
                } else {
                    list(projects)
                }
            }
            .padding(.top, 10)
        }
        .onReceive(store.$projects) { latest in
            guard stopTracker.isWaiting else { return }
            let previous = stopTracker.result?.id
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { stopTracker.update(with: latest) }
            if let result = stopTracker.result, result.id != previous {
                AccessibilityNotification.Announcement("\(result.title) \(result.detail)").post()
            }
        }
    }

    private func stop(_ request: QuitRequest) {
        stopTracker.begin(stopping: request.pids, in: store.projects)
        ProcessActions.quit(request)
        AppRouter.shared.engine?.sampleNow()
    }

    @ViewBuilder
    private var stoppedBanner: some View {
        if let result = stopTracker.result {
            PanelStoppedBanner(result: result)
                .transition(.opacity)
                .task(id: result.id) {
                    try? await Task.sleep(for: Self.resultDuration)
                    guard !Task.isCancelled else { return }
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { stopTracker.dismiss() }
                }
        }
    }

    private func list(_ projects: [Project]) -> some View {
        let memory = projects.reduce(UInt64(0)) { $0 + $1.memoryBytes }
        let ports = Set(projects.flatMap(\.ports)).count
        let now = Date()
        let idle = projects.filter { Self.isIdleServer($0, now: now) }
        return PanelCard {
            PanelMetricHeader {
                PanelFigure(Figure("\(projects.count)", projects.count == 1 ? "project" : "projects"), size: 29)
            } caption: {
                Text(verbatim: "\(Format.memory(memory).text) · \(ports == 1 ? "1 port" : "\(ports) ports") open")
            } trailing: {
                EmptyView()
            }
            if stopTracker.result != nil {
                stoppedBanner
                    .padding(.top, 12)
            } else if !idle.isEmpty {
                IdleBanner(idle: idle, pendingStop: $pendingStop, onStop: stop)
                    .padding(.top, 12)
                    .transition(.opacity)
            }
            PanelDivider()
                .padding(.top, 12)
                .padding(.bottom, 3)
            PanelListTitle(title: "Running Now")
            ForEach(projects.prefix(Self.visibleLimit)) { project in
                ProjectRow(project: project)
            }
            if projects.count > Self.visibleLimit {
                Button {
                    PanelActions.openMainWindow(.projects)
                } label: {
                    Text(verbatim: "and \(projects.count - Self.visibleLimit) more in Tally")
                        .font(.system(size: 11))
                        .panelSecondaryText()
                        .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show every project in Tally")
            }
        }
    }

    /// The Projects tab's rule: a server with ports whose processes are all quiet, for half an hour or since a day ago,
    /// so the panel never offers to stop a server that was in use a few minutes ago.
    private static let idleServerQuiet: TimeInterval = 30 * 60

    private static func isIdleServer(_ project: Project, now: Date) -> Bool {
        guard !project.ports.isEmpty, !project.processes.isEmpty else { return false }
        var allBarelyUsed = true
        var latestActivity: Date?
        for process in project.processes {
            switch process.activity {
            case .working: return false
            case .barelyUsed: break
            case .idle: allBarelyUsed = false
            }
            if let date = process.lastActiveDate ?? process.startDate {
                latestActivity = max(latestActivity ?? date, date)
            }
        }
        guard !allBarelyUsed else { return true }
        guard let latestActivity else { return false }
        return now.timeIntervalSince(latestActivity) >= idleServerQuiet
    }

    private var emptyState: some View {
        PanelCard(top: stopTracker.result == nil ? 22 : 12, bottom: 22) {
            if stopTracker.result != nil {
                stoppedBanner
                    .padding(.bottom, 14)
            }
            VStack(spacing: 8) {
                IconBadge(TallyTab.projects.symbol, tint: Palette.accent, size: 34)
                Text("No dev servers running")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .padding(.top, 2)
                Text("Projects appear here when a dev server or a process with an open port runs inside a folder.")
                    .font(.system(size: 12))
                    .panelSecondaryText()
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

private struct ProjectRow: View {
    let project: Project

    @State private var isHovered = false

    var body: some View {
        let ports = project.ports
        Button {
            PanelActions.openMainWindow(.projects)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: TallyTab.projects.symbol)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(project.isWorking ? Palette.accent : Palette.ink2)
                    .frame(width: 18)
                Text(project.name)
                    .font(PanelMetrics.rowFont)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                ViewThatFits(in: .horizontal) {
                    badges(ports, showsIdle: true)
                    badges(ports, showsIdle: false)
                    EmptyView()
                }
                .layoutPriority(0.5)
                Spacer(minLength: 8)
                Text(Format.memory(project.memoryBytes).text)
                    .font(PanelMetrics.valueFont)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .fixedSize()
            }
            .frame(height: PanelMetrics.appRowHeight)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Palette.raised)
                    .padding(.horizontal, -7)
                    .padding(.vertical, 1)
                    .opacity(isHovered ? 1 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(project.path)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens Projects in Tally")
    }

    private func badges(_ ports: [Int], showsIdle: Bool) -> some View {
        HStack(spacing: 8) {
            ForEach(ports.prefix(2), id: \.self) { port in
                PanelTag(text: String(port), tint: Palette.accent)
            }
            if ports.count > 2 {
                Text(verbatim: "+\(ports.count - 2)")
                    .font(.system(size: 11, weight: .semibold))
                    .panelSecondaryText()
            }
            if showsIdle, let idleText {
                Text(idleText)
                    .font(.system(size: 11))
                    .panelSecondaryText()
            }
        }
        .lineLimit(1)
        .fixedSize()
    }

    /// "idle 45 min" when every process in the project has been quiet.
    private var idleText: String? {
        guard !project.isWorking else { return nil }
        let since = project.processes.compactMap { process -> Date? in
            switch process.activity {
            case .working: nil
            case .idle(let since): since
            case .barelyUsed(let upSince): upSince
            }
        }.min()
        guard let since else { return nil }
        return "idle \(Format.span(Date().timeIntervalSince(since)))"
    }
}

/// Points out dev servers left idle and offers to stop them, asking first.
private struct IdleBanner: View {
    let idle: [Project]
    @Binding var pendingStop: QuitRequest?
    let onStop: (QuitRequest) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var processCount: Int {
        idle.reduce(0) { $0 + $1.processes.count }
    }

    var body: some View {
        let memory = idle.reduce(UInt64(0)) { $0 + $1.memoryBytes }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.caution)
                VStack(alignment: .leading, spacing: 1) {
                    Text(processCount == 1 ? "1 dev server is idle" : "\(processCount) dev servers are idle")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                    Text(verbatim: "\(Format.memory(memory).text) could be freed")
                        .font(.system(size: 11.5))
                        .panelSecondaryText()
                }
                .lineLimit(1)
                Spacer(minLength: 6)
                if pendingStop == nil {
                    Button("Stop All") {
                        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { pendingStop = request }
                    }
                    .buttonStyle(SoftButtonStyle(tint: Palette.caution, prominent: true))
                    .help("Stop the idle dev servers, after asking")
                }
            }
            if let pending = pendingStop {
                confirmation(pending)
                    .transition(.opacity)
            }
        }
        .padding(10)
        .background(Palette.caution.opacity(0.10), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .onChange(of: pendingStop) { _, pending in
            PanelActions.isConfirming = pending != nil
        }
        .onDisappear {
            PanelActions.isConfirming = false
            // The idle servers changed under the confirmation; a later banner must not reopen it with the old list.
            pendingStop = nil
        }
    }

    private var request: QuitRequest {
        let pids = idle.flatMap { $0.processes.map(\.pid) }
        let names = idle.map(\.name).joined(separator: ", ")
        let title = idle.count == 1 ? "Stop \(idle[0].name)?" : "Stop \(idle.count) idle projects?"
        let processText = pids.count == 1 ? "1 process" : "\(pids.count) processes"
        let message = idle.count == 1 ? "\(processText) will close." : "\(names): \(processText) will close."
        var startDates: [Int32: Date] = [:]
        for process in idle.flatMap(\.processes) {
            if let startDate = process.startDate { startDates[process.pid] = startDate }
        }
        return QuitRequest(id: "idle-projects", title: title, message: message, pids: pids, appPid: nil, startDates: startDates)
    }

    private func confirmation(_ pending: QuitRequest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(pending.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text(pending.message)
                    .font(.system(size: 11.5))
                    .panelSecondaryText()
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel", role: .cancel) {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { pendingStop = nil }
                }
                .buttonStyle(SoftButtonStyle())
                .keyboardShortcut(.cancelAction)
                Button("Stop", role: .destructive) {
                    pendingStop = nil
                    onStop(pending)
                }
                .buttonStyle(SoftButtonStyle(tint: Palette.red, prominent: true))
            }
        }
        .padding(10)
        .background(Palette.raised, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

/// "4 servers stopped." and what that freed, in place of the idle banner for a few seconds after a stop.
private struct PanelStoppedBanner: View {
    let result: ProjectStopTracker.Result

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LegibleTint(Palette.good, wash: 0.10))
            VStack(alignment: .leading, spacing: 1) {
                Text(result.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text(result.detail)
                    .font(.system(size: 11.5))
                    .panelSecondaryText()
                    .fixedSize(horizontal: false, vertical: true)
            }
            .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Palette.good.opacity(0.10), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
