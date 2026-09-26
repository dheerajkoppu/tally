import SwiftUI
import TallyCore

struct WelcomeFeature {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String

    static let all: [WelcomeFeature] = [
        WelcomeFeature(symbol: Symbols.apps, tint: Palette.accent, title: "Apps, not processes", detail: "Helper processes add up under the app they work for."),
        WelcomeFeature(symbol: "clock.arrow.circlepath", tint: Palette.memory, title: "30 days of history", detail: "Scroll back a month to see what was busy and which apps were responsible."),
        WelcomeFeature(symbol: "bell.badge", tint: Palette.red, title: "Alerts for runaway apps", detail: "Heavy CPU, steadily growing memory, or lots of disk activity."),
        WelcomeFeature(symbol: "menubar.rectangle", tint: Palette.cpu, title: "Right in the menu bar", detail: "Pick an icon, a number or a graph. Everything else is one click away."),
        WelcomeFeature(symbol: TallyTab.projects.symbol, tint: Palette.projects, title: "Dev servers, by project", detail: "Listening ports grouped by folder, and idle servers pointed out."),
        WelcomeFeature(symbol: Symbols.temperature, tint: Palette.network, title: "Temperatures, fans and volume", detail: "Sensors, AirPods batteries, and a volume slider for each app."),
    ]
}

struct WelcomeFeatureTile: View {
    let feature: WelcomeFeature

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IconBadge(feature.symbol, tint: feature.tint, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(feature.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text(feature.detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.ink2)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 68, alignment: .topLeading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
