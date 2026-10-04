import SwiftUI
import AppKit
import TallyCore

/// The compact panel shown from the menu bar item.
public struct MenuBarPanelView: View {
    @State private var tab: TallyTab

    /// Opens on the tab the panel showed last.
    @MainActor
    public init() {
        _tab = State(initialValue: PanelActions.lastTab)
    }

    public init(initialTab: TallyTab) {
        _tab = State(initialValue: initialTab)
    }

    public var body: some View {
        VStack(spacing: 0) {
            PanelTabStrip(selection: $tab)
            content
                .padding(.top, 9)
            PanelFooter(tab: tab)
                .padding(.top, 7)
        }
        .padding(.horizontal, PanelMetrics.padding)
        .padding(.top, PanelMetrics.padding)
        .padding(.bottom, 6)
        .frame(width: PanelMetrics.width)
        // While the popover animates to a new tab's height, the content stays at the top instead of sliding to stay centred.
        .frame(maxHeight: .infinity, alignment: .top)
        .onChange(of: tab) { _, newTab in
            PanelActions.lastTab = newTab
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .overview: OverviewPanel { tab = $0 }
        case .cpu: CPUPanel()
        case .memory: MemoryPanel()
        case .disk: DiskPanel()
        case .network: NetworkPanel()
        case .gpu: GPUPanel()
        case .battery: BatteryPanel()
        case .sensors: SensorsPanel()
        case .projects: ProjectsPanel()
        }
    }
}

/// An icon-only tab per section; the selected one sits on a faint wash of the accent.
/// Command-1 to Command-9 pick a tab, and the arrow keys move between tabs when the strip has focus.
struct PanelTabStrip: View {
    @Binding var selection: TallyTab
    @Namespace private var selectionNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(TallyTab.allCases.enumerated()), id: \.element) { index, tab in
                PanelTabButton(tab: tab, shortcut: KeyEquivalent(Character(String(index + 1))), isSelected: tab == selection, namespace: selectionNamespace) {
                    selection = tab
                }
            }
        }
        .padding(3)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: selection)
        .onMoveCommand { direction in
            let tabs = TallyTab.allCases
            guard let index = tabs.firstIndex(of: selection) else { return }
            switch direction {
            case .left: selection = tabs[(index + tabs.count - 1) % tabs.count]
            case .right: selection = tabs[(index + 1) % tabs.count]
            default: break
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sections")
    }
}

private struct PanelTabButton: View {
    let tab: TallyTab
    let shortcut: KeyEquivalent
    let isSelected: Bool
    let namespace: Namespace.ID
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Button(action: action) {
            Image(systemName: tab.symbol)
                .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                .foregroundStyle(foreground)
                .frame(maxWidth: .infinity)
                .frame(height: 26.5)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(tab.tint.opacity(selectionWash))
                            .matchedGeometryEffect(id: "selection", in: namespace)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(shortcut, modifiers: .command)
        .onHover { isHovered = $0 }
        .help(tab.title)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private var selectionWash: Double {
        contrast == .increased ? 0.30 : 0.20
    }

    private var foreground: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(LegibleTint(tab.tint, wash: selectionWash)) }
        return AnyShapeStyle(isHovered || contrast == .increased ? Palette.ink : Palette.ink2)
    }
}

/// Open Tally on the left, Settings and Quit on the right, as plain text in the secondary colour.
struct PanelFooter: View {
    let tab: TallyTab

    var body: some View {
        HStack(spacing: 6) {
            Button("Open Tally") {
                PanelActions.openMainWindow(tab)
            }
            .help("Open the Tally window on the \(tab.title) tab")

            Spacer(minLength: 8)

            Button("Settings…") {
                PanelActions.openSettings()
            }
            .keyboardShortcut(",", modifiers: .command)
            .help("Settings")

            Button("Quit") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
            .help("Quit Tally")
            .accessibilityLabel("Quit Tally")
        }
        .buttonStyle(PanelTextButtonStyle())
        // The labels line up with the section title; the buttons' padding reaches past it.
        .padding(.horizontal, 6 - PanelTextButtonStyle.horizontalPadding)
        .frame(height: 26)
    }
}
