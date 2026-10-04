import SwiftUI
import TallyCore

/// Icon, name, identity and the Quit, Force Quit and Done buttons. Done is the default button;
/// Escape also closes the sheet.
struct InspectorHeader: View, Equatable {
    let appID: String
    let bundlePath: String?
    let name: String
    let identity: String
    let isRunning: Bool
    let hasSample: Bool
    /// True once the app was seen running while the sheet was open.
    let wasSeen: Bool
    let processCount: Int
    let isSystem: Bool
    let canQuit: Bool
    let onQuit: () -> Void
    let onForceQuit: () -> Void
    let onDone: () -> Void

    static func == (lhs: InspectorHeader, rhs: InspectorHeader) -> Bool {
        lhs.appID == rhs.appID && lhs.bundlePath == rhs.bundlePath && lhs.name == rhs.name && lhs.identity == rhs.identity && lhs.isRunning == rhs.isRunning
            && lhs.hasSample == rhs.hasSample && lhs.wasSeen == rhs.wasSeen && lhs.processCount == rhs.processCount
            && lhs.isSystem == rhs.isSystem && lhs.canQuit == rhs.canQuit
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            AppIconView(appID: appID, bundlePath: bundlePath, size: 52)
                .saturation(isRunning || !hasSample ? 1 : 0.2)
                .opacity(isRunning || !hasSample ? 1 : 0.7)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(Typography.sheetTitle)
                    .foregroundStyle(Palette.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(identity)
                    .font(Typography.label)
                    .foregroundStyle(Palette.ink2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(identity)
                HStack(spacing: 6) {
                    if isRunning {
                        Pill(Format.processes(processCount), tint: Palette.accent, fontSize: 11)
                    } else if hasSample {
                        Pill(wasSeen ? "No longer running" : "Not running", symbol: "xmark.circle", tint: Palette.ink2, style: .neutral, fontSize: 11)
                    }
                    if isSystem {
                        Pill("System", tint: Palette.ink2, style: .neutral, fontSize: 11)
                    }
                }
                .padding(.top, 3)
            }
            .lineLimit(1)

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                Button("Quit", action: onQuit)
                    .buttonStyle(SoftButtonStyle())
                    .disabled(!canQuit)
                    .opacity(canQuit ? 1 : 0.45)
                    .help(canQuit ? "Quit \(name)" : "")
                Button("Force Quit", role: .destructive, action: onForceQuit)
                    .buttonStyle(SoftButtonStyle(tint: Palette.red))
                    .disabled(!canQuit)
                    .opacity(canQuit ? 1 : 0.45)
                    .help(canQuit ? "Force quit \(name), losing unsaved work" : "")
                Button("Done", action: onDone)
                    .buttonStyle(SoftButtonStyle(tint: .accentColor, prominent: true))
                    .keyboardShortcut(.defaultAction)
            }
            .lineLimit(1)
            .fixedSize()
            .background {
                Button("Close", action: onDone)
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
    }
}

/// CPU, Memory, Power, Disk, Network and GPU for the app right now.
struct InspectorFigureGrid: View, Equatable {
    let figures: [InspectorFigure]
    let isDimmed: Bool

    init(app: AppUsage?, snapshot: SystemSnapshot) {
        figures = Self.figures(app: app, snapshot: snapshot)
        isDimmed = app == nil
    }

    var body: some View {
        Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            ForEach(0..<2, id: \.self) { rowIndex in
                GridRow {
                    ForEach(figures[(rowIndex * 3)..<min(rowIndex * 3 + 3, figures.count)]) { figure in
                        InspectorFigureTile(figure: figure, isDimmed: isDimmed)
                    }
                }
            }
        }
    }

    private static func figures(app: AppUsage?, snapshot: SystemSnapshot) -> [InspectorFigure] {
        guard let app else {
            return [
                InspectorFigure(id: "cpu", label: "CPU", symbol: TallyTab.cpu.symbol, tint: Palette.accent, value: "—", detail: " "),
                InspectorFigure(id: "memory", label: "Memory", symbol: TallyTab.memory.symbol, tint: Palette.accent, value: "—", detail: " "),
                InspectorFigure(id: "power", label: "Power", symbol: Symbols.power, tint: Palette.accent, value: "—", detail: " "),
                InspectorFigure(id: "disk", label: "Disk", symbol: TallyTab.disk.symbol, tint: Palette.accent, value: "—", detail: " "),
                InspectorFigure(id: "network", label: "Network", symbol: TallyTab.network.symbol, tint: Palette.accent, value: "—", detail: " "),
                InspectorFigure(id: "gpu", label: "GPU", symbol: TallyTab.gpu.symbol, tint: Palette.accent, value: "—", detail: " "),
            ]
        }
        let threads = app.processes.reduce(0) { $0 + $1.threadCount }
        let cores = max(snapshot.cpu.logicalCores, 1)
        let memoryShare = snapshot.memory.totalBytes > 0 ? Double(app.memoryBytes) / Double(snapshot.memory.totalBytes) * 100 : 0
        let powerShare = snapshot.battery.powerDrawWatts > 0 ? app.powerWatts / snapshot.battery.powerDrawWatts * 100 : 0
        let diskTotal = app.diskReadBytesPerSecond + app.diskWriteBytesPerSecond
        let networkTotal = app.networkInBytesPerSecond + app.networkOutBytesPerSecond
        let machineShare = Format.percent(app.cpuPercent / Double(cores)).text
        return [
            InspectorFigure(
                id: "cpu", label: "CPU", symbol: TallyTab.cpu.symbol, tint: Palette.accent,
                value: MetricTabContent.appPercent(app.cpuPercent),
                detail: threads > 0 ? "\(Format.integer(Double(threads))) threads · \(machineShare) of Mac" : "\(machineShare) of the Mac"
            ),
            InspectorFigure(
                id: "memory", label: "Memory", symbol: TallyTab.memory.symbol, tint: Palette.accent,
                value: Format.memory(app.memoryBytes).text,
                detail: "\(Format.percent(memoryShare).text) of RAM"
            ),
            InspectorFigure(
                id: "power", label: "Power", symbol: Symbols.power, tint: Palette.accent,
                value: Format.power(app.powerWatts).text,
                detail: powerShare > 0 ? "\(Format.percent(min(powerShare, 100)).text) of the Mac's draw" : "Estimated"
            ),
            InspectorFigure(
                id: "disk", label: "Disk", symbol: TallyTab.disk.symbol, tint: Palette.accent,
                value: Format.rate(diskTotal).text,
                detail: "Read \(Format.rate(app.diskReadBytesPerSecond).text) · Write \(Format.rate(app.diskWriteBytesPerSecond).text)"
            ),
            InspectorFigure(
                id: "network", label: "Network", symbol: TallyTab.network.symbol, tint: Palette.accent,
                value: Format.rate(networkTotal).text,
                detail: "In \(Format.rate(app.networkInBytesPerSecond).text) · Out \(Format.rate(app.networkOutBytesPerSecond).text)"
            ),
            InspectorFigure(
                id: "gpu", label: "GPU", symbol: TallyTab.gpu.symbol, tint: Palette.accent,
                value: MetricTabContent.appPercent(app.gpuPercent),
                detail: "Of the GPU"
            ),
        ]
    }
}

struct InspectorFigure: Identifiable, Equatable {
    var id: String
    var label: String
    var symbol: String
    var tint: Color
    var value: String
    var detail: String
}

struct InspectorFigureTile: View {
    let figure: InspectorFigure
    let isDimmed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MetricTileHeader(symbol: figure.symbol, label: figure.label)
            Text(figure.value)
                .font(Typography.figure(Typography.tileFigureSize))
                .foregroundStyle(isDimmed ? Palette.ink2 : Palette.ink)
                .padding(.top, 8)
            Text(figure.detail)
                .font(Typography.tileSubtitle.monospacedDigit())
                .foregroundStyle(Palette.ink2)
                .padding(.top, 2)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .metricSurface()
        .accessibilityReading(figure.label, value: figure.detail.trimmingCharacters(in: .whitespaces).isEmpty ? figure.value : "\(figure.value), \(figure.detail)")
    }
}
