import SwiftUI
import TallyCore

public struct AboutSettingsPane: View {
    private static let website = URL(string: "https://github.com/dheerajkoppu/tally")!

    public init() {}

    public var body: some View {
        Form {
            Section {
                VStack(spacing: 6) {
                    TallyLogoMark(size: 64)
                        .padding(.bottom, 4)
                        .accessibilityHidden(true)
                    Text("Tally")
                        .font(.title2.weight(.bold))
                    Text(Self.versionText)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text("A free, open-source system monitor that adds up each app with its helpers.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
            }

            Section {
                PrivacyRow(symbol: "network", title: "Online Only When You Ask", text: "Tally connects to GitHub only when you choose Check for Updates.")
                PrivacyRow(symbol: "desktopcomputer", title: "Stays on Your Mac", text: "Your apps, history and project names never leave it.")
                PrivacyRow(symbol: "chevron.left.forwardslash.chevron.right", title: "Open Source", text: "Anyone can read the code and check.")
            } header: {
                Text("Privacy")
            }

            Section {
                LabeledContent("Source Code") {
                    Link("github.com/dheerajkoppu/tally", destination: Self.website)
                }
                LabeledContent("License", value: "MIT")
                LabeledContent("Updates") {
                    Button("Check for Updates…") {
                        UpdateChecker.checkForUpdates()
                    }
                }
            }
        }
        .settingsPaneLayout()
    }

    static var versionText: String {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let version = info["CFBundleShortVersionString"] as? String else { return "Development build" }
        if let build = info["CFBundleVersion"] as? String, !build.isEmpty {
            return "Version \(version) (\(build))"
        }
        return "Version \(version)"
    }
}

/// A privacy promise: a green symbol, a title and a sentence.
private struct PrivacyRow: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        LabeledContent {
            EmptyView()
        } label: {
            Label {
                Text(title)
                Text(text)
            } icon: {
                Image(systemName: symbol)
                    .foregroundStyle(Palette.good)
                    .frame(width: 20)
            }
        }
    }
}
