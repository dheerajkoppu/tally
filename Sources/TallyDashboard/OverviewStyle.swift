import SwiftUI
import TallyCore

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
