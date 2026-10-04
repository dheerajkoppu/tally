import SwiftUI
import TallyCore

/// One project: folder badge, name, ports, status and memory. Expands on click to list its processes.
struct ProjectRow: View {
    let project: Project
    let isExpanded: Bool
    let now: Date
    let onToggle: () -> Void
    let onStop: (StopRequest) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onToggle) { header }
                .buttonStyle(HoverRowStyle())
                .help(isExpanded ? "Hide processes" : "Show processes")
                .contextMenu { ProjectMenu(project: project, onStop: onStop) }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(project.name)
                .accessibilityValue(accessibilitySummary)
                .accessibilityHint(isExpanded ? "Hides its processes" : "Shows its processes")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { onToggle() }
                // Listed last to first: SwiftUI hands custom actions to VoiceOver in reverse order.
                .accessibilityActions {
                    ForEach(project.ports.uniqued().reversed(), id: \.self) { port in
                        Button("Open localhost:\(String(port)) in Browser") { ProjectActions.openInBrowser(port: port) }
                    }
                    Button("Open in Terminal") { ProjectActions.openInTerminal(project) }
                    Button("Show in Finder") { ProjectActions.showInFinder(project) }
                    Button("Force Quit Project") { onStop(ProjectActions.stopRequest(for: project, force: true)) }
                    Button("Stop Project") { onStop(ProjectActions.stopRequest(for: project, force: false)) }
                }
            if isExpanded {
                ProcessPanel(project: project, now: now, onStop: onStop)
                    .padding(.leading, 46)
                    .padding(.trailing, 12)
                    .padding(.bottom, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ProjectBadge(symbol: "folder")
            VStack(alignment: .leading, spacing: ProjectLayout.titleSpacing) {
                Text(project.name)
                    .font(Typography.rowTitle)
                    .foregroundStyle(Palette.ink)
                Text(subtitle)
                    .font(Typography.rowSubtitle)
                    .foregroundStyle(Palette.ink2)
            }
            .lineLimit(1)
            .layoutPriority(1)
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                ForEach(project.ports.uniqued(), id: \.self) { port in
                    PortPill(port: port)
                }
                StatusPill(activity: ProjectStatus.activity(of: project), now: now)
            }
            Text(Format.memory(project.memoryBytes).text)
                .font(Typography.rowValue)
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .frame(minWidth: 64, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: ProjectLayout.rowHeight)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        if project.processes.count == 1, let only = project.processes.first { return ProjectText.runtime(only) }
        return Format.processes(project.processes.count)
    }

    /// "node, port 4322, idle 45 min, 458 MB, expanded"
    private var accessibilitySummary: String {
        var parts = [subtitle]
        let ports = project.ports.uniqued()
        if !ports.isEmpty { parts.append(ProjectText.ports(ports)) }
        if let pill = ProjectStatus.pill(for: ProjectStatus.activity(of: project), now: now) { parts.append(pill.text) }
        parts.append(Format.memory(project.memoryBytes).text)
        parts.append(isExpanded ? "expanded" : "collapsed")
        return parts.joined(separator: ", ")
    }
}

/// Right-click menu for a project.
struct ProjectMenu: View {
    let project: Project
    let onStop: (StopRequest) -> Void

    var body: some View {
        Button("Stop Project") { onStop(ProjectActions.stopRequest(for: project, force: false)) }
        Button("Force Quit Project") { onStop(ProjectActions.stopRequest(for: project, force: true)) }
        Divider()
        Button("Show in Finder") { ProjectActions.showInFinder(project) }
        Button("Open in Terminal") { ProjectActions.openInTerminal(project) }
        let ports = project.ports.uniqued()
        if !ports.isEmpty {
            Divider()
            ForEach(ports, id: \.self) { port in
                Button("Open localhost:\(String(port)) in Browser") { ProjectActions.openInBrowser(port: port) }
            }
        }
        Divider()
        Button("Copy Path") { ProjectActions.copy(project.path) }
    }
}

/// The processes of an expanded project, with Stop for each and Stop Project under the list.
struct ProcessPanel: View {
    let project: Project
    let now: Date
    let onStop: (StopRequest) -> Void
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 0) {
                ForEach(Array(project.processes.enumerated()), id: \.element.id) { index, process in
                    if index > 0 {
                        Rectangle().fill(contrast == .increased ? Palette.ink3 : Palette.line).frame(height: 1)
                    }
                    ProcessLine(process: process, project: project, now: now, onStop: onStop)
                }
            }
            .padding(.horizontal, 14)
            .background(Palette.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            HStack(spacing: 8) {
                Text(ProjectText.abbreviatedPath(project.path))
                    .font(Typography.rowSubtitle)
                    .foregroundStyle(Palette.ink2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer(minLength: 12)
                Button { ProjectActions.showInFinder(project) } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(ProjectButtonStyle())
                .help("Show in Finder")
                .accessibilityLabel("Show \(project.name) in Finder")
                Button { ProjectActions.openInTerminal(project) } label: {
                    Image(systemName: "terminal")
                }
                .buttonStyle(ProjectButtonStyle())
                .help("Open in Terminal")
                .accessibilityLabel("Open \(project.name) in Terminal")
                Button("Stop Project") { onStop(ProjectActions.stopRequest(for: project, force: false)) }
                    .buttonStyle(ProjectButtonStyle(tint: Palette.accent))
                    .help("Stop every process in \(project.name), after a confirmation")
            }
        }
    }
}

/// One process: its command, runtime, pid and state, then ports, CPU, memory and Stop.
struct ProcessLine: View {
    let process: DevProcess
    let project: Project
    let now: Date
    let onStop: (StopRequest) -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(ProjectText.command(process, in: project))
                    .font(Typography.tableText)
                    .foregroundStyle(Palette.ink)
                    .truncationMode(.middle)
                    .help(process.commandLine)
                Text(detail)
                    .font(Typography.rowSubtitle)
                    .foregroundStyle(Palette.ink2)
            }
            .lineLimit(1)
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                ForEach(process.ports, id: \.self) { port in
                    PortPill(port: port)
                }
            }
            Text(Format.precisePercent(process.cpuPercent))
                .font(Typography.label.monospacedDigit())
                .foregroundStyle(Palette.ink2)
                .frame(minWidth: 44, alignment: .trailing)
                .help("CPU, share of one core")
            Text(Format.memory(process.memoryBytes).text)
                .font(Typography.rowValue)
                .foregroundStyle(Palette.ink)
                .frame(minWidth: 58, alignment: .trailing)
            Button("Stop") { onStop(ProjectActions.stopRequest(for: process, in: project)) }
                .buttonStyle(ProjectButtonStyle())
                .help("Stop this process, after a confirmation")
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .accessibilityReading(ProjectText.command(process, in: project), value: accessibilitySummary)
        // Listed last to first: SwiftUI hands custom actions to VoiceOver in reverse order.
        .accessibilityActions {
            Button("Copy PID") { ProjectActions.copy(String(process.pid)) }
            Button("Copy Command") { ProjectActions.copy(process.commandLine) }
            ForEach(process.ports.reversed(), id: \.self) { port in
                Button("Open localhost:\(String(port)) in Browser") { ProjectActions.openInBrowser(port: port) }
            }
            Button("Stop") { onStop(ProjectActions.stopRequest(for: process, in: project)) }
        }
        .contextMenu {
            Button("Stop") { onStop(ProjectActions.stopRequest(for: process, in: project)) }
            ForEach(process.ports, id: \.self) { port in
                Button("Open localhost:\(String(port)) in Browser") { ProjectActions.openInBrowser(port: port) }
            }
            Divider()
            Button("Copy Command") { ProjectActions.copy(process.commandLine) }
            Button("Copy PID") { ProjectActions.copy(String(process.pid)) }
        }
    }

    private var detail: String {
        detailParts.joined(separator: " · ")
    }

    private var detailParts: [String] {
        var parts = [ProjectText.runtime(process), "pid \(process.pid)"]
        if let startDate = process.startDate { parts.append("up \(Format.span(now.timeIntervalSince(startDate)))") }
        if let state = ProjectStatus.processDetail(process, now: now) { parts.append(state) }
        return parts
    }

    /// "node, pid 4122, up 2 hours, idle 45 min, port 3000, 0.1% CPU, 212 MB"
    private var accessibilitySummary: String {
        var parts = detailParts
        if !process.ports.isEmpty { parts.append(ProjectText.ports(process.ports)) }
        parts.append("\(Format.precisePercent(process.cpuPercent)) CPU")
        parts.append(Format.memory(process.memoryBytes).text)
        return parts.joined(separator: ", ")
    }
}

extension Array where Element == Int {
    func uniqued() -> [Int] { Array(Set(self)).sorted() }
}
