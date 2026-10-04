import SwiftUI
import TallyCore
import TallyDashboard
import TallyProjects
import TallyExtras
import TallyFanControl

/// The main window: the selected tab, scrolling under a standard toolbar with the tab switcher and the window's tools.
struct MainView: View {
    @ObservedObject private var router = AppRouter.shared
    @State private var showsTabTitles = true
    /// The picker writes here and the router follows after the update, so the bridged toolbar control never
    /// publishes a router change from inside a view update.
    @State private var selectedTab = AppRouter.shared.tab

    /// Below this window width the nine tab titles no longer fit beside the toolbar button, so the tabs show icons.
    static let tabTitlesMinimumWidth: CGFloat = 940

    var body: some View {
        ScrollView {
            content
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 20)
        }
        .scrollIndicators(.automatic)
        .background(Palette.background)
        .frame(minWidth: 860, minHeight: 600)
        .onGeometryChange(for: Bool.self) { proxy in
            proxy.size.width >= Self.tabTitlesMinimumWidth
        } action: { fits in
            showsTabTitles = fits
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                TabSwitcher(selection: $selectedTab, showsTitles: showsTabTitles)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    router.isExportPresented = true
                } label: {
                    Label("Export Image", systemImage: "square.and.arrow.up")
                }
                .help("Export an image of your Mac’s tally")
            }
        }
        .navigationTitle(router.tab.title)
        .onChange(of: selectedTab) { _, tab in
            if router.tab != tab { router.tab = tab }
        }
        .onChange(of: router.tab) { _, tab in
            if selectedTab != tab { selectedTab = tab }
        }
        .toolbar(removing: .title)
        // One sheet at a time: asking for one replaces the other rather than queueing behind it.
        .onChange(of: router.isExportPresented) { _, isPresented in
            if isPresented { router.inspectedAppID = nil }
        }
        .onChange(of: router.inspectedAppID) { _, appID in
            if appID != nil { router.isExportPresented = false }
        }
        .sheet(item: presentedSheet) { sheet in
            switch sheet {
            case .inspector(let appID):
                AppInspectorView(appID: appID)
                    .allowsQuittingWhilePresented()
            case .export:
                ExportView()
                    .allowsQuittingWhilePresented()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch router.tab {
        case .overview:
            OverviewView()
        case .sensors:
            SensorsView { FanControlView() }
        case .projects:
            ProjectsView()
        default:
            MetricTabView(tab: router.tab)
                .id(router.tab)
        }
    }

    private var presentedSheet: Binding<MainSheet?> {
        Binding(
            get: {
                if router.isExportPresented { return .export }
                return router.inspectedAppID.map(MainSheet.inspector)
            },
            set: { sheet in
                router.isExportPresented = sheet == .export
                if case .inspector(let appID) = sheet { router.inspectedAppID = appID } else { router.inspectedAppID = nil }
            }
        )
    }
}

private enum MainSheet: Identifiable, Hashable {
    case inspector(String)
    case export

    var id: Self { self }
}

/// The tabs as one control in the toolbar: tabs on macOS 27, a segmented control before.
/// A segment shows a title or an icon, never both, so narrow windows switch to icons and keep the titles for tooltips and VoiceOver.
private struct TabSwitcher: View {
    @Binding var selection: TallyTab
    let showsTitles: Bool

    var body: some View {
        let picker = Picker("Section", selection: $selection) {
            ForEach(TallyTab.allCases) { tab in
                Label(tab.title, systemImage: tab.symbol)
                    .help(tab.title)
                    .tag(tab)
            }
        }
        if showsTitles {
            styled(picker.labelStyle(.titleOnly))
        } else {
            styled(picker.labelStyle(.iconOnly))
        }
    }

    @ViewBuilder
    private func styled(_ picker: some View) -> some View {
        // The tabs style needs the macOS 27 SDK (Swift 6.4); older Xcodes build with the segmented style.
        #if compiler(>=6.4)
        if #available(macOS 27, *) {
            picker.pickerStyle(.tabs)
        } else {
            picker.pickerStyle(.segmented)
        }
        #else
        picker.pickerStyle(.segmented)
        #endif
    }
}

private extension View {
    /// Sheets that only show information let the app quit without closing them first.
    @ViewBuilder
    func allowsQuittingWhilePresented() -> some View {
        if #available(macOS 15.4, *) {
            presentationPreventsAppTermination(false)
        } else {
            self
        }
    }
}
