import AppKit
import TallyCore
import TallyExtras

@MainActor
enum MainMenu {
    static func build() -> NSMenu {
        let mainMenu = NSMenu()
        let actions = MenuActions.shared

        let appMenu = NSMenu(title: "Tally")
        appMenu.addItem(withTitle: "About Tally", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        let updates = appMenu.addItem(withTitle: "Check for Updates…", action: #selector(MenuActions.checkForUpdates(_:)), keyEquivalent: "")
        updates.target = actions
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showSettingsWindow(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        services.submenu = NSMenu(title: "Services")
        NSApp.servicesMenu = services.submenu
        appMenu.addItem(services)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Tally", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Tally", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        addSubmenu(appMenu, to: mainMenu)

        let fileMenu = NSMenu(title: "File")
        // Shift-Command-E, since Command-E is the standard Use Selection for Find.
        let export = fileMenu.addItem(withTitle: "Export Image…", action: #selector(AppDelegate.showExport(_:)), keyEquivalent: "e")
        export.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        addSubmenu(fileMenu, to: mainMenu)

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        addSubmenu(editMenu, to: mainMenu)

        let viewMenu = NSMenu(title: "View")
        for (index, tab) in TallyTab.allCases.enumerated() {
            let item = viewMenu.addItem(withTitle: tab.title, action: #selector(AppDelegate.selectTab(_:)), keyEquivalent: "\(index + 1)")
            item.representedObject = tab.rawValue
        }
        viewMenu.addItem(.separator())
        let mixer = viewMenu.addItem(withTitle: "Show Volume Mixer", action: #selector(MenuActions.showVolumeMixer(_:)), keyEquivalent: "")
        mixer.target = actions
        let fans = viewMenu.addItem(withTitle: "Show Fan Control", action: #selector(MenuActions.showFanControl(_:)), keyEquivalent: "")
        fans.target = actions
        viewMenu.addItem(.separator())
        let fullScreen = viewMenu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        addSubmenu(viewMenu, to: mainMenu)

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Tally", action: #selector(AppDelegate.showMainWindow(_:)), keyEquivalent: "0")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu
        addSubmenu(windowMenu, to: mainMenu)

        let helpMenu = NSMenu(title: "Help")
        let help = helpMenu.addItem(withTitle: "Tally Help", action: #selector(MenuActions.openHelp(_:)), keyEquivalent: "?")
        help.target = actions
        NSApp.helpMenu = helpMenu
        addSubmenu(helpMenu, to: mainMenu)

        return mainMenu
    }

    private static func addSubmenu(_ submenu: NSMenu, to menu: NSMenu) {
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        menu.addItem(item)
    }
}

/// Targets for menu items that the app delegate does not handle.
@MainActor
final class MenuActions: NSObject {
    static let shared = MenuActions()
    private static let helpURL = URL(string: "https://github.com/dheerajkoppu/tally")!

    @objc func openHelp(_ sender: Any?) {
        NSWorkspace.shared.open(Self.helpURL)
    }

    @objc func checkForUpdates(_ sender: Any?) {
        UpdateChecker.checkForUpdates()
    }

    @objc func showVolumeMixer(_ sender: Any?) {
        let router = AppRouter.shared
        router.showMainWindow()
        router.isMixerPresented = true
    }

    @objc func showFanControl(_ sender: Any?) {
        let router = AppRouter.shared
        router.showMainWindow()
        router.isFanControlPresented = true
    }
}
