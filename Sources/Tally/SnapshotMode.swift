import AppKit
import TallyCore
import TallyMenuBar
import TallyExtras

/// Captures the app's own windows to PNG, for checking the real window chrome without screen recording access,
/// and prints how the toolbars are built, since Liquid Glass does not draw into a layer capture:
///   Tally.app/Contents/MacOS/Tally --snapshot /tmp/shots [--wait 6] [--appearance light|dark]
@MainActor
enum SnapshotMode {
    static var isRequested: Bool { CommandLine.arguments.contains("--snapshot") }

    static func run(windows: WindowManager, statusItem: StatusItemController?) {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count else { return }
        let output = URL(fileURLWithPath: arguments[index + 1])
        let wait = arguments.firstIndex(of: "--wait").flatMap { $0 + 1 < arguments.count ? Double(arguments[$0 + 1]) : nil } ?? 6
        if let appearanceIndex = arguments.firstIndex(of: "--appearance"), appearanceIndex + 1 < arguments.count {
            NSApp.appearance = NSAppearance(named: arguments[appearanceIndex + 1] == "dark" ? .darkAqua : .aqua)
        }
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        Task { @MainActor in
            func pause(_ seconds: Double) async {
                try? await Task.sleep(for: .seconds(seconds))
            }
            func file(_ name: String) -> URL {
                output.appendingPathComponent(name)
            }

            windows.showMain()
            await pause(wait)
            let router = AppRouter.shared
            for tab in TallyTab.allCases {
                router.tab = tab
                await pause(1.2)
                if let window = windows.mainWindow { capture(window, to: file("window-\(tab.rawValue).png")) }
            }
            router.tab = .overview
            await pause(0.5)
            guard let mainWindow = windows.mainWindow else { exit(1) }
            describe(mainWindow, as: "Main window")

            let savedFrame = mainWindow.frame
            mainWindow.setFrame(NSRect(origin: savedFrame.origin, size: NSSize(width: 880, height: savedFrame.height)), display: true)
            await pause(1)
            describe(mainWindow, as: "Main window at 880 pt")
            capture(mainWindow, to: file("window-narrow.png"))
            mainWindow.setFrame(savedFrame, display: true)
            await pause(0.5)

            router.isExportPresented = true
            await pause(1.5)
            if let sheet = mainWindow.attachedSheet {
                capture(sheet, to: file("sheet-export.png"))
                print("Export sheet prevents quitting: \(sheet.preventsApplicationTerminationWhenModal)")
            }
            router.isExportPresented = false
            await pause(1)

            mainWindow.performClose(nil)
            await pause(1)
            print("Closed main window keeps a view tree: \(mainWindow.contentViewController != nil || mainWindow.contentView != nil), toolbar: \(mainWindow.toolbar != nil)")
            windows.showMain()
            await pause(1.5)
            describe(mainWindow, as: "Main window reopened")
            print("Reopened frame matches: \(mainWindow.frame == savedFrame)")

            await checkPresenceRule(statusItem: statusItem)

            if let button = statusItem?.buttonForSnapshot, let window = button.window {
                capture(window, to: file("statusitem.png"))
            }
            if let panel = statusItem?.showPanelForSnapshot() {
                await pause(1.5)
                capture(panel, to: file("panel.png"))
                print("Panel window: \(type(of: panel)), opaque: \(panel.isOpaque)")
            }

            let storedPane = SettingsPane.stored
            windows.showSettings()
            await pause(1)
            if let settingsWindow = windows.settingsWindow, let tabs = settingsWindow.contentViewController as? SettingsTabViewController {
                for (paneIndex, pane) in SettingsPane.allCases.enumerated() {
                    tabs.selectedTabViewItemIndex = paneIndex
                    await pause(0.8)
                    capture(settingsWindow, to: file("settings-\(pane.rawValue).png"))
                    describeSettings(settingsWindow)
                }
                tabs.selectedTabViewItemIndex = SettingsPane.allCases.firstIndex(of: storedPane) ?? 0
            }
            SettingsPane.stored = storedPane
            exit(0)
        }
    }

    /// Hides the menu bar item and the Dock icon in turn, prints what Tally keeps, and puts both settings back.
    private static func checkPresenceRule(statusItem: StatusItemController?) async {
        let settings = AppSettings.shared
        let original = (dock: settings.showInDock, menuBar: settings.showInMenuBar)
        func state(_ step: String) async {
            try? await Task.sleep(for: .seconds(0.3))
            let itemVisible = statusItem?.isInMenuBar ?? false
            print("\(step): Dock \(settings.showInDock), menu bar \(settings.showInMenuBar), status item shown \(itemVisible)")
        }
        settings.showInDock = true
        settings.showInMenuBar = false
        await state("Menu bar item off")
        settings.showInDock = false
        await state("Then Dock icon off")
        settings.showInMenuBar = false
        await state("Then menu bar item off again")
        settings.showInMenuBar = original.menuBar
        settings.showInDock = original.dock
        settings.showInMenuBar = original.menuBar
        await state("Restored")
    }

    /// The window's title and each toolbar platter, control and segment, as text.
    private static func describe(_ window: NSWindow, as name: String) {
        var lines = ["\(name): title “\(window.title)”, title hidden: \(window.titleVisibility == .hidden), toolbar style: \(window.toolbarStyle.rawValue), frame: \(window.frame.size)"]
        if let toolbar = window.toolbar {
            lines.append("  toolbar items: \(toolbar.items.count), customizable: \(toolbar.allowsUserCustomization)")
            for item in toolbar.items where !item.label.isEmpty {
                lines.append("    item “\(item.label)”, tooltip “\(item.toolTip ?? "")”")
            }
        }
        func walk(_ view: NSView, depth: Int) {
            let className = String(describing: type(of: view))
            let indent = String(repeating: "  ", count: depth)
            if className.contains("Platter") || className.contains("GlassEffect") || className.contains("ScrollPocket") {
                lines.append("\(indent)\(className) \(view.frame)")
            }
            if let segmented = view as? NSSegmentedControl {
                var role = "segmented"
                #if compiler(>=6.4)
                if #available(macOS 27, *) { role = segmented.role == .tabs ? "tabs" : "segmented" }
                #endif
                let segments = (0..<segmented.segmentCount).map { segment in
                    let label = segmented.label(forSegment: segment) ?? ""
                    let shown = label.isEmpty ? "icon(\(segmented.toolTip(forSegment: segment) ?? "no tooltip"))" : label
                    return segment == segmented.selectedSegment ? "[\(shown)]" : shown
                }
                lines.append("\(indent)NSSegmentedControl role: \(role), \(view.frame.size): \(segments.joined(separator: " "))")
            } else if let button = view as? NSButton, !className.contains("Theme") {
                lines.append("\(indent)\(className) “\(button.toolTip ?? button.title)” \(view.frame.size)")
            }
            for subview in view.subviews { walk(subview, depth: depth + 1) }
        }
        if let frameView = window.contentView?.superview { walk(frameView, depth: 1) }
        print(lines.joined(separator: "\n"))
    }

    private static func describeSettings(_ window: NSWindow) {
        let minimize = window.standardWindowButton(.miniaturizeButton)?.isEnabled ?? false
        let zoom = window.standardWindowButton(.zoomButton)?.isEnabled ?? false
        let toolbar = window.toolbar
        print("Settings: title “\(window.title)”, content \(window.contentLayoutRect.size), minimize enabled: \(minimize), zoom enabled: \(zoom), customizable: \(toolbar?.allowsUserCustomization ?? false), selected: \(toolbar?.selectedItemIdentifier?.rawValue ?? "none"), style: \(window.toolbarStyle.rawValue)")
    }

    private static func capture(_ window: NSWindow, to file: URL) {
        guard let view = window.contentView?.superview ?? window.contentView else { return }
        capture(view, scale: window.backingScaleFactor, background: nil, to: file)
    }

    private static func capture(_ view: NSView, scale: CGFloat, background: NSColor?, to file: URL) {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let width = Int(view.bounds.width * scale)
        let height = Int(view.bounds.height * scale)
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let layer = view.layer
        else { return }
        context.scaleBy(x: scale, y: scale)
        if let background {
            view.effectiveAppearance.performAsCurrentDrawingAppearance {
                context.setFillColor(background.cgColor)
            }
            context.fill(CGRect(origin: .zero, size: view.bounds.size))
            // A hosting view's layer draws top-down, unlike the window frame's.
            context.translateBy(x: 0, y: view.bounds.height)
            context.scaleBy(x: 1, y: -1)
        }
        layer.render(in: context)
        guard let image = context.makeImage(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        try? png.write(to: file)
        print("Wrote \(file.path)")
    }
}
