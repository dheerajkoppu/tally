import SwiftUI
import TallyCore

/// The memory pressure pill: a small symbol and a label on a faint tint.
struct OverviewPill: View, Equatable {
    private let content: OverviewPillContent

    init(_ content: OverviewPillContent) {
        self.content = content
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: content.symbol)
                .font(Typography.chevron)
                .accessibilityHidden(true)
            Text(content.text)
                .font(.system(size: 10.5, weight: .semibold))
        }
        .lineLimit(1)
        .foregroundStyle(LegibleTint(content.tint, wash: 0.14))
        .padding(.leading, 7)
        .padding(.trailing, 7.5)
        .frame(height: 16.5)
        .background(content.tint.opacity(0.14), in: Capsule())
        .fixedSize()
        .accessibilityReading("Memory pressure", value: content.text)
    }
}

/// A capsule button in a faint tint of its colour, readable on raised rows in light and dark.
struct OverviewTintedButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.compactButton)
            .foregroundStyle(LegibleTint(tint, on: Palette.raised, wash: 0.24))
            .padding(.horizontal, 12)
            .frame(height: 24)
            .background(tint.opacity(configuration.isPressed ? 0.24 : 0.14), in: Capsule())
            .controlOutline(Capsule())
            .contentShape(Capsule())
    }
}
