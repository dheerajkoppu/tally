import SwiftUI
import TallyCore

/// Every fan as a dial with its speed. Opens the Sensors tab, where the fans are controlled.
struct OverviewFansCard: View, Equatable {
    let fans: [OverviewFanContent]

    var body: some View {
        Button {
            AppRouter.shared.tab = .sensors
        } label: {
            Card {
                VStack(alignment: .leading, spacing: 0) {
                    CardHeader(fans.count == 1 ? "Fan" : "Fans", symbol: Symbols.fan, showsChevron: true)
                    Spacer(minLength: 12)
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(fans) { fan in
                            VStack(spacing: 6) {
                                FanGauge(fraction: fan.fraction)
                                    .frame(width: 64, height: 64)
                                VStack(spacing: 1) {
                                    Text(fan.speed)
                                        .font(Typography.statValue)
                                        .foregroundStyle(Palette.ink)
                                    Text(fan.name)
                                        .font(Typography.statLabel)
                                        .foregroundStyle(Palette.ink2)
                                }
                                .lineLimit(1)
                            }
                            .frame(maxWidth: 120)
                        }
                        Spacer(minLength: 0)
                    }
                    Spacer(minLength: 12)
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .buttonStyle(OverviewCardButtonStyle(cornerRadius: Metrics.cardRadius))
        .help("Show temperatures and fan control")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(fans.count == 1 ? "Fan" : "Fans")
        .accessibilityValue(fans.map { "\($0.name) \($0.speed)" }.joined(separator: ", "))
        .accessibilityHint("Opens the Sensors tab")
        .accessibilityAddTraits(.isButton)
    }
}

/// AirPods, mouse and keyboard batteries as tiles that fill with the charge left.
struct OverviewDevicesCard: View, Equatable {
    let devices: [OverviewDeviceContent]

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                CardHeader("Devices", symbol: "dot.radiowaves.left.and.right")
                Spacer(minLength: 12)
                HStack(alignment: .top, spacing: 10) {
                    ForEach(devices.prefix(6)) { device in
                        VStack(spacing: 6) {
                            LevelTile(level: device.level, symbol: device.symbol, tint: device.isLow ? Palette.red : Palette.accent)
                                .frame(height: 64)
                            VStack(spacing: 1) {
                                Text(device.percent)
                                    .font(Typography.statValue)
                                    .foregroundStyle(Palette.ink)
                                Text(device.name)
                                    .font(Typography.statLabel)
                                    .foregroundStyle(Palette.ink2)
                                    .truncationMode(.tail)
                            }
                            .lineLimit(1)
                        }
                        .frame(maxWidth: 120)
                        .help(device.name)
                        .accessibilityReading("\(device.name) battery", value: device.percent)
                    }
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 12)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Devices")
    }
}
