import SwiftUI
import AppKit
import TallyCore

/// What a process row shows, so unchanged rows are not drawn again.
struct InspectorProcessRowModel: Identifiable, Equatable {
    var id: Int32 { pid }
    var pid: Int32
    var name: String
    var cpu: String
    var memory: String
    var isRestricted: Bool
    var canQuit: Bool
    var isSessionProcess: Bool
    var executablePath: String?

    /// Ending one of these ends the login session, losing unsaved work in every app.
    private static let sessionProcesses: Set<String> = ["loginwindow"]

    init(_ process: ProcessSample) {
        pid = process.pid
        name = process.name
        cpu = MetricTabContent.appPercent(process.cpuPercent)
        memory = Format.memory(process.memoryBytes).text
        isRestricted = process.isRestricted
        isSessionProcess = Self.sessionProcesses.contains(process.name)
        // Only processes owned by this user can be signalled.
        canQuit = process.uid == getuid() && process.pid > 1 && !isSessionProcess
        executablePath = process.executablePath
    }
}

/// The app's processes, sortable by CPU or memory, each with its own Quit
struct InspectorProcessTable: View {
    let processes: [ProcessSample]
    let isRunning: Bool
    let wasRunning: Bool
    @Binding var sort: InspectorSort
    let onQuit: (Int32) -> Void
    let onForceQuit: (Int32) -> Void

    @State private var showsAll = false
    private static let visibleCount = 12

    static let pidWidth: CGFloat = 64
    static let cpuWidth: CGFloat = 70
    static let memoryWidth: CGFloat = 84
    static let actionWidth: CGFloat = 56

    var body: some View {
        let sorted = sortedProcesses
        let visible = showsAll ? sorted : Array(sorted.prefix(Self.visibleCount))
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Process").frame(maxWidth: .infinity, alignment: .leading)
                Text("PID").frame(width: Self.pidWidth, alignment: .trailing)
                sortHeader("CPU", key: .cpu).frame(width: Self.cpuWidth, alignment: .trailing)
                sortHeader("Memory", key: .memory).frame(width: Self.memoryWidth, alignment: .trailing)
                Color.clear.frame(width: Self.actionWidth, height: 1)
            }
            .font(Typography.label)
            .foregroundStyle(Palette.ink2)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 8)

            if sorted.isEmpty {
                Text(isRunning ? "No processes" : (wasRunning ? "No longer running" : "Not running"))
                    .font(Typography.body)
                    .foregroundStyle(Palette.ink2)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
            } else {
                ForEach(Array(visible.enumerated()), id: \.element.pid) { index, process in
                    InspectorProcessRow(
                        row: InspectorProcessRowModel(process),
                        isStriped: index.isMultiple(of: 2),
                        onQuit: onQuit,
                        onForceQuit: onForceQuit
                    )
                    .equatable()
                }
                if sorted.count > Self.visibleCount {
                    InspectorShowAllButton(count: sorted.count, showsAll: $showsAll)
                }
            }
        }
        .padding(6)
        .metricSurface()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Processes")
    }

    private var sortedProcesses: [ProcessSample] {
        processes.sorted { first, second in
            switch sort {
            case .cpu:
                if first.cpuPercent != second.cpuPercent { return first.cpuPercent > second.cpuPercent }
                if first.memoryBytes != second.memoryBytes { return first.memoryBytes > second.memoryBytes }
            case .memory:
                if first.memoryBytes != second.memoryBytes { return first.memoryBytes > second.memoryBytes }
                if first.cpuPercent != second.cpuPercent { return first.cpuPercent > second.cpuPercent }
            }
            return first.pid < second.pid
        }
    }

    private func sortHeader(_ title: String, key: InspectorSort) -> some View {
        let isSelected = sort == key
        return Button {
            sort = key
        } label: {
            Text(title)
                .overlay(alignment: .leading) {
                    Image(systemName: "chevron.down")
                        .font(Typography.chevron.weight(.bold))
                        .offset(x: -11)
                        .opacity(isSelected ? 1 : 0)
                        .accessibilityHidden(true)
                }
                .foregroundStyle(isSelected ? Palette.ink : Palette.ink2)
                .fontWeight(isSelected ? .semibold : .regular)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Sort by \(title)")
        .accessibilityLabel("Sort by \(title)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct InspectorProcessRow: View, Equatable {
    let row: InspectorProcessRowModel
    let isStriped: Bool
    let onQuit: (Int32) -> Void
    let onForceQuit: (Int32) -> Void

    @State private var isHovered = false

    static func == (lhs: InspectorProcessRow, rhs: InspectorProcessRow) -> Bool {
        lhs.row == rhs.row && lhs.isStriped == rhs.isStriped
    }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                Text(row.name)
                    .font(Typography.tableText)
                    .foregroundStyle(Palette.ink)
                    .truncationMode(.middle)
                if row.isRestricted {
                    Image(systemName: Symbols.lock)
                        .font(Typography.inlineSymbol)
                        .foregroundStyle(Palette.ink2)
                        .help("Owned by another user. Some figures are limited.")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(String(row.pid))
                .font(Typography.label.monospacedDigit())
                .foregroundStyle(Palette.ink2)
                .frame(width: InspectorProcessTable.pidWidth, alignment: .trailing)
            Text(row.cpu)
                .font(Typography.tableValue)
                .foregroundStyle(Palette.ink)
                .frame(width: InspectorProcessTable.cpuWidth, alignment: .trailing)
            Text(row.memory)
                .font(Typography.tableValue)
                .foregroundStyle(Palette.ink)
                .frame(width: InspectorProcessTable.memoryWidth, alignment: .trailing)
            // Full strength while enabled: faded text on the grey capsule would fall below 4.5:1.
            Button("Quit") { onQuit(row.pid) }
                .buttonStyle(InspectorMiniButtonStyle())
                .frame(width: InspectorProcessTable.actionWidth, alignment: .trailing)
                .opacity(row.canQuit ? 1 : 0.35)
                .disabled(!row.canQuit)
                .help(row.canQuit ? "Quit \(row.name)" : (row.isSessionProcess ? "Quitting \(row.name) would log you out" : "\(row.name) belongs to another user"))
        }
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Quit") { onQuit(row.pid) }
                .disabled(!row.canQuit)
            Button("Force Quit", role: .destructive) { onForceQuit(row.pid) }
                .disabled(!row.canQuit)
            Divider()
            Button("Show in Finder") {
                if let path = row.executablePath { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            }
            .disabled(row.executablePath == nil)
            Button("Copy PID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(String(row.pid), forType: .string)
            }
        }
        .accessibilityReading(row.name, value: accessibilityValue)
        // Listed last to first: SwiftUI hands custom actions to VoiceOver in reverse order.
        .accessibilityActions {
            Button("Copy PID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(String(row.pid), forType: .string)
            }
            if let path = row.executablePath {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            }
            if row.canQuit {
                Button("Force Quit") { onForceQuit(row.pid) }
                Button("Quit") { onQuit(row.pid) }
            }
        }
    }

    /// "PID 412, 4.1% CPU, 300 MB memory, owned by another user".
    private var accessibilityValue: String {
        let value = "PID \(row.pid), \(row.cpu) CPU, \(row.memory) memory"
        return row.isRestricted ? "\(value), owned by another user" : value
    }

    private var background: Color {
        if isHovered { return Palette.cardHighlight }
        return isStriped ? Palette.raised.opacity(0.6) : .clear
    }
}

struct InspectorShowAllButton: View {
    let count: Int
    @Binding var showsAll: Bool
    @State private var isHovered = false

    var body: some View {
        Button {
            showsAll.toggle()
        } label: {
            HStack(spacing: 5) {
                Text(showsAll ? "Show Fewer" : "Show All \(count) Processes")
                Image(systemName: showsAll ? "chevron.up" : "chevron.down")
                    .font(Typography.inlineSymbol)
                    .accessibilityHidden(true)
            }
            .font(Typography.listButton)
            .foregroundStyle(isHovered ? Palette.ink : Palette.ink2)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .contentShape(Rectangle())
            .controlOutline(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

/// A small grey capsule button for rows: "Quit".
struct InspectorMiniButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.miniButton)
            .foregroundStyle(Palette.ink2)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Palette.cardHighlight, in: Capsule())
            .controlOutline(Capsule())
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Capsule())
    }
}
