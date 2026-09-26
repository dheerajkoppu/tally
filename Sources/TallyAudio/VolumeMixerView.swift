import SwiftUI
import TallyCore

/// A slider for each app playing sound.
public struct VolumeMixerView: View {
    @ObservedObject private var mixer = AudioMixer.shared

    private static let rowHeight: CGFloat = 38
    private static let visibleRowLimit = 8

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 12)
            if mixer.permission == .denied {
                permissionNote
                    .padding(.bottom, 10)
            }
            if mixer.apps.isEmpty {
                emptyState
            } else if mixer.apps.count > Self.visibleRowLimit {
                ScrollView {
                    rows
                }
                .frame(height: Self.rowHeight * CGFloat(Self.visibleRowLimit))
            } else {
                rows
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 12)
        .frame(width: 340, alignment: .topLeading)
        .onAppear { mixer.start() }
        .onDisappear { mixer.stop() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .center, spacing: 8) {
                Text("Volume")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Spacer(minLength: 8)
                if mixer.hasAdjustments {
                    Button {
                        mixer.resetAll()
                    } label: {
                        Pill("Reset", symbol: "arrow.counterclockwise", tint: Palette.accent, fontSize: 11)
                    }
                    .buttonStyle(.plain)
                    .help("Put every app back to full volume")
                    .accessibilityLabel("Reset All Volumes")
                }
            }
            .frame(height: 20)
            Text(caption)
                .font(Typography.rowSubtitle)
                .foregroundStyle(Palette.ink2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var caption: String {
        if let device = mixer.outputDeviceName, !device.isEmpty {
            return "Sound goes to \(device).\nAudio is never saved."
        }
        return "Turn one app down without touching the rest. Audio is never saved."
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(mixer.apps) { app in
                VolumeRow(app: app, mixer: mixer)
                    .frame(height: Self.rowHeight)
            }
        }
        .disabled(!mixer.canAdjust)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "speaker.slash")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(Palette.ink3)
                .frame(height: 26)
            Text("Nothing is playing sound")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.ink2)
            Text("Apps show up here while they play audio.")
                .font(Typography.rowSubtitle)
                .foregroundStyle(Palette.ink3)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 14)
        .padding(.bottom, 20)
    }

    private var permissionNote: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.ink2)
                Text("Allow Tally under System Audio Recording to change app volumes. Audio is never saved.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Open System Settings") { mixer.openPrivacySettings() }
                .buttonStyle(SoftButtonStyle(tint: Palette.accent, prominent: true))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Icon, name, level slider and mute button for one app.
private struct VolumeRow: View {
    let app: AudioApp
    let mixer: AudioMixer

    var body: some View {
        HStack(spacing: 0) {
            AppIconView(bundlePath: app.iconPath, size: 20)
                .accessibilityHidden(true)
            HStack(spacing: 5) {
                Text(app.name)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let problem = app.problem {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.disk)
                        .help(problem)
                        .accessibilityLabel(problem)
                }
            }
            .padding(.leading, 14)
            .help(app.name)
            Spacer(minLength: 12)
            Slider(value: Binding(get: { app.volume }, set: { mixer.setVolume($0, for: app.id) }), in: 0...1) {
                Text("\(app.name) volume")
            }
            .labelsHidden()
            .controlSize(.small)
            .tint(app.isMuted ? Palette.ink3 : nil)
            .frame(width: 124)
            .help(app.isMuted ? "Muted" : percentText)
            .accessibilityValue(app.isMuted ? "Muted, \(percentText)" : percentText)
            Button {
                mixer.toggleMute(for: app.id)
            } label: {
                Image(systemName: app.isMuted ? "speaker.slash" : "speaker.wave.2")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(app.isMuted ? Palette.red : Palette.ink2)
                    .frame(width: 16, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 11)
            .help(app.isMuted ? "Unmute \(app.name)" : "Mute \(app.name)")
            .accessibilityLabel(app.isMuted ? "Unmute \(app.name)" : "Mute \(app.name)")
        }
    }

    /// "40 percent"
    private var percentText: String {
        "\(Int((app.volume * 100).rounded())) percent"
    }
}
