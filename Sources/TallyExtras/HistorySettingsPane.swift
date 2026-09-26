import SwiftUI
import AppKit
import TallyCore

/// Where the history file lives and how much of it there is, read off the main thread.
@MainActor
final class HistoryFileModel: ObservableObject {
    nonisolated static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Tally", isDirectory: true)
    nonisolated static let file = directory.appendingPathComponent("history.sqlite")

    @Published private(set) var sizeBytes: UInt64?
    @Published private(set) var dailyMemory: [Double] = []
    @Published private(set) var isClearing = false

    var displayPath: String {
        (Self.file.path as NSString).abbreviatingWithTildeInPath
    }

    func load() {
        let history = TallyStore.shared.history
        Task.detached(priority: .utility) {
            let points = history?.series(.memory, range: .days30, buckets: Self.days) ?? []
            let daily = Self.dailySlots(points, now: Date())
            let size = Self.measure()
            await MainActor.run {
                self.sizeBytes = size
                self.dailyMemory = daily
            }
        }
    }

    func clear() {
        guard let history = TallyStore.shared.history, !isClearing else { return }
        isClearing = true
        Task.detached(priority: .userInitiated) {
            history.clearAll()
            await MainActor.run {
                self.isClearing = false
                self.load()
            }
        }
    }

    func revealInFinder() {
        if FileManager.default.fileExists(atPath: Self.file.path) {
            NSWorkspace.shared.activateFileViewerSelecting([Self.file])
        } else if FileManager.default.fileExists(atPath: Self.directory.path) {
            NSWorkspace.shared.open(Self.directory)
        }
    }

    nonisolated private static let days = 30

    /// One value per day, oldest first, with days that have no data left at zero.
    nonisolated private static func dailySlots(_ points: [HistoryPoint], now: Date) -> [Double] {
        let start = now.addingTimeInterval(-HistoryRange.days30.duration)
        let slot = HistoryRange.days30.duration / Double(days)
        var values = [Double](repeating: 0, count: days)
        for point in points {
            let index = Int(point.date.timeIntervalSince(start) / slot)
            values[min(max(index, 0), days - 1)] = max(values[min(max(index, 0), days - 1)], point.value)
        }
        return values
    }

    /// The database plus its write-ahead log and shared-memory files.
    nonisolated private static func measure() -> UInt64? {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { return nil }
        let sizes = names
            .filter { $0.hasPrefix(file.lastPathComponent) }
            .compactMap { try? manager.attributesOfItem(atPath: directory.appendingPathComponent($0).path)[.size] as? UInt64 }
        return sizes.isEmpty ? nil : sizes.reduce(0, +)
    }
}

public struct HistorySettingsPane: View {
    @StateObject private var model = HistoryFileModel()
    @State private var isConfirmingClear = false

    public init() {}

    public var body: some View {
        Form {
            Section {
                DailyMemoryChart(values: model.dailyMemory, installedBytes: TallyStore.shared.snapshot.memory.totalBytes, isClearing: model.isClearing)
                    .frame(height: 64)
                    .padding(.vertical, 4)
            } header: {
                Text("Last 30 Days")
            } footer: {
                Text("Memory in use, one bar per day.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                LabeledContent {
                    Button("Show in Finder") { model.revealInFinder() }
                } label: {
                    Text("Location")
                    Text(model.displayPath)
                        .textSelection(.enabled)
                }
                LabeledContent("Size", value: model.sizeBytes.map { Format.storage($0).text } ?? "–")
                LabeledContent("Kept For", value: "30 days")
            } header: {
                Text("Stored on This Mac")
            } footer: {
                Text("CPU, memory, GPU, disk, network, battery and power, for the whole Mac and for each app, about once a minute. Anything older than 30 days is removed on its own. Nothing leaves this Mac.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                LabeledContent {
                    Button("Clear History…", role: .destructive) { isConfirmingClear = true }
                        .disabled(model.isClearing)
                } label: {
                    Text("Clear History")
                    Text("Charts in the History views start over.")
                }
            }
        }
        .settingsPaneLayout()
        .task { model.load() }
        .alert("Clear all history?", isPresented: $isConfirmingClear) {
            Button("Clear History", role: .destructive) { model.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes up to 30 days of usage history from this Mac. It cannot be undone.")
        }
    }
}

/// A bar a day of peak memory in use, drawn as one shape.
private struct DailyMemoryChart: View {
    let values: [Double]
    let installedBytes: UInt64
    let isClearing: Bool

    var body: some View {
        let hasData = values.contains { $0 > 0 }
        UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 10, style: .continuous)
            .fill(Palette.memory.opacity(hasData ? 0.10 : 0.08))
            .overlay {
                if hasData {
                    DailyBars(fractions: fractions)
                        .fill(Palette.memory)
                        .padding(.horizontal, 6)
                        .padding(.top, 6)
                } else {
                    Text(isClearing ? "Clearing…" : "Bars appear here as Tally records your Mac's days.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Memory in use, last 30 days")
            .accessibilityValue(summary)
    }

    private var top: Double {
        installedBytes > 0 ? Double(installedBytes) : max(values.max() ?? 1, 1)
    }

    private var fractions: [Double] {
        values.map { min(max($0 / top, 0), 1) }
    }

    private var summary: String {
        guard let peak = values.max(), peak > 0 else { return "No data yet" }
        let days = values.filter { $0 > 0 }.count
        return "Peak \(Format.memory(UInt64(peak)).text), \(days == 1 ? "1 day" : "\(days) days") recorded"
    }
}

/// Bars with rounded tops, bottom-aligned, one per value. Days without data get no bar.
private struct DailyBars: Shape {
    let fractions: [Double]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let count = max(fractions.count, 1)
        let slot = rect.width / CGFloat(count)
        let barWidth = max(1.5, slot * 0.62)
        let radius = min(2.5, barWidth / 2)
        for (index, fraction) in fractions.enumerated() where fraction > 0 {
            let height = max(2, rect.height * fraction)
            let bar = CGRect(x: rect.minX + CGFloat(index) * slot + (slot - barWidth) / 2, y: rect.maxY - height, width: barWidth, height: height)
            path.addPath(UnevenRoundedRectangle(topLeadingRadius: radius, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: radius).path(in: bar))
        }
        return path
    }
}
