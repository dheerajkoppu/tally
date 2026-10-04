import SwiftUI
import TallyCore

/// Each SSD on the Disk tab, with the health it reports and how much has been written to and read from it in its lifetime.
struct MetricDrivesCard: View, Equatable {
    let rows: [MetricDriveRowModel]
    let tint: Color

    init(drives: [DriveHealth], tint: Color) {
        rows = drives.map(MetricDriveRowModel.init)
        self.tint = tint
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("Drive")
                Spacer(minLength: 12)
                Text("Health")
                    .frame(width: MetricDriveRow.valueWidth, alignment: .trailing)
                Text("Written")
                    .frame(width: MetricDriveRow.valueWidth, alignment: .trailing)
                Text("Read")
                    .frame(width: MetricDriveRow.valueWidth, alignment: .trailing)
            }
            .font(Typography.label)
            .foregroundStyle(Palette.ink2)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.top, 9)
            .padding(.bottom, 7)
            .accessibilityHidden(true)

            ForEach(rows) { row in
                MetricDriveRow(row: row, tint: tint)
                    .equatable()
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 6)
        .padding(.bottom, 7.5)
        .frame(maxWidth: .infinity)
        .metricSurface()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Drive health")
    }
}

/// Only what a drive row shows, so rows compare cheaply.
struct MetricDriveRowModel: Identifiable, Equatable {
    var id: String
    var name: String
    var symbol: String
    var subtitle: String
    var health: String
    var written: String
    var read: String
    var needsAttention: Bool
    var help: String

    init(_ drive: DriveHealth) {
        id = drive.id
        name = drive.name
        symbol = drive.isInternal ? "internaldrive" : "externaldrive"
        let poweredOn = "\(Format.span(TimeInterval(drive.powerOnHours) * 3600)) powered on"
        subtitle = [drive.isInternal ? drive.model : "External", poweredOn].joined(separator: " · ")
        health = Format.percent(drive.healthPercent).text
        written = Format.total(drive.bytesWritten).text
        read = Format.total(drive.bytesRead).text
        needsAttention = drive.needsAttention

        var notes = ["Health is the share of rated life left, as the drive itself estimates it."]
        if drive.hasCriticalWarning { notes.append("The drive is reporting a warning about its condition.") }
        if drive.mediaErrors > 0 { notes.append("It has hit \(Format.integer(Double(drive.mediaErrors))) errors it could not recover from.") }
        if drive.percentageUsed >= 100 { notes.append("It has passed its rated life.") }
        if drive.needsAttention { notes.append("Back up your data.") }
        notes.append("Spare blocks left: \(drive.availableSparePercent)%. Started \(Format.integer(Double(drive.powerCycles))) times, \(Format.integer(Double(drive.unsafeShutdowns))) without shutting down properly.")
        help = notes.joined(separator: " ")
    }
}

/// Badge, name and model, then health, written and read in columns. VoiceOver reads
/// "Internal SSD, healthy, health 96%, written 56.5 TB, read 220.5 TB, APPLE SSD AP1024Z, 77 days powered on".
struct MetricDriveRow: View, Equatable {
    static let valueWidth: CGFloat = 110

    let row: MetricDriveRowModel
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(row.symbol, tint: tint, size: MetricLayout.rowIconSize)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 7) {
                    Text(row.name)
                        .font(Typography.rowTitle)
                        .foregroundStyle(Palette.ink)
                    MetricTagPill(text: row.needsAttention ? "Needs Attention" : "Healthy", tint: row.needsAttention ? Palette.red : Palette.good)
                }
                Text(row.subtitle)
                    .font(Typography.rowSubtitle)
                    .foregroundStyle(Palette.ink2)
            }
            .lineLimit(1)
            Spacer(minLength: 16)
            value(row.health, isWarning: row.needsAttention)
            value(row.written)
            value(row.read)
        }
        .padding(.horizontal, 12)
        .frame(height: MetricLayout.rowHeight)
        .contentShape(Rectangle())
        .help(row.help)
        .accessibilityReading(accessibilityLabel, value: accessibilityValue)
    }

    private func value(_ text: String, isWarning: Bool = false) -> some View {
        Text(text)
            .font(Typography.rowValue)
            .tracking(-0.2)
            .foregroundStyle(isWarning ? Palette.red : Palette.ink)
            .lineLimit(1)
            .frame(width: Self.valueWidth, alignment: .trailing)
    }

    private var accessibilityLabel: String {
        "\(row.name), \(row.needsAttention ? "needs attention" : "healthy")"
    }

    private var accessibilityValue: String {
        "health \(row.health), written \(row.written), read \(row.read), \(row.subtitle.replacingOccurrences(of: " · ", with: ", "))"
    }
}
