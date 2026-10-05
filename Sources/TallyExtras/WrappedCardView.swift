import SwiftUI
import TallyCore

/// Figures only Tally Wrapped shows.
enum WrappedText {
    /// Seconds of one core as "312 h", "4.5 h" or "45 min".
    static func cpuTime(_ seconds: Double) -> String {
        let hours = seconds / 3600
        if hours >= 10 { return "\(Format.integer(hours)) h" }
        if hours >= 1 { return String(format: "%.1f h", hours) }
        return "\(max(1, Int((seconds / 60).rounded()))) min"
    }

    /// "806 Wh", "1.2 kWh"
    static func energy(_ wattHours: Double) -> String {
        if wattHours >= 1000 { return String(format: "%.1f kWh", wattHours / 1000) }
        return String(format: wattHours >= 10 ? "%.0f Wh" : "%.1f Wh", wattHours)
    }

    /// "3 PM" or "15", as the Mac shows the time.
    static func hour(_ hour: Int) -> String {
        let date = Calendar.current.date(from: DateComponents(year: 2001, month: 1, day: 1, hour: hour)) ?? Date()
        return date.formatted(.dateTime.hour())
    }

    /// "Sep 24 – Dec 31, 2026"
    static func coverage(_ summary: YearSummary) -> String {
        let first = summary.firstDate.formatted(.dateTime.month(.abbreviated).day())
        let last = summary.lastDate.formatted(.dateTime.month(.abbreviated).day().year())
        return "\(first) – \(last)"
    }
}

/// The 1200 × 675 Tally Wrapped card: the year's hours by month, the apps that worked the Mac hardest and a few highlights.
struct WrappedCardView: View {
    static let size = CGSize(width: 1200, height: 675)

    @ObservedObject private var wrapped = WrappedModel.shared
    @ObservedObject private var store = TallyStore.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        ShareCanvas(size: Self.size, padding: EdgeInsets(top: 41, leading: 50, bottom: 30, trailing: 50)) {
            if let summary = wrapped.summary {
                VStack(alignment: .leading, spacing: 0) {
                    header(summary)
                        .padding(.bottom, 31)
                    HStack(alignment: .top, spacing: 35) {
                        hours(summary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        topApps(summary)
                            .frame(width: 428, height: 214)
                    }
                    .frame(height: 214)
                    .padding(.bottom, 30)
                    HStack(spacing: 35) {
                        highlights(summary)
                        standouts(summary)
                            .frame(width: 428)
                    }
                    .frame(height: 171)
                    .padding(.bottom, 17)
                    HStack {
                        Text(WrappedText.coverage(summary))
                        Spacer(minLength: 24)
                        Text(summary.appCount == 1 ? "1 app or tool" : "\(Format.integer(Double(summary.appCount))) apps and tools")
                    }
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.ink2)
                    .lineLimit(1)
                    .frame(height: 15)
                }
            } else {
                Text("Tally Wrapped arrives in December, once there is a week of history.")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Palette.ink2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func header(_ summary: YearSummary) -> some View {
        HStack(spacing: 0) {
            TallyLogoMark(size: 26)
                .padding(.trailing, 10)
            Text("Tally Wrapped")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .padding(.trailing, 7)
            Text(String(summary.year))
                .font(.system(size: 15))
                .foregroundStyle(Palette.ink2)
            Spacer(minLength: 24)
            Text("\(MachineInfo.model(store.snapshot)) · \(MachineInfo.specs(store.snapshot))")
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.ink2)
        }
        .lineLimit(1)
        .frame(height: 26)
    }

    private func hours(_ summary: YearSummary) -> some View {
        let months = Calendar.current.veryShortMonthSymbols
        return VStack(alignment: .leading, spacing: 0) {
            ShareCapsLabel("Awake with Tally")
                .frame(height: 17)
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(Format.integer(summary.activeSeconds / 3600))
                    .font(.system(size: 70, weight: .bold).monospacedDigit())
                    .tracking(-1.75)
                    .foregroundStyle(Palette.ink)
                Text("hours")
                    .font(.system(size: 45, weight: .semibold))
                    .foregroundStyle(Palette.shareUnit)
                    .padding(.leading, 9)
                Text(summary.activeDays == 1 ? "on 1 day" : "over \(summary.activeDays) days")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Palette.ink2)
                    .padding(.leading, 15)
            }
            .lineLimit(1)
            .padding(.top, -3)
            ShareBarChart(slots: summary.monthlyHours.map { $0 > 0 ? $0 : nil }, maxValue: summary.monthlyHours.max() ?? 0, tint: Palette.accent, barWidth: 14)
                .frame(height: 64)
                .padding(.top, 12)
            HStack(spacing: 0) {
                ForEach(Array(months.enumerated()), id: \.offset) { _, month in
                    Text(month)
                        .frame(maxWidth: .infinity)
                }
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Palette.ink3)
            .padding(.top, 6)
        }
    }

    private func topApps(_ summary: YearSummary) -> some View {
        let largest = summary.topByCPU.first?.value ?? 0
        return ShareInset(padding: EdgeInsets(top: 15, leading: 18, bottom: 12, trailing: 19)) {
            VStack(alignment: .leading, spacing: 0) {
                ShareCapsLabel("Top apps by CPU time")
                    .frame(height: 12)
                    .padding(.bottom, 6)
                ForEach(summary.topByCPU) { app in
                    HStack(spacing: 0) {
                        AppIconView(appID: app.appID, bundlePath: app.bundlePath, size: 20)
                        Text(app.name)
                            .font(.system(size: 14))
                            .foregroundStyle(Palette.ink)
                            .padding(.leading, 12)
                        Spacer(minLength: 12)
                        ShareMeter(fraction: largest > 0 ? app.value / largest : 0, tint: Palette.accent)
                            .frame(width: 87, height: 4)
                        Text(WrappedText.cpuTime(app.value))
                            .font(.system(size: 14, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Palette.ink)
                            .frame(width: 80, alignment: .trailing)
                            .padding(.leading, 14)
                    }
                    .lineLimit(1)
                    .frame(height: 33.8)
                }
            }
        }
    }

    private func highlights(_ summary: YearSummary) -> some View {
        let busiestDay = summary.busiestDay.map { $0.formatted(.dateTime.month(.abbreviated).day()) }
        return ShareInset(padding: EdgeInsets(top: 17, leading: 19.5, bottom: 16.5, trailing: 19)) {
            VStack(alignment: .leading, spacing: 13) {
                ShareCapsLabel("Highlights")
                    .frame(height: 12)
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 13) {
                    GridRow {
                        stat("Downloaded", Format.total(summary.networkInBytes).text)
                        stat("Uploaded", Format.total(summary.networkOutBytes).text)
                        stat("Written to disk", Format.total(summary.diskWrittenBytes).text)
                    }
                    GridRow {
                        stat("Busiest day", busiestDay ?? "–")
                        stat("Busiest hour", summary.busiestHour.map(WrappedText.hour) ?? "–")
                        if let hottest = summary.hottestCelsius {
                            stat("Hottest CPU", Format.temperature(hottest, unit: settings.temperatureUnit).text)
                        } else {
                            stat("Average CPU", Format.percent(summary.cpuAverage).text)
                        }
                    }
                }
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.ink2)
            Text(value)
                .font(.system(size: 22, weight: .bold).monospacedDigit())
                .foregroundStyle(Palette.ink)
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func standouts(_ summary: YearSummary) -> some View {
        ShareInset(padding: EdgeInsets(top: 17, leading: 18, bottom: 12, trailing: 19)) {
            VStack(alignment: .leading, spacing: 0) {
                ShareCapsLabel("Also on top")
                    .frame(height: 12)
                    .padding(.bottom, 6)
                if let app = summary.topByMemory {
                    standout("Most memory", app, Format.memory(UInt64(app.value)).text)
                }
                if let app = summary.topByNetwork {
                    standout("Most data", app, Format.total(UInt64(app.value)).text)
                }
                if let app = summary.topByEnergy {
                    standout("Most energy", app, WrappedText.energy(app.value))
                }
            }
        }
    }

    private func standout(_ label: String, _ app: HistoryAppTotal, _ value: String) -> some View {
        HStack(spacing: 0) {
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.ink2)
                .frame(width: 92, alignment: .leading)
            AppIconView(appID: app.appID, bundlePath: app.bundlePath, size: 20)
            Text(app.name)
                .font(.system(size: 14))
                .foregroundStyle(Palette.ink)
                .padding(.leading, 12)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 14, weight: .semibold).monospacedDigit())
                .foregroundStyle(Palette.ink)
        }
        .lineLimit(1)
        .frame(height: 33.8)
    }
}
