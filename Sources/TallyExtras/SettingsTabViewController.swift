import AppKit
import SwiftUI
import TallyCore

/// The Settings window's content: a toolbar with one item per pane. The window title follows the
/// selected pane and the window takes each pane's height. Changes apply as they are made.
@MainActor
public final class SettingsTabViewController: NSTabViewController {
    public init() {
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        canPropagateSelectedChildViewControllerTitle = true
        for pane in SettingsPane.allCases {
            let item = NSTabViewItem(viewController: SettingsPaneController(pane: pane))
            item.identifier = pane.rawValue
            item.label = pane.title
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
            addTabViewItem(item)
        }
        selectedTabViewItemIndex = SettingsPane.allCases.firstIndex(of: SettingsPane.stored) ?? 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    private static let frameName = "TallySettingsWindow"

    /// A standard Settings window around a new controller, sized to the pane shown last,
    /// where it was last left on screen.
    public static func makeWindow() -> NSWindow {
        let controller = SettingsTabViewController()
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenNone)
        let restored = window.setFrameUsingName(frameName)
        let topLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)
        if let pane = controller.selectedPaneController {
            pane.mount()
            window.setContentSize(pane.preferredContentSize)
        }
        if restored {
            window.setFrameTopLeftPoint(topLeft)
        } else {
            window.center()
        }
        window.setFrameAutosaveName(frameName)
        return window
    }

    public override func viewWillAppear() {
        super.viewWillAppear()
        transitionOptions = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? [] : [.crossfade, .allowUserInteraction]
    }

    public override func tabView(_ tabView: NSTabView, willSelect tabViewItem: NSTabViewItem?) {
        (tabViewItem?.viewController as? SettingsPaneController)?.mount()
        super.tabView(tabView, willSelect: tabViewItem)
    }

    public override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        if let pane = (tabViewItem?.viewController as? SettingsPaneController)?.pane {
            SettingsPane.stored = pane
        }
    }

    private var selectedPaneController: SettingsPaneController? {
        guard tabViewItems.indices.contains(selectedTabViewItemIndex) else { return nil }
        return tabViewItems[selectedTabViewItemIndex].viewController as? SettingsPaneController
    }
}

/// Hosts one pane, and only while it is on screen: a hidden pane or a closed window keeps no SwiftUI
/// views alive, so nothing in Settings updates when no one is looking.
@MainActor
final class SettingsPaneController: NSHostingController<AnyView> {
    let pane: SettingsPane
    private var isMounted = false

    init(pane: SettingsPane) {
        self.pane = pane
        super.init(rootView: AnyView(EmptyView()))
        title = pane.title
    }

    @available(*, unavailable)
    required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func mount() {
        guard !isMounted else { return }
        isMounted = true
        rootView = AnyView(SettingsPaneView(pane))
        sizingOptions = [.preferredContentSize]
    }

    override func viewWillAppear() {
        mount()
        super.viewWillAppear()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        guard isMounted else { return }
        isMounted = false
        sizingOptions = []
        rootView = AnyView(EmptyView())
    }
}
