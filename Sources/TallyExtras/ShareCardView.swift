import SwiftUI
import Darwin
import TallyCore

/// The Mac's model and specs, from the snapshot with sysctl and ProcessInfo as fallbacks.
enum MachineInfo {
    static let chipFallback: String = {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 1 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else { return "" }
        return String(cString: buffer)
    }()

    /// "Apple M4 Pro"
    static func fullChip(_ snapshot: SystemSnapshot) -> String {
        snapshot.cpu.chipName.isEmpty ? chipFallback : snapshot.cpu.chipName
    }

    /// "M4 Pro"
    static func chip(_ snapshot: SystemSnapshot) -> String {
        let name = fullChip(snapshot)
        return name.hasPrefix("Apple ") ? String(name.dropFirst(6)) : name
    }

    /// "MacBook Pro"
    static func model(_ snapshot: SystemSnapshot) -> String {
        snapshot.machineName.isEmpty ? "Mac" : snapshot.machineName
    }

    /// "24 GB", the installed memory.
    static func installedMemory(_ snapshot: SystemSnapshot) -> String {
        let bytes = snapshot.memory.totalBytes > 0 ? snapshot.memory.totalBytes : ProcessInfo.processInfo.physicalMemory
        return String(format: "%.0f GB", Double(bytes) / 1_073_741_824)
    }

    /// "Apple M4 Pro · 12 cores · 24 GB"
    static func specs(_ snapshot: SystemSnapshot) -> String {
        let cores = snapshot.cpu.logicalCores > 0 ? snapshot.cpu.logicalCores : ProcessInfo.processInfo.activeProcessorCount
        return [fullChip(snapshot), "\(cores) cores", installedMemory(snapshot)]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

/// The logo, "Tally" and the Mac's model at the left; chip, cores and memory at the right.
struct ShareHeader: View {
    let snapshot: SystemSnapshot
    var logoSize: CGFloat = 26

    var body: some View {
        HStack(spacing: 0) {
            TallyLogoMark(size: logoSize)
                .padding(.trailing, 10)
            Text("Tally")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .padding(.trailing, 7)
            Text(MachineInfo.model(snapshot))
                .font(.system(size: 15))
                .foregroundStyle(Palette.ink2)
            Spacer(minLength: 24)
            Text(MachineInfo.specs(snapshot))
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.ink2)
        }
        .lineLimit(1)
        .frame(height: logoSize)
    }
}

/// Process and app counts at the left, the date at the right.
struct ShareFooter: View {
    let processes: Int
    let apps: Int
    let date: String

    var body: some View {
        HStack {
            Text(ShareText.grouping(processes: processes, apps: apps))
            Spacer(minLength: 24)
            Text(date)
        }
        .font(.system(size: 12.5))
        .foregroundStyle(Palette.ink2)
        .lineLimit(1)
        .frame(height: 15)
    }
}

/// The 1200 × 675 share card: memory in use, the top apps by memory and the last five minutes of CPU.
struct ShareCardView: View {
    static let size = CGSize(width: 1200, height: 675)
    static let cpuSlots = 60

    @ObservedObject private var store = TallyStore.shared
    let date: Date

    init(date: Date = Date()) {
        self.date = date
    }

    var body: some View {
        let snapshot = store.snapshot
        ShareCanvas(size: Self.size, padding: EdgeInsets(top: 41, leading: 50, bottom: 30, trailing: 50)) {
            VStack(alignment: .leading, spacing: 0) {
                ShareHeader(snapshot: snapshot)
                    .padding(.bottom, 31)
                HStack(alignment: .top, spacing: 35) {
                    memory(snapshot)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    topApps
                        .frame(width: 428, height: 214)
                }
                .padding(.bottom, 30)
                cpu(snapshot)
                    .frame(height: 171)
                    .padding(.bottom, 17)
                ShareFooter(processes: store.processCount, apps: store.apps.count, date: date.formatted(date: .abbreviated, time: .omitted))
            }
        }
    }

    private func memory(_ snapshot: SystemSnapshot) -> some View {
        let memory = snapshot.memory
        let used = Format.memory(memory.usedBytes)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ShareCapsLabel("Memory in use")
                SharePressureTag(pressure: memory.pressure)
            }
            .frame(height: 17)
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(used.value)
                    .font(.system(size: 70, weight: .bold).monospacedDigit())
                    .tracking(-1.75)
                    .foregroundStyle(Palette.ink)
                Text(used.unit)
                    .font(.system(size: 45, weight: .semibold))
                    .foregroundStyle(Palette.shareUnit)
                    .padding(.leading, 9)
                Text("of \(MachineInfo.installedMemory(snapshot))")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Palette.ink2)
                    .padding(.leading, 15)
            }
            .lineLimit(1)
            .padding(.top, -3)
            ShareMemoryBar(memory: memory)
                .frame(height: 14)
                .padding(.top, 11)
            HStack(spacing: 18) {
                ShareLegendItem(color: Palette.memoryApp, label: "App", value: Format.memory(memory.appBytes).text)
                ShareLegendItem(color: Palette.memoryWired, label: "Wired", value: Format.memory(memory.wiredBytes).text)
                ShareLegendItem(color: Palette.memoryCompressed, label: "Compressed", value: Format.memory(memory.compressedBytes).text)
            }
            .padding(.top, 15)
        }
    }

    private var topApps: some View {
        let apps = Array(store.apps.prefix(5))
        let largest = Double(apps.first?.memoryBytes ?? 0)
        return ShareInset(padding: EdgeInsets(top: 15, leading: 18, bottom: 12, trailing: 19)) {
            VStack(alignment: .leading, spacing: 0) {
                ShareCapsLabel("Top apps by memory")
                    .frame(height: 12)
                    .padding(.bottom, 6)
                ForEach(apps) { app in
                    HStack(spacing: 0) {
                        AppIconView(app, size: 20)
                        Text(app.name)
                            .font(.system(size: 14))
                            .foregroundStyle(Palette.ink)
                            .padding(.leading, 12)
                        Spacer(minLength: 12)
                        ShareMeter(fraction: largest > 0 ? Double(app.memoryBytes) / largest : 0, tint: Palette.memory)
                            .frame(width: 87, height: 4)
                        Text(Format.memory(app.memoryBytes).text)
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

    private func cpu(_ snapshot: SystemSnapshot) -> some View {
        let recent = RecentSlots(.cpu, in: store.live, slotCount: Self.cpuSlots)
        return ShareInset(padding: EdgeInsets(top: 17, leading: 19.5, bottom: 16.5, trailing: 19)) {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ShareCapsLabel("CPU · \(recent.title(liveCount: store.live.cpu.count))")
                    Spacer(minLength: 16)
                    HStack(spacing: 20) {
                        ShareInlineStat(label: "Now", value: Format.percent(snapshot.cpu.totalPercent).text)
                        ShareInlineStat(label: "Average", value: Format.percent(recent.average).text)
                        ShareInlineStat(label: "Peak", value: Format.percent(recent.peak).text)
                        ShareInlineStat(label: "GPU", value: Format.percent(snapshot.gpu.utilizationPercent).text)
                    }
                }
                .frame(height: 17)
                HStack(spacing: 14) {
                    ShareBarChart(slots: recent.slots, maxValue: 100, tint: Palette.cpu)
                    VStack(alignment: .trailing, spacing: 0) {
                        Text("100%")
                        Spacer(minLength: 0)
                        Text("50%")
                        Spacer(minLength: 0)
                        Text("0%")
                    }
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(Palette.ink3)
                    .padding(.vertical, -6)
                    .frame(width: 30, alignment: .trailing)
                }
                .frame(height: 112)
                .padding(.top, 8.5)
            }
        }
    }
}
