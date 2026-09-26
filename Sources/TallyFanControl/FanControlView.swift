import SwiftUI
import TallyCore

/// The fan control popover: one row per fan with its live speed, an Automatic / Manual choice and a speed slider.
public struct FanControlView: View {
    @ObservedObject private var controller = FanController.shared
    @ObservedObject private var store = TallyStore.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorSchemeContrast) private var contrast

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if hasNoFans {
                FanNote(symbol: "wind", text: "This Mac has no fans. It cools itself silently, so there is nothing to control.")
            } else {
                helperCard
                presets
                ForEach(fans) { fan in
                    FanRow(fan: fan, controller: controller)
                }
                ForEach(controller.otherFanApps, id: \.self) { app in
                    FanNote(symbol: "exclamationmark.triangle", tint: Palette.disk, text: "\(app) is also installed. Let only one app control the fans at a time.")
                }
                if let message = controller.errorMessage {
                    FanNote(symbol: "xmark.octagon", tint: Palette.red, text: message)
                }
                if showsUninstall {
                    footer
                }
            }
        }
        .padding(20)
        .frame(width: 340, alignment: .topLeading)
        .onAppear { controller.refresh() }
        .onExitCommand { dismiss() }
    }

    private var fans: [FanReading] {
        let sensed = store.snapshot.sensors.fans
        return sensed.isEmpty ? controller.helperFans : sensed
    }

    private var hasNoFans: Bool {
        store.hasSample && fans.isEmpty && controller.helperState != .checking
    }

    private var showsUninstall: Bool {
        FanHelperLocation.testSocketPath == nil && [.installed, .needsUpdate, .unreachable].contains(controller.helperState)
    }

    private var secondaryInk: Color { contrast == .increased ? Palette.ink : Palette.ink2 }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 9) {
                IconBadge(Symbols.fan, tint: Palette.cpu)
                Text("Fans")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Spacer(minLength: 8)
                if controller.isDryRun {
                    Pill("Dry Run", tint: Palette.disk, fontSize: 11)
                        .help("The helper is logging fan changes without making them")
                }
            }
            Text("Choose a fixed speed or let macOS decide. Fans return to automatic when Tally quits.")
                .font(Typography.rowSubtitle)
                .foregroundStyle(secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var helperCard: some View {
        switch controller.helperState {
        case .notInstalled:
            HelperCard(
                text: "Fan control needs a small helper that runs with administrator rights. It only changes fan speeds and puts them back to automatic when Tally quits.",
                action: "Install Helper…",
                isWorking: controller.isInstalling,
                perform: controller.install
            )
        case .needsUpdate:
            HelperCard(
                text: "The fan helper is out of date or was installed for another user. Update it to keep controlling the fans.",
                action: "Update Helper…",
                isWorking: controller.isInstalling,
                perform: controller.install
            )
        case .unreachable:
            HelperCard(
                text: "The fan helper is installed but not responding. Check that Tally is allowed under Login Items & Extensions in System Settings, or reinstall the helper.",
                action: "Reinstall Helper…",
                isWorking: controller.isInstalling,
                perform: controller.install
            )
        case .checking, .installed:
            EmptyView()
        }
    }

    private var presets: some View {
        let isEnabled = controller.canControl && !fans.isEmpty
        let active = isEnabled ? controller.activePreset(for: fans) : nil
        return HStack(spacing: 6) {
            ForEach(FanController.Preset.allCases) { preset in
                let isActive = preset == active
                Button(preset.title) {
                    controller.apply(preset, to: fans)
                }
                .buttonStyle(SoftButtonStyle(tint: isActive ? Color.accentColor : nil, prominent: isActive))
                .help(preset.help)
                .accessibilityLabel("\(preset.title) preset")
                .accessibilityAddTraits(isActive ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Uninstall Helper…") {
                controller.uninstall()
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12))
            .help("Remove the fan helper. Fans return to automatic.")
            .disabled(controller.isInstalling)
            Spacer(minLength: 0)
            if controller.isInstalling {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Working")
            }
        }
    }
}

/// Name, live speed, mode and target slider for one fan.
private struct FanRow: View {
    let fan: FanReading
    @ObservedObject var controller: FanController
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let mode = controller.mode(for: fan.id)
        let target = controller.target(for: fan)
        let hasRange = fan.maxRPM > fan.minRPM
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(fan.name)
                    .font(Typography.rowTitle)
                    .foregroundStyle(Palette.ink)
                Spacer(minLength: 8)
                Text(fan.rpm >= 1 ? "\(Format.integer(fan.rpm)) rpm" : "Off")
                    .font(Typography.rowValue)
                    .foregroundStyle(Palette.ink)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(fan.name) speed")
            .accessibilityValue(fan.rpm >= 1 ? "\(Format.integer(fan.rpm)) rpm" : "Off")

            Picker("\(fan.name) mode", selection: Binding(
                get: { mode },
                set: { newMode in
                    if newMode == .manual {
                        controller.setManual(fan.id, rpm: target)
                    } else {
                        controller.setAuto(fan.id)
                    }
                }
            )) {
                ForEach(FanController.Mode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(!controller.canControl || !hasRange)
            .help("Automatic lets macOS choose the speed. Manual holds the speed you set.")

            VStack(spacing: 3) {
                Slider(
                    value: Binding(
                        get: { target },
                        set: { controller.setManual(fan.id, rpm: min(max($0, fan.minRPM), fan.maxRPM)) }
                    ),
                    in: fan.minRPM...(hasRange ? fan.maxRPM : fan.minRPM + 1)
                ) {
                    Text("\(fan.name) target speed")
                }
                .labelsHidden()
                .disabled(mode != .manual || !controller.canControl || !hasRange)
                .accessibilityValue("\(Format.integer(target)) rpm")
                .accessibilityHint(mode == .manual ? "Adjust to change the fan speed" : "Choose Manual to set a speed")

                HStack {
                    Text(Format.integer(fan.minRPM))
                    Spacer(minLength: 8)
                    Text(caption(mode: mode, target: target))
                        .fontWeight(.medium)
                        .foregroundStyle(mode == .manual ? Palette.ink : secondaryInk)
                    Spacer(minLength: 8)
                    Text(Format.integer(fan.maxRPM))
                }
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(secondaryInk)
                .accessibilityHidden(true)
            }

            if controller.externallyControlled.contains(fan.id) {
                FanNote(symbol: "exclamationmark.triangle", tint: Palette.disk, text: "Another app is holding this fan at a fixed speed.")
            }
        }
        .padding(14)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            if contrast == .increased {
                RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.ink2, lineWidth: 1)
            }
        }
    }

    private var secondaryInk: Color { contrast == .increased ? Palette.ink : Palette.ink2 }

    private func caption(mode: FanController.Mode, target: Double) -> String {
        mode == .manual ? "Target \(Format.integer(target)) rpm" : "Set by macOS"
    }
}

/// The explanation and install button shown until the helper is ready.
private struct HelperCard: View {
    let text: String
    let action: String
    let isWorking: Bool
    let perform: () -> Void
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.ink2)
                    .accessibilityHidden(true)
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button(action, action: perform)
                    .buttonStyle(SoftButtonStyle(tint: Color.accentColor, prominent: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking)
                    .help("Asks for your administrator password once")
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Installing")
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            if contrast == .increased {
                RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.ink2, lineWidth: 1)
            }
        }
    }
}

/// A short symbol-and-sentence note.
private struct FanNote: View {
    let symbol: String
    var tint: Color = Palette.ink2
    let text: String
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(contrast == .increased ? Palette.ink : Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
