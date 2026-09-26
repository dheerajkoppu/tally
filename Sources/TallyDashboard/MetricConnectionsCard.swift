import SwiftUI
import TallyCore

/// Each connected port on the Network tab, with its own download and upload speed and its link speed.
struct MetricConnectionsCard: View, Equatable {
    let rows: [MetricConnectionRowModel]
    let tint: Color
    let isPlaceholder: Bool

    init(network: NetworkStats, tint: Color, isPlaceholder: Bool) {
        let marksPrimary = network.connections.count > 1
        rows = network.connections.map { MetricConnectionRowModel($0, marksPrimary: marksPrimary) }
        self.tint = tint
        self.isPlaceholder = isPlaceholder
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("Connection")
                Spacer(minLength: 12)
                Text("Download")
                    .frame(width: MetricConnectionRow.valueWidth, alignment: .trailing)
                Text("Upload")
                    .frame(width: MetricConnectionRow.valueWidth, alignment: .trailing)
            }
            .font(Typography.label)
            .foregroundStyle(Palette.ink2)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.top, 9)
            .padding(.bottom, 7)
            .accessibilityHidden(true)

            if isPlaceholder {
                MetricSkeletonRow(isRaised: false)
                    .accessibilityHidden(true)
            } else if rows.isEmpty {
                Text("Not connected")
                    .font(Typography.body)
                    .foregroundStyle(Palette.ink2)
                    .frame(maxWidth: .infinity)
                    .frame(height: MetricLayout.rowHeight)
            } else {
                ForEach(rows) { row in
                    MetricConnectionRow(row: row, tint: tint)
                        .equatable()
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 6)
        .padding(.bottom, 7.5)
        .frame(maxWidth: .infinity)
        .metricSurface()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Connections")
    }
}

/// Only what a connection row shows, so rows compare cheaply.
struct MetricConnectionRowModel: Identifiable, Equatable {
    var id: String
    var kind: String
    var symbol: String
    var subtitle: String
    var linkSpeed: String?
    var download: String
    var upload: String
    var isPrimary: Bool

    init(_ connection: NetworkConnection, marksPrimary: Bool) {
        id = connection.interfaceName
        kind = connection.kind
        symbol = connection.symbol
        linkSpeed = connection.linkSpeedText
        subtitle = [connection.interfaceName, linkSpeed.map { "\($0) link" }].compactMap { $0 }.joined(separator: " · ")
        download = Format.rate(connection.downloadBytesPerSecond).text
        upload = Format.rate(connection.uploadBytesPerSecond).text
        isPrimary = marksPrimary && connection.isPrimary
    }
}

/// Badge, name and port, then download and upload in columns. VoiceOver reads
/// "Ethernet, en8, primary, download 21 kB/s, upload 217 kB/s, link speed 1 Gb/s".
struct MetricConnectionRow: View, Equatable {
    static let valueWidth: CGFloat = 110

    let row: MetricConnectionRowModel
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(row.symbol, tint: tint, size: MetricLayout.rowIconSize)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 7) {
                    Text(row.kind)
                        .font(Typography.rowTitle)
                        .foregroundStyle(Palette.ink)
                    if row.isPrimary {
                        MetricTagPill(text: "Primary", tint: tint)
                            .help("macOS sends traffic through this connection first.")
                    }
                }
                Text(row.subtitle)
                    .font(Typography.rowSubtitle)
                    .foregroundStyle(Palette.ink2)
            }
            .lineLimit(1)
            Spacer(minLength: 16)
            value(row.download)
            value(row.upload)
        }
        .padding(.horizontal, 12)
        .frame(height: MetricLayout.rowHeight)
        .accessibilityReading(accessibilityLabel, value: accessibilityValue)
    }

    private func value(_ text: String) -> some View {
        Text(text)
            .font(Typography.rowValue)
            .tracking(-0.2)
            .foregroundStyle(Palette.ink)
            .lineLimit(1)
            .frame(width: Self.valueWidth, alignment: .trailing)
    }

    private var accessibilityLabel: String {
        row.isPrimary ? "\(row.kind), \(row.id), primary" : "\(row.kind), \(row.id)"
    }

    private var accessibilityValue: String {
        var parts = ["download \(row.download)", "upload \(row.upload)"]
        if let linkSpeed = row.linkSpeed { parts.append("link speed \(linkSpeed)") }
        return parts.joined(separator: ", ")
    }
}
