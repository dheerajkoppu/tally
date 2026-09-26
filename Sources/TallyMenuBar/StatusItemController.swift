import AppKit
import SwiftUI
import Combine
import TallyCore

/// The menu bar item and the compact panel behind it.
/// The item redraws only when a figure it shows changes, and in the plain icon style it does no work per sample.
@MainActor
public final class StatusItemController {
    private static let fastSamplingReason = "menubar-panel"
    private static let escapeKeyCode: UInt16 = 53

    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let bridge = StatusItemBridge()
    private let menu = NSMenu()
    private var strainMonitor = StrainMonitor()
    private var strain: Strain?
    private var lastContent: StatusItemArtwork.Content?
    private var lastAccessibilityLabel = ""
    private var lastToolTip = ""
    private var settingsSubscription: AnyCancellable?
    private var visibilitySubscription: AnyCancellable?
    private var visibilityObservation: NSKeyValueObservation?
    private var sampleSubscription: AnyCancellable?
    private var outsideClickMonitor: Any?
    private var escapeKeyMonitor: Any?
    /// The app that was frontmost before the panel opened, given focus back when the panel is dismissed.
    private var previousApplication: NSRunningApplication?
    private var returnsFocusOnClose = false
    private var lastPopoverClose = Date.distantPast
    private var isSamplingFast = false

    public init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "TallyStatusItem"
        // People can also Command-drag the item out of the menu bar; Settings brings it back.
        statusItem.behavior = .removalAllowed
        statusItem.isVisible = AppSettings.shared.showInMenuBar

        bridge.onClick = { [weak self] in self?.handleClick() }
        bridge.onPopoverWillClose = { [weak self] in self?.lastPopoverClose = Date() }
        bridge.onPopoverClose = { [weak self] in self?.popoverDidClose() }
        bridge.onOpen = { AppRouter.shared.showMainWindow() }
        bridge.onSettings = { AppRouter.shared.showSettings() }

        if let button = statusItem.button {
            button.target = bridge
            button.action = #selector(StatusItemBridge.statusItemClicked(_:))
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            button.imagePosition = .imageOnly
        }

        popover.behavior = .transient
        popover.delegate = bridge

        buildMenu()
        PanelActions.dismiss = { [weak self] in self?.closePopover(returningFocus: false) }
        observeSettings()
        observeVisibility()
        updateSampleSubscription()
        render()

        // For measuring the panel's cost: --open-panel [tab] opens it shortly after launch without taking focus.
        if CommandLine.arguments.contains("--open-panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.showPopover(takingFocus: false) }
        }
    }

    private func observeSettings() {
        let settings = AppSettings.shared
        // @Published emits before the value is stored, so read the settings after hopping to the next turn.
        settingsSubscription = Publishers.CombineLatest4(settings.$menuBarStyle, settings.$menuBarMetrics, settings.$menuBarWarnings, settings.$temperatureUnit)
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                updateSampleSubscription()
                render()
            }
    }

    /// Keeps the item's visibility and the Show in Menu Bar setting in step, whichever of them changes.
    private func observeVisibility() {
        // The item follows the setting at once, so a Command-drag is the only way the two can differ.
        visibilitySubscription = AppSettings.shared.$showInMenuBar
            .dropFirst()
            .sink { [weak self] isShown in self?.applyVisibility(isShown) }
        visibilityObservation = statusItem.observe(\.isVisible) { [weak self] _, _ in
            DispatchQueue.main.async { self?.syncSettingWithItem() }
        }
    }

    private func applyVisibility(_ isShown: Bool) {
        if statusItem.isVisible != isShown { statusItem.isVisible = isShown }
        if !isShown { closePopover(returningFocus: false) }
        // @Published emits before the value is stored.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            updateSampleSubscription()
            render()
        }
    }

    private func syncSettingWithItem() {
        let settings = AppSettings.shared
        if settings.showInMenuBar != statusItem.isVisible { settings.showInMenuBar = statusItem.isVisible }
    }

    /// Follows the store only while the item is in the menu bar and shows figures or may show a warning.
    private func updateSampleSubscription() {
        let settings = AppSettings.shared
        if !settings.menuBarWarnings {
            strain = nil
            strainMonitor = StrainMonitor()
        }
        let needsSamples = settings.showInMenuBar && (settings.menuBarStyle != .icon || settings.menuBarWarnings)
        guard needsSamples != (sampleSubscription != nil) else { return }
        guard needsSamples else {
            sampleSubscription = nil
            return
        }
        sampleSubscription = TallyStore.shared.$snapshot
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                guard let self else { return }
                if AppSettings.shared.menuBarWarnings { strain = strainMonitor.evaluate(snapshot) }
                render()
            }
    }

    private func render() {
        guard statusItem.isVisible, let button = statusItem.button else { return }
        let settings = AppSettings.shared
        let store = TallyStore.shared
        let warning = settings.menuBarWarnings ? strain : nil

        var style = settings.menuBarStyle
        var readings: [MenuBarReading] = []
        if style != .icon, store.hasSample {
            let metrics = settings.menuBarMetrics.prefix(style == .stacked ? 3 : 1)
            readings = metrics.map { MenuBarReadings.reading(for: $0, snapshot: store.snapshot, unit: settings.temperatureUnit) }
        }
        if readings.isEmpty { style = .icon }
        let bars = style == .graph
            ? MenuBarReadings.barLevels(for: readings[0].metric, snapshot: store.snapshot, live: store.live, levels: StatusItemArtwork.graphLevels)
            : []
        let content = StatusItemArtwork.Content(
            style: style,
            metrics: readings.map(\.metric),
            texts: readings.map { style == .stacked ? $0.compactText : $0.text },
            bars: bars,
            warning: warning?.level
        )
        if content != lastContent {
            lastContent = content
            button.image = StatusItemArtwork.image(for: content)
        }

        var spoken = ["Tally"]
        if let warning { spoken.append("Warning: " + warning.reasons.joined(separator: ", ")) }
        spoken.append(contentsOf: readings.map(\.spokenText))
        let accessibilityLabel = spoken.joined(separator: ", ")
        if accessibilityLabel != lastAccessibilityLabel {
            lastAccessibilityLabel = accessibilityLabel
            button.setAccessibilityLabel(accessibilityLabel)
        }
        let toolTip = warning.map { "Tally: " + $0.reasons.joined(separator: "\n") } ?? "Tally"
        if toolTip != lastToolTip {
            lastToolTip = toolTip
            button.toolTip = toolTip
        }
    }

    private func handleClick() {
        // No mouse event means an accessibility press, which opens the panel like a primary click.
        let event = NSApp.currentEvent
        let isMouse = event.map { [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp].contains($0.type) } ?? false
        let isSecondary = isMouse && (event?.type == .rightMouseDown || event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true)
        if isSecondary {
            showMenu()
        } else {
            togglePopover()
        }
    }

    /// Opens the panel without a click, for the app's --snapshot mode. Returns the panel's window.
    public func showPanelForSnapshot() -> NSWindow? {
        if !popover.isShown { showPopover(takingFocus: false) }
        return popover.contentViewController?.view.window
    }

    /// The status item's button, for the app's --snapshot mode.
    public var buttonForSnapshot: NSView? { statusItem.button }

    public var isInMenuBar: Bool { statusItem.isVisible }

    private func togglePopover() {
        if popover.isShown {
            closePopover(returningFocus: true)
            return
        }
        // The click that dismissed a transient popover also lands here; do not reopen it.
        if Date().timeIntervalSince(lastPopoverClose) < 0.3 { return }
        showPopover(takingFocus: true)
    }

    /// - Parameter takingFocus: make Tally active so the panel receives the keyboard (Escape, arrows, shortcuts).
    private func showPopover(takingFocus: Bool) {
        // A hidden item has no window to anchor to; showing then would throw, and a second show would leak its monitors.
        guard let button = statusItem.button, button.window != nil, statusItem.isVisible, !popover.isShown else { return }
        // One popover at a time: the panel replaces the main window's mixer or fan control.
        let router = AppRouter.shared
        if router.isMixerPresented { router.isMixerPresented = false }
        if router.isFanControlPresented { router.isFanControlPresented = false }
        let hostingController = NSHostingController(rootView: MenuBarPanelView())
        hostingController.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hostingController
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        if takingFocus {
            let frontmost = NSWorkspace.shared.frontmostApplication
            previousApplication = frontmost == NSRunningApplication.current ? nil : frontmost
            NSApp.activate()
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        // Keep the item highlighted while the panel is open; the click's mouse-up would clear it right away.
        DispatchQueue.main.async { [weak self] in
            guard let self, popover.isShown else { return }
            statusItem.button?.highlight(true)
        }

        if !isSamplingFast {
            isSamplingFast = true
            AppRouter.shared.engine?.beginFastSampling(Self.fastSamplingReason)
        }
        // A transient popover in an inactive app does not see clicks in other apps, so close it here.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.closePopover(returningFocus: false) }
        }
        escapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == Self.escapeKeyCode else { return event }
            let windowNumber = event.windowNumber
            let handled = MainActor.assumeIsolated { self?.escapePressed(inWindow: windowNumber) ?? false }
            return handled ? nil : event
        }
    }

    /// Escape closes the panel, unless an inline confirmation inside it is showing.
    private func escapePressed(inWindow windowNumber: Int) -> Bool {
        guard !PanelActions.isConfirming, windowNumber == popover.contentViewController?.view.window?.windowNumber else { return false }
        closePopover(returningFocus: true)
        return true
    }

    private func closePopover(returningFocus: Bool) {
        guard popover.isShown else { return }
        returnsFocusOnClose = returningFocus
        popover.performClose(nil)
    }

    private func popoverDidClose() {
        statusItem.button?.highlight(false)
        for monitor in [outsideClickMonitor, escapeKeyMonitor].compactMap({ $0 }) {
            NSEvent.removeMonitor(monitor)
        }
        outsideClickMonitor = nil
        escapeKeyMonitor = nil
        if isSamplingFast {
            isSamplingFast = false
            AppRouter.shared.engine?.endFastSampling(Self.fastSamplingReason)
        }
        // Hand the keyboard back to the app the user was in, unless a Tally window has it now.
        let panelWindow = popover.contentViewController?.view.window
        if returnsFocusOnClose, NSApp.isActive, NSApp.keyWindow == nil || NSApp.keyWindow === panelWindow, let previousApplication {
            previousApplication.activate(from: NSRunningApplication.current, options: [])
        }
        previousApplication = nil
        returnsFocusOnClose = false
        PanelActions.isConfirming = false
        // Drop the panel so nothing observes the store while it is hidden.
        popover.contentViewController = nil
    }

    private func buildMenu() {
        let open = NSMenuItem(title: "Open Tally", action: #selector(StatusItemBridge.openTally(_:)), keyEquivalent: "")
        let settings = NSMenuItem(title: "Settings…", action: #selector(StatusItemBridge.openSettings(_:)), keyEquivalent: ",")
        let quit = NSMenuItem(title: "Quit Tally", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        open.target = bridge
        settings.target = bridge
        quit.target = NSApp
        menu.items = [open, settings, .separator(), quit]
    }

    private func showMenu() {
        closePopover(returningFocus: false)
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }
}

/// The Objective-C side of the status item: button target, menu target and popover delegate.
@MainActor
private final class StatusItemBridge: NSObject, NSPopoverDelegate {
    var onClick: () -> Void = {}
    var onPopoverWillClose: () -> Void = {}
    var onPopoverClose: () -> Void = {}
    var onOpen: () -> Void = {}
    var onSettings: () -> Void = {}

    @objc func statusItemClicked(_ sender: Any?) {
        onClick()
    }

    @objc func openTally(_ sender: Any?) {
        onOpen()
    }

    @objc func openSettings(_ sender: Any?) {
        onSettings()
    }

    func popoverWillClose(_ notification: Notification) {
        onPopoverWillClose()
    }

    func popoverDidClose(_ notification: Notification) {
        onPopoverClose()
    }
}
