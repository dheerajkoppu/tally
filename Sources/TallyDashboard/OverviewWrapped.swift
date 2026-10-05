import SwiftUI
import TallyCore

/// The invitation to Tally Wrapped at the top of Overview through December and January, until it is dismissed.
struct OverviewWrappedCard: View, Equatable {
    let year: Int
    let hours: Int
    let apps: Int

    var body: some View {
        Card {
            HStack(spacing: 12) {
                IconBadge("sparkles", tint: Palette.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Tally Wrapped \(String(year))")
                        .font(Typography.bodyEmphasis)
                        .foregroundStyle(Palette.ink)
                    Text("Your Mac's year: \(Format.integer(Double(hours))) hours awake, \(Format.integer(Double(apps))) apps and the ones that worked it hardest.")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.ink2)
                }
                .lineLimit(1)
                .layoutPriority(1)
                Spacer(minLength: 12)
                Button("View") { AppRouter.shared.isWrappedPresented = true }
                    .buttonStyle(OverviewTintedButtonStyle(tint: Palette.accent))
                    .fixedSize()
                    .help("See your Mac's year and save it as an image")
                Button {
                    AppSettings.shared.dismissedWrappedYear = year
                } label: {
                    Image(systemName: "xmark")
                        .font(Typography.chevron.weight(.bold))
                        .foregroundStyle(Palette.ink2)
                        .frame(width: 22, height: 22)
                        .background(Palette.ink.opacity(0.07), in: Circle())
                        .controlOutline(Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Dismiss. Tally Wrapped stays in the File menu.")
                .accessibilityLabel("Dismiss")
            }
        }
    }
}
