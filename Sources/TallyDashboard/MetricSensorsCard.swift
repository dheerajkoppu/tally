import SwiftUI
import TallyCore

/// CPU and GPU temperature, fan speeds and peripheral batteries, on the Battery tab. Fan tiles open fan control.
struct MetricSensorsCard: View, Equatable {
    let readings: [MetricSensorReading]
    let temperatureHelp: String

    init(sensors: SensorStats, unit: TemperatureUnit) {
        readings = Self.readings(sensors, unit: unit)
        let hottest = sensors.temperatures.sorted { $0.celsius > $1.celsius }.prefix(6)
        temperatureHelp = hottest.map { "\($0.name): \(Format.temperature($0.celsius, unit: unit).text)" }.joined(separator: "\n")
    }

    static func hasContent(_ sensors: SensorStats) -> Bool {
        sensors.cpuTemperatureCelsius != nil || sensors.gpuTemperatureCelsius != nil || !sensors.fans.isEmpty || !sensors.peripheralBatteries.isEmpty
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                CardHeader("Temperatures & Fans", symbol: Symbols.temperature, tint: Palette.red)
                    .accessibilityAddTraits(.isHeader)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 118, maximum: 200), spacing: 10, alignment: .leading)], alignment: .leading, spacing: 10) {
                    ForEach(readings) { reading in
                        if reading.isFan {
                            Button {
                                AppRouter.shared.isFanControlPresented = true
                            } label: {
                                MetricSensorTile(reading: reading, showsChevron: true)
                            }
                            .buttonStyle(.plain)
                            .contentShape(.focusEffect, RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .help("Fan Control…")
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(reading.accessibilityLabel)
                            .accessibilityValue(reading.accessibilityValue)
                            .accessibilityHint("Opens fan control")
                            .accessibilityAddTraits(.isButton)
                        } else {
                            MetricSensorTile(reading: reading, showsChevron: false)
                                .help(reading.id == "cpu" || reading.id == "gpu" ? temperatureHelp : "")
                                .accessibilityReading(reading.accessibilityLabel, value: reading.accessibilityValue)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Temperatures and fans")
    }

    private static func readings(_ sensors: SensorStats, unit: TemperatureUnit) -> [MetricSensorReading] {
        var result: [MetricSensorReading] = []
        if let cpu = sensors.cpuTemperatureCelsius {
            result.append(MetricSensorReading(id: "cpu", symbol: Symbols.temperature, tint: Palette.red, value: Format.temperature(cpu, unit: unit).text, caption: "CPU"))
        }
        if let gpu = sensors.gpuTemperatureCelsius {
            result.append(MetricSensorReading(id: "gpu", symbol: Symbols.temperature, tint: Palette.red, value: Format.temperature(gpu, unit: unit).text, caption: "GPU"))
        }
        for fan in sensors.fans {
            let name = sensors.fans.count > 1 ? fan.name : "Fan"
            let isSpinning = fan.rpm >= 1
            result.append(MetricSensorReading(
                id: "fan-\(fan.id)",
                symbol: Symbols.fan,
                tint: Palette.cpu,
                value: isSpinning ? Format.integer((fan.rpm / 10).rounded() * 10) : "Off",
                caption: isSpinning ? "\(name), rpm" : name,
                isFan: true
            ))
        }
        for peripheral in sensors.peripheralBatteries {
            let tint = peripheral.percent <= 20 ? Palette.red : Palette.battery
            result.append(MetricSensorReading(id: "peripheral-\(peripheral.id)", symbol: peripheral.kind.symbol, tint: tint, value: Format.percent(peripheral.percent).text, caption: peripheral.name))
        }
        return result
    }
}

struct MetricSensorReading: Identifiable, Equatable {
    var id: String
    var symbol: String
    var tint: Color
    var value: String
    var caption: String
    var isFan = false

    var accessibilityLabel: String {
        isFan ? caption.replacingOccurrences(of: ", rpm", with: "") : caption
    }

    var accessibilityValue: String {
        isFan && value != "Off" ? "\(value) rpm" : value
    }
}

struct MetricSensorTile: View {
    let reading: MetricSensorReading
    let showsChevron: Bool

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                IconBadge(reading.symbol, tint: reading.tint, size: 20)
                Spacer(minLength: 0)
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(Typography.chevron)
                        .foregroundStyle(isHovered ? Palette.ink2 : Palette.ink3)
                }
            }
            Text(reading.value)
                .font(Typography.figure(Typography.compactFigureSize))
                .foregroundStyle(Palette.ink)
                .padding(.top, 8)
            Text(reading.caption)
                .font(Typography.tileSubtitle)
                .foregroundStyle(Palette.ink2)
                .padding(.top, 1)
        }
        .lineLimit(1)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .metricSurface(isHovered && showsChevron ? Palette.cardHighlight : Palette.raised, radius: 12)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { hovering in
            if showsChevron { isHovered = hovering }
        }
    }
}
