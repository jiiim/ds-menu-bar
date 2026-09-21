// SPDX-FileCopyrightText: Copyright James Martin and DS Menu Bar contributors
// SPDX-License-Identifier: MIT

import AppKit

/// The main menu — the strip across the top of the screen while one of this
/// app's windows is frontmost. Distinct from the status item's dropdown, which
/// StatusBarController owns.
///
/// This has to be built by hand. A SwiftUI `App` supplies a standard main menu
/// for free, but this app runs an AppKit lifecycle, and neither
/// `NSApplication.addSceneRepresentation` nor the `Settings` scene's
/// `.commands` builds one. Without it `NSApp.mainMenu` stays nil, and the
/// Settings window's text fields lose Cut/Copy/Paste/Select All/Undo: AppKit
/// matches those keystrokes against menu key equivalents in `sendEvent`,
/// before the event ever reaches the field.
///
/// Every action here is dispatched to `nil` so it travels the responder chain
/// — the text-editing items reach the field editor, and the application items
/// reach NSApp or its delegate.
@MainActor
enum MainMenu {
    /// The Services and Window submenus are handed back separately because
    /// AppKit populates them only once they are assigned to NSApplication.
    struct Menus {
        let main: NSMenu
        let services: NSMenu
        let windows: NSMenu
    }

    static func install(on application: NSApplication) {
        let menus = make()
        application.mainMenu = menus.main
        application.servicesMenu = menus.services
        application.windowsMenu = menus.windows
    }

    static func make() -> Menus {
        let services = NSMenu(title: "Services")
        let windows = NSMenu(title: "Window")

        let main = NSMenu()
        main.addItem(submenu(applicationMenu(services: services)))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(windowMenu(windows)))
        return Menus(main: main, services: services, windows: windows)
    }

    // MARK: - Submenus

    /// AppKit titles the first submenu with the bundle name regardless of what
    /// is set here, so only the item titles need to name the app.
    private static func applicationMenu(services: NSMenu) -> NSMenu {
        let menu = NSMenu(title: "DS Menu Bar")
        menu.addItem(item("About DS Menu Bar", #selector(AppDelegate.showAboutWindow(_:))))
        menu.addItem(.separator())
        menu.addItem(item(
            "Settings…",
            #selector(AppDelegate.showSettingsWindow(_:)),
            key: ","
        ))
        menu.addItem(.separator())

        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        menu.addItem(servicesItem)
        menu.addItem(.separator())

        menu.addItem(item("Hide DS Menu Bar", #selector(NSApplication.hide(_:)), key: "h"))
        menu.addItem(item(
            "Hide Others",
            #selector(NSApplication.hideOtherApplications(_:)),
            key: "h",
            modifiers: [.command, .option]
        ))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        // The delegate owns the quit decision: it prompts while the server is
        // active. terminate: would skip that and go straight to teardown.
        menu.addItem(item("Quit DS Menu Bar", #selector(AppDelegate.requestQuit(_:)), key: "q"))
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Undo", Selector(("undo:")), key: "z"))
        menu.addItem(item(
            "Redo",
            Selector(("redo:")),
            key: "z",
            modifiers: [.command, .shift]
        ))
        menu.addItem(.separator())
        menu.addItem(item("Cut", #selector(NSText.cut(_:)), key: "x"))
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), key: "c"))
        menu.addItem(item("Paste", #selector(NSText.paste(_:)), key: "v"))
        menu.addItem(item("Delete", #selector(NSText.delete(_:))))
        menu.addItem(item("Select All", #selector(NSText.selectAll(_:)), key: "a"))
        return menu
    }

    private static func windowMenu(_ menu: NSMenu) -> NSMenu {
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), key: "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(item("Close", #selector(NSWindow.performClose(_:)), key: "w"))
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }

    // MARK: - Item construction

    private static func item(
        _ title: String,
        _ action: Selector,
        key: String = "",
        modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}
