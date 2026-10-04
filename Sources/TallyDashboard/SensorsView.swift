import SwiftUI
import TallyCore

/// The Sensors tab: CPU and GPU temperature with their recent history, the fans, every temperature this Mac reports,
/// and the batteries of connected devices. The fan controls come from the app target, which owns the fan helper.
public struct SensorsView<FanControls: View>: View {
    @ObservedObject private var store = TallyStore.shared
    @ObservedObject private var settings = AppSettings.shared
    private let fanControls: FanControls

    public init(@ViewBuilder fanControls: () -> FanControls) {
        self.fanControls = fanControls()
    }

    public var body: some View {
        let sensors = store.snapshot.sensors
        let unit = settings.temperatureUnit
        let headline = SensorHeadline.all(sensors: sensors, live: store.live, unit: unit)
        let readings = SensorRow.all(sensors.temperatures, unit: unit)
        let devices = OverviewContent.deviceContent(sensors.peripheralBatteries)
        VStack(alignment: .leading, spacing: Metrics.gridSpacing) {
            if !headline.isEmpty {
                OverviewCardGrid(spacing: Metrics.gridSpacing, minimumColumnWidth: 280, maximumColumns: 2) {
                    ForEach(headline) { content in
                        SensorHeadlineCard(content: content).equatable()
                    }
                }
            }
            fanControls
            if !readings.isEmpty {
                SensorListCard(rows: readings).equatable()
            }
            if !devices.isEmpty {
                OverviewDevicesCard(devices: devices).equatable()
            }
            if store.hasSample, headline.isEmpty, readings.isEmpty {
                SensorsEmptyCard()
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// CPU or GPU temperature: the reading, how warm that is, and the last few minutes.
struct SensorHeadline: Identifiable, Equatable {
    var id: String
    var title: String
    var figure: Figure
    var range: TemperatureRange
    var level: Double
    var stats: [OverviewStatContent]
    var bars: [Double]
    var spokenSummary: String

    @MainActor
    static func all(sensors: SensorStats, live: LiveSeries, unit: TemperatureUnit) -> [SensorHeadline] {
        [
            headline(id: "cpu", title: "CPU", celsius: sensors.cpuTemperatureCelsius, series: live.cpuTemperature, unit: unit),
            headline(id: "gpu", title: "GPU", celsius: sensors.gpuTemperatureCelsius, series: live.gpuTemperature, unit: unit),
        ]
        .compactMap { $0 }
    }

    @MainActor
    private static func headline(id: String, title: String, celsius: Double?, series: [Double], unit: TemperatureUnit) -> SensorHeadline? {
        guard let celsius, celsius > 0 else { return nil }
        func text(_ value: Double?) -> String {
            value.map { Format.temperature($0, unit: unit).text } ?? OverviewContent.placeholder
        }
        let recent = series.suffix(OverviewContent.sparklineCount)
        let measured = recent.filter { $0 > 0 }
        let average = measured.isEmpty ? nil : measured.reduce(0, +) / Double(measured.count)
        let range = TemperatureRange(celsius: celsius)
        let stats = [
            OverviewStatContent(label: "Lowest", value: text(measured.min())),
            OverviewStatContent(label: "Average", value: text(average)),
            OverviewStatContent(label: "Peak", value: text(measured.max())),
        ]
        return SensorHeadline(
            id: id,
            title: title,
            figure: Format.temperature(celsius, unit: unit),
            range: range,
            level: TemperatureRange.level(celsius),
            stats: stats,
            bars: OverviewContent.bars(Array(recent), top: TemperatureRange.scaleTop),
            spokenSummary: "\(text(celsius)), \(range.label.lowercased()). " + stats.map { "\($0.label) \($0.value)" }.joined(separator: ", ")
        )
    }
}

struct SensorHeadlineCard: View, Equatable {
    let content: SensorHeadline

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                CardHeader("\(content.title) Temperature", symbol: Symbols.temperature)
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 7) {
                        BigFigure(content.figure, size: Typography.heroFigureSize)
                        Chip("Range", value: content.range.label, dot: content.range.statusTint)
                    }
                    Spacer(minLength: 0)
                    ThermometerGlyph(level: content.level, tint: content.range.tint)
                        .frame(width: 44, height: 66)
                }
                .padding(.top, 8)
                OverviewCardGrid(spacing: 12, minimumColumnWidth: 0, maximumColumns: content.stats.count) {
                    ForEach(content.stats) { stat in
                        StatColumn(stat.label, value: stat.value)
                    }
                }
                .padding(.top, 12)
                BarSparkline(content.bars, tint: content.range.tint, maxValue: 1)
                    .frame(height: 40)
                    .padding(.top, 12)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(content.title) temperature")
        .accessibilityValue(content.spokenSummary)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// One temperature reading in the full list.
struct SensorRow: Identifiable, Equatable {
    var id: String
    var name: String
    var value: String
    var level: Double
    var isHot: Bool

    static func all(_ readings: [TemperatureReading], unit: TemperatureUnit) -> [SensorRow] {
        readings.filter { $0.celsius > 0 }.map { reading in
            SensorRow(
                id: reading.id,
                name: reading.name,
                value: Format.temperature(reading.celsius, unit: unit).text,
                level: (TemperatureRange.level(reading.celsius) * 100).rounded() / 100,
                isHot: TemperatureRange(celsius: reading.celsius) == .high
            )
        }
    }
}

/// Every temperature this Mac reports, in two columns, each with a meter from room temperature to the hottest a chip runs.
struct SensorListCard: View, Equatable {
    let rows: [SensorRow]

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    CardHeader("All Temperatures", symbol: "list.bullet")
                    Text(rows.count == 1 ? "1 sensor" : "\(rows.count) sensors")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.ink2)
                        .fixedSize()
                }
                OverviewCardGrid(spacing: 0, minimumColumnWidth: 300, maximumColumns: 2, columnSpacing: 28) {
                    ForEach(rows) { row in
                        HStack(spacing: 12) {
                            Text(row.name)
                                .font(Typography.tableText)
                                .foregroundStyle(Palette.ink)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Meter(row.level, tint: row.isHot ? Palette.red : Palette.accent, height: 5)
                                .frame(width: 110)
                            Text(row.value)
                                .font(Typography.tableValue)
                                .foregroundStyle(Palette.ink)
                                .frame(width: 44, alignment: .trailing)
                        }
                        .frame(height: 30)
                        .accessibilityReading(row.name, value: row.value)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("All temperatures")
    }
}

/// Shown on Macs that report no temperatures.
private struct SensorsEmptyCard: View {
    var body: some View {
        Card {
            VStack(spacing: 4) {
                Text("No temperature sensors")
                    .font(Typography.largeEmptyTitle)
                    .foregroundStyle(Palette.ink)
                Text("This Mac does not report its temperatures to apps.")
                    .font(Typography.body)
                    .foregroundStyle(Palette.ink2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
        }
        .accessibilityElement(children: .combine)
    }
}
