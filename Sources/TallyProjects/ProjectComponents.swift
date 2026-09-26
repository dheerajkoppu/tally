import SwiftUI
import TallyCore

/// The small capsules on a project row: ports in the projects tint, "working" in green, idle time in grey.
struct ProjectPill: View {
    enum Style {
        case tinted(Color)
        case neutral
    }

    let text: String
    var symbol: String?
    let style: Style

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol).font(Typography.chevron)
            }
            Text(text).font(Typography.pill).monospacedDigit()
        }
        .lineLimit(1)
        .foregroundStyle(foreground)
        .padding(.horizontal, 9)
        .padding(.vertical, 2)
        .background(background, in: Capsule())
        .fixedSize()
    }

    private var foreground: AnyShapeStyle {
        switch style {
        case .tinted(let tint): AnyShapeStyle(LegibleTint(tint, wash: 0.14))
        case .neutral: AnyShapeStyle(Palette.ink2)
        }
    }

    private var background: Color {
        switch style {
        case .tinted(let tint): tint.opacity(0.14)
        case .neutral: Palette.cardHighlight
        }
    }
}

/// The tinted square beside each project, with the finer glyph the Projects design uses.
struct ProjectBadge: View {
    let symbol: String
    var size: CGFloat = Metrics.badgeSize
    var tint: Color = Palette.projects

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.41, weight: .medium))
            .foregroundStyle(LegibleTint(tint, wash: 0.16))
            .frame(width: size, height: size)
            .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: size * 0.32, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct PortPill: View {
    let port: Int

    var body: some View {
        ProjectPill(text: String(port), style: .tinted(Palette.projects))
    }
}

struct StatusPill: View {
    let activity: DevActivity
    let now: Date

    var body: some View {
        if let pill = ProjectStatus.pill(for: activity, now: now) {
            ProjectPill(text: pill.text, symbol: pill.symbol, style: pill.working ? .tinted(Palette.battery) : .neutral)
        }
    }
}

/// "4 dev servers are running but idle", with what stopping them frees and a Stop All button.
struct IdleServersBanner: View {
    let projects: [Project]
    let onStopAll: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ProjectBadge(symbol: Symbols.moon)
            VStack(alignment: .leading, spacing: ProjectLayout.titleSpacing) {
                Text(title)
                    .font(Typography.rowTitle)
                    .foregroundStyle(Palette.ink)
                Text(detail)
                    .font(Typography.label)
                    .foregroundStyle(Palette.ink2)
            }
            .lineLimit(1)
            .accessibilityElement(children: .combine)
            Spacer(minLength: 12)
            Button("Stop All", action: onStopAll)
                .buttonStyle(ProjectButtonStyle(tint: Palette.projects, prominent: true))
                .help("Stop every idle dev server, after a confirmation")
        }
        .padding(.horizontal, 12)
        .frame(height: ProjectLayout.bannerHeight)
        .background(Palette.projects.opacity(0.11), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var title: String {
        projects.count == 1 ? "1 dev server is running but idle" : "\(projects.count) dev servers are running but idle"
    }

    private var detail: String {
        let memory = Format.memory(projects.reduce(0) { $0 + $1.memoryBytes }).text
        let ports = Array(Set(projects.flatMap(\.ports))).sorted()
        let pronoun = projects.count == 1 ? "it" : "them"
        return "Stopping \(pronoun) frees \(memory) and \(ProjectText.ports(ports))."
    }
}

/// "4 servers stopped." and what that freed, in place of the idle banner for a few seconds after a stop.
struct StoppedServersBanner: View {
    let result: ProjectStopTracker.Result

    var body: some View {
        HStack(spacing: 12) {
            ProjectBadge(symbol: Symbols.check, tint: Palette.battery)
            VStack(alignment: .leading, spacing: ProjectLayout.titleSpacing) {
                Text(result.title)
                    .font(Typography.rowTitle)
                    .foregroundStyle(Palette.ink)
                Text(result.detail)
                    .font(Typography.label)
                    .foregroundStyle(Palette.ink2)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: ProjectLayout.bannerHeight)
        .background(Palette.battery.opacity(0.11), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Row and banner sizes, as tight as the Projects tab in the Tally launch video.
enum ProjectLayout {
    static let rowHeight: CGFloat = 50
    static let bannerHeight: CGFloat = 49
    /// Between a row's title and its subtitle.
    static let titleSpacing: CGFloat = 1
}

/// Shown when nothing is running, or before the first scan.
struct ProjectsEmptyState: View {
    let isScanning: Bool

    var body: some View {
        VStack(spacing: 0) {
            ProjectBadge(symbol: isScanning ? "magnifyingglass" : "folder", size: 44)
                .padding(.bottom, 14)
            Text(isScanning ? "Looking for dev servers…" : "No dev servers running")
                .font(Typography.largeEmptyTitle)
                .foregroundStyle(Palette.ink)
                .padding(.bottom, 6)
            Text("Dev servers and anything listening on a port appear here, sorted into the project folder each one runs from.")
                .font(Typography.body)
                .foregroundStyle(Palette.ink2)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .frame(maxWidth: 340)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 64)
        .accessibilityElement(children: .combine)
    }
}

/// A capsule button that stays visible on both the card and the raised process list, in light and dark.
struct ProjectButtonStyle: ButtonStyle {
    var tint: Color?
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        ProjectButtonBody(configuration: configuration, tint: tint, prominent: prominent)
    }
}

private struct ProjectButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let tint: Color?
    let prominent: Bool
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(Typography.compactButton)
            .foregroundStyle(foreground)
            .padding(.horizontal, 12)
            .padding(.vertical, 5.5)
            .background {
                if prominent {
                    Capsule().fill(LegibleTint(tint ?? Palette.accent, on: .white))
                } else {
                    Capsule().fill(Palette.ink.opacity(contrast == .increased ? 0.15 : 0.075))
                }
            }
            .controlOutline(Capsule())
            .opacity(configuration.isPressed ? 0.7 : (isEnabled ? 1 : 0.5))
            .contentShape(Capsule())
    }

    /// Tinted text is measured against the grey capsule, a little darker than the card it sits on.
    private var foreground: AnyShapeStyle {
        if prominent { return AnyShapeStyle(Color.white) }
        guard let tint else { return AnyShapeStyle(Palette.ink) }
        return AnyShapeStyle(LegibleTint(tint, on: Palette.cardHighlight))
    }
}

/// A faint highlight under the pointer, for rows that expand on click.
struct HoverRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverRowBody(configuration: configuration)
    }
}

private struct HoverRowBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Palette.ink.opacity(configuration.isPressed ? 0.06 : (isHovered ? 0.035 : 0)))
            }
            .onHover { isHovered = $0 }
    }
}
