import SwiftUI
import AppKit
import TallyCore

/// A row in the app list: a running app, or an app from a history range. Only what the row shows, so rows compare cheaply.
struct MetricAppRowModel: Identifiable, Equatable {
    var id: String
    var name: String
    var subtitle: String
    var value: String
    /// 0...1 against the first row, rounded to half a percent.
    var fraction: Double
    /// For the icon: the app's bundle, if it has one. Tools and the macOS group are found by `id`.
    var bundlePath: String?
    var canQuit: Bool
    /// Bundle or executable path, for Show in Finder.
    var path: String?

    init(app: AppUsage, value: String, fraction: Double) {
        id = app.id
        name = app.name
        subtitle = Format.processes(app.processCount)
        self.value = value
        self.fraction = MetricTabContent.rounded(fraction)
        bundlePath = app.bundlePath
        canQuit = MetricAppMenu.canQuit(app)
        path = app.bundlePath ?? app.processes.first?.executablePath
    }

    init(total: HistoryAppTotal, running: AppUsage?, value: String, fraction: Double) {
        id = total.appID
        name = running?.name ?? total.name
        subtitle = running.map { Format.processes($0.processCount) } ?? "Not running"
        self.value = value
        self.fraction = MetricTabContent.rounded(fraction)
        bundlePath = running?.bundlePath ?? total.bundlePath
        canQuit = MetricAppMenu.canQuit(running)
        path = running?.bundlePath ?? running?.processes.first?.executablePath ?? total.bundlePath ?? (total.appID.hasPrefix("/") ? total.appID : nil)
    }
}

/// What a row can ask for. Each action looks the app up when it runs, so a row that did not redraw never acts on stale figures.
struct MetricAppActions {
    var inspect: (String) -> Void
    var quit: (String) -> Void
    var forceQuit: (String) -> Void
}

/// "App … CPU" and the apps behind the tab's figure, with the first row raised.
struct MetricAppListCard: View {
    let title: String
    let valueTitle: String
    /// True for history lists, whose figure VoiceOver reads after its title ("average 44.1%").
    var isHistory = false
    /// The rows on screen: the first eight, or every row after Show All.
    let rows: [MetricAppRowModel]
    let totalCount: Int
    let tint: Color
    let isPlaceholder: Bool
    let emptyMessage: String
    @Binding var showsAll: Bool
    let actions: MetricAppActions

    @FocusState private var focusedRow: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                Spacer(minLength: 12)
                Text(valueTitle)
            }
            .font(Typography.label)
            .foregroundStyle(Palette.ink2)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.top, 9)
            .padding(.bottom, 7)
            .accessibilityHidden(true)

            if isPlaceholder {
                ForEach(0..<5, id: \.self) { index in
                    MetricSkeletonRow(isRaised: index == 0)
                }
                .accessibilityHidden(true)
            } else if rows.isEmpty {
                Text(emptyMessage)
                    .font(Typography.body)
                    .foregroundStyle(Palette.ink2)
                    .frame(maxWidth: .infinity)
                    .frame(height: MetricLayout.rowHeight)
            } else {
                ForEach(rows) { row in
                    MetricAppRow(row: row, tint: tint, isRaised: row.id == rows.first?.id, valueTitle: valueTitle, isHistory: isHistory, actions: actions)
                        .equatable()
                        .focused($focusedRow, equals: row.id)
                }
                if totalCount > MetricLayout.visibleApps {
                    MetricShowAllButton(count: totalCount, showsAll: $showsAll)
                }
            }
        }
        .onMoveCommand(perform: moveFocus)
        .padding(.horizontal, 6)
        .padding(.top, 6)
        .padding(.bottom, 7.5)
        .frame(maxWidth: .infinity)
        .metricSurface()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title == "App" ? "Apps by \(valueTitle)" : title)
    }

    /// Up and down arrows move between rows once one has keyboard focus.
    private func moveFocus(_ direction: MoveCommandDirection) {
        guard let focusedRow, let index = rows.firstIndex(where: { $0.id == focusedRow }) else { return }
        switch direction {
        case .up where index > 0: self.focusedRow = rows[index - 1].id
        case .down where index < rows.count - 1: self.focusedRow = rows[index + 1].id
        default: break
        }
    }
}

struct MetricShowAllButton: View {
    let count: Int
    @Binding var showsAll: Bool
    @State private var isHovered = false

    var body: some View {
        Button {
            showsAll.toggle()
        } label: {
            HStack(spacing: 5) {
                Text(showsAll ? "Show Fewer" : "Show All \(count) Apps")
                Image(systemName: showsAll ? "chevron.up" : "chevron.down")
                    .font(Typography.inlineSymbol)
                    .accessibilityHidden(true)
            }
            .font(Typography.listButton)
            .foregroundStyle(isHovered ? Palette.ink : Palette.ink2)
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .contentShape(Rectangle())
            .controlOutline(RoundedRectangle(cornerRadius: MetricLayout.rowRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

/// One app: icon, name, process count, figure and a meter. Redraws only when what it shows changes.
/// VoiceOver reads "Google Chrome, 96 processes, 44.1% CPU" and offers Inspect, Quit, Force Quit and Show in Finder.
struct MetricAppRow: View, Equatable {
    let row: MetricAppRowModel
    let tint: Color
    let isRaised: Bool
    /// The list's column title, "CPU" or "Average", spoken with the figure.
    let valueTitle: String
    let isHistory: Bool
    let actions: MetricAppActions

    @State private var isHovered = false

    static func == (lhs: MetricAppRow, rhs: MetricAppRow) -> Bool {
        lhs.row == rhs.row && lhs.isRaised == rhs.isRaised && lhs.tint == rhs.tint && lhs.valueTitle == rhs.valueTitle && lhs.isHistory == rhs.isHistory
    }

    var body: some View {
        Button {
            actions.inspect(row.id)
        } label: {
            HStack(spacing: 12) {
                AppIconView(appID: row.id, bundlePath: row.bundlePath, size: MetricLayout.rowIconSize)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.name)
                        .font(Typography.rowTitle)
                        .foregroundStyle(Palette.ink)
                    Text(row.subtitle)
                        .font(Typography.rowSubtitle)
                        .foregroundStyle(Palette.ink2)
                }
                .lineLimit(1)
                Spacer(minLength: 16)
                VStack(alignment: .trailing, spacing: 6) {
                    Text(row.value)
                        .font(Typography.rowValue)
                        .tracking(-0.2)
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    Meter(row.fraction, tint: tint, height: 4)
                        .frame(width: MetricLayout.meterWidth)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: MetricLayout.rowHeight)
            .background(background, in: RoundedRectangle(cornerRadius: MetricLayout.rowRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: MetricLayout.rowRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .contentShape(.focusEffect, RoundedRectangle(cornerRadius: MetricLayout.rowRadius, style: .continuous))
        .onKeyPress(.return) {
            actions.inspect(row.id)
            return .handled
        }
        .onHover { isHovered = $0 }
        .contextMenu { MetricAppMenu(row: row, actions: actions) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.name)
        .accessibilityValue("\(row.subtitle), \(spokenFigure)")
        .accessibilityHint("Shows the app's processes")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { actions.inspect(row.id) }
        // Listed last to first: SwiftUI hands custom actions to VoiceOver in reverse order.
        .accessibilityActions {
            if let path = row.path {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            }
            if row.canQuit {
                Button("Force Quit") { actions.forceQuit(row.id) }
                Button("Quit") { actions.quit(row.id) }
            }
            Button("Inspect") { actions.inspect(row.id) }
        }
    }

    /// "44.1% CPU", "5.3 MB/s writing", or for history "average 44.1%".
    private var spokenFigure: String {
        let title = valueTitle == valueTitle.uppercased() ? valueTitle : valueTitle.lowercased()
        return isHistory ? "\(title) \(row.value)" : "\(row.value) \(title)"
    }

    private var background: Color {
        if isRaised { return Palette.raised }
        return isHovered ? Palette.raised.opacity(0.55) : .clear
    }
}

/// Inspect, Quit, Force Quit and Show in Finder, for an app row's context menu.
struct MetricAppMenu: View {
    let row: MetricAppRowModel
    let actions: MetricAppActions

    var body: some View {
        Button("Inspect") { actions.inspect(row.id) }
        Divider()
        Button("Quit") { actions.quit(row.id) }
            .disabled(!row.canQuit)
        Button("Force Quit", role: .destructive) { actions.forceQuit(row.id) }
            .disabled(!row.canQuit)
        Divider()
        Button("Show in Finder") {
            if let path = row.path { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
        }
        .disabled(row.path == nil)
    }

    /// The macOS group is many system processes, not something to quit.
    static func canQuit(_ app: AppUsage?) -> Bool {
        guard let app else { return false }
        return app.kind != .system && !app.processes.isEmpty
    }
}

struct MetricSkeletonRow: View {
    let isRaised: Bool

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Palette.cardHighlight)
                .frame(width: 26, height: 26)
                .padding(1)
            VStack(alignment: .leading, spacing: 5) {
                MetricSkeletonBar(width: 120)
                MetricSkeletonBar(width: 72, height: 7)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 7) {
                MetricSkeletonBar(width: 48)
                MetricSkeletonBar(width: MetricLayout.meterWidth, height: 4)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: MetricLayout.rowHeight)
        .background(isRaised ? Palette.raised : .clear, in: RoundedRectangle(cornerRadius: MetricLayout.rowRadius, style: .continuous))
    }
}

extension QuitRequest {
    /// The same request, worded for Force Quit.
    var metricForced: QuitRequest {
        let name = title.hasPrefix("Quit ") ? String(title.dropFirst(5)) : title
        return QuitRequest(id: id, title: "Force Quit \(name)", message: "Unsaved work will be lost. \(message)", pids: pids, appPid: appPid, startDates: startDates)
    }
}

/// Asks before force quitting: "Force Quit Safari? / Unsaved work will be lost."
struct MetricForceQuitConfirmation: ViewModifier {
    @Binding var request: QuitRequest?
    let onDone: () -> Void

    func body(content: Content) -> some View {
        content.alert(
            request?.title ?? "",
            isPresented: Binding(get: { request != nil }, set: { if !$0 { request = nil } }),
            presenting: request
        ) { request in
            Button("Force Quit", role: .destructive) {
                ProcessActions.forceQuit(request)
                onDone()
            }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            Text(request.message)
        }
    }
}

extension View {
    func metricForceQuitConfirmation(_ request: Binding<QuitRequest?>, onDone: @escaping () -> Void = {}) -> some View {
        modifier(MetricForceQuitConfirmation(request: request, onDone: onDone))
    }
}
