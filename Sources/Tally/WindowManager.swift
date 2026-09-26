import AppKit
import SwiftUI
import TallyCore
import TallyExtras

/// Owns the main, settings and welcome windows.
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    var engine: SamplingEngine?

    private(set) var mainWindow: NSWindow?
    private(set) var settingsWindow: NSWindow?
    private var welcomeWindow: NSWindow?
    private static let mainFrameName = "TallyMainWindow"

    func showMain() {
        let window = mainWindow ?? makeMainWindow()
        if window.contentViewController == nil {
            let frame = window.frame
            let controller = NSHostingController(rootView: MainView())
            // The window's size limits are fixed, so SwiftUI need not recompute them after every sample.
            controller.sizingOptions = []
            controller.sceneBridgingOptions = [.toolbars, .title]
            window.contentViewController = controller
            window.setFrame(frame, display: false)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        engine?.beginFastSampling("main-window")
    }

    /// A standard titled window; `MainView` supplies its toolbar and title.
    private func makeMainWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = TallyTab.overview.title
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 860, height: 600)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName(Self.mainFrameName)
        if !window.setFrameUsingName(Self.mainFrameName) { window.center() }
        window.delegate = self
        mainWindow = window
        return window
    }

    func showSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsTabViewController.makeWindow()
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func showWelcome(onFinish: @escaping () -> Void) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: WelcomeView { [weak self] in
            onFinish()
            self?.welcomeWindow?.close()
            self?.showMain()
        })
        window.delegate = self
        window.center()
        welcomeWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        engine?.beginFastSampling("welcome")
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === welcomeWindow {
            engine?.endFastSampling("welcome")
            welcomeWindow = nil
            return
        }
        guard window === mainWindow else { return }
        engine?.endFastSampling("main-window")
        // Drop the view tree and the toolbar SwiftUI built for it, so a closed window stops redrawing on every sample.
        DispatchQueue.main.async { [weak window] in
            guard let window, !window.isVisible else { return }
            window.contentViewController = nil
            window.contentView = nil
            window.toolbar = nil
        }
    }

    func windowDidMiniaturize(_ notification: Notification) {
        engine?.endFastSampling("main-window")
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        engine?.beginFastSampling("main-window")
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === mainWindow else { return }
        if window.occlusionState.contains(.visible) {
            engine?.beginFastSampling("main-window")
        } else {
            engine?.endFastSampling("main-window")
        }
    }
}
