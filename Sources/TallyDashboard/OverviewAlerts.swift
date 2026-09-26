import SwiftUI
import TallyCore

/// "Worth a Look": apps that have been misbehaving, each with Inspect and Dismiss.
struct OverviewAlertsCard: View, Equatable {
    let alerts: [OverviewAlertContent]

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 9) {
                    CardHeader("Worth a Look", symbol: "exclamationmark.triangle", tint: Palette.disk)
                    Text(alerts.count == 1 ? "1 app" : "\(alerts.count) apps")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.ink2)
                        .fixedSize()
                }
                VStack(spacing: 8) {
                    ForEach(alerts) { alert in
                        OverviewAlertRow(content: alert)
                            .transition(.opacity)
                    }
                }
            }
        }
        .transition(.opacity)
    }
}

private struct OverviewAlertRow: View {
    let content: OverviewAlertContent

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let alert = content.alert
        let tab = content.tab
        HStack(spacing: 12) {
            AppIconView(appID: alert.appID, bundlePath: alert.bundlePath, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(alert.title)
                    .font(Typography.bodyEmphasis)
                    .foregroundStyle(Palette.ink)
                HStack(spacing: 5) {
                    Image(systemName: alert.kind.symbol)
                        .font(Typography.inlineSymbol)
                        .foregroundStyle(tab.tint)
                    Text(alert.detail)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.ink2)
                }
            }
            .lineLimit(1)
            .layoutPriority(1)
            Spacer(minLength: 12)
            Text(content.age)
                .font(Typography.caption)
                .foregroundStyle(Palette.ink2)
                .lineLimit(1)
                .fixedSize()
            Button("Inspect", action: inspect)
                .buttonStyle(OverviewTintedButtonStyle(tint: tab.tint))
                .fixedSize()
                .help("Show \(alert.appName) in \(tab.title)")
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(Typography.chevron.weight(.bold))
                    .foregroundStyle(Palette.ink2)
                    .frame(width: 22, height: 22)
                    .background(Palette.ink.opacity(0.07), in: Circle())
                    .controlOutline(Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(Palette.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(alert.title)
        .accessibilityValue(alert.detail.hasSuffix(".") ? "\(alert.detail) \(content.age)" : "\(alert.detail), \(content.age)")
        .accessibilityHint("Shows \(alert.appName) in \(tab.title)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { inspect() }
        // Listed last to first: SwiftUI hands custom actions to VoiceOver in reverse order.
        .accessibilityActions {
            Button("Dismiss", action: dismiss)
            Button("Inspect", action: inspect)
        }
    }

    private func inspect() {
        AppRouter.shared.open(content.tab, inspecting: content.alert.appID)
    }

    private func dismiss() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
            TallyStore.shared.dismiss(content.alert)
        }
    }
}
