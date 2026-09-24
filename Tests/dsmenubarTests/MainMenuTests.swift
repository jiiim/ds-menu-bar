// SPDX-FileCopyrightText: Copyright James Martin and DS Menu Bar contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest

@testable import dsmenubar

/// The AppKit lifecycle builds no main menu of its own, so an app that never
/// installs one silently loses every application and text-editing keystroke.
/// These assert the menu exists and carries the key equivalents AppKit matches
/// in sendEvent before the event reaches the first responder.
@MainActor
final class MainMenuTests: XCTestCase {
    func testTopLevelStructure() {
        let menus = MainMenu.make()

        XCTAssertEqual(
            menus.main.items.map(\.title),
            ["DS Menu Bar", "Edit", "Server", "Window"]
        )
        XCTAssertTrue(menus.main.items.allSatisfy { $0.submenu != nil })
        XCTAssertTrue(menus.main.items.last?.submenu === menus.windows)
    }

    func testApplicationMenuCoversAboutSettingsAndQuit() throws {
        let menu = try submenu(named: "DS Menu Bar")

        XCTAssertEqual(
            menu.items.filter { !$0.isSeparatorItem }.map(\.title),
            [
                "About DS Menu Bar",
                "Settings…",
                "Services",
                "Hide DS Menu Bar",
                "Hide Others",
                "Show All",
                "Quit DS Menu Bar",
            ]
        )

        try assertShortcut(in: menu, "Settings…", key: ",", modifiers: .command)
        try assertShortcut(in: menu, "Quit DS Menu Bar", key: "q", modifiers: .command)
        try assertShortcut(
            in: menu,
            "Hide Others",
            key: "h",
            modifiers: [.command, .option]
        )

        XCTAssertEqual(
            try item(in: menu, "About DS Menu Bar").action,
            #selector(AppDelegate.showAboutWindow(_:))
        )
        XCTAssertEqual(
            try item(in: menu, "Settings…").action,
            #selector(AppDelegate.showSettingsWindow(_:))
        )
        XCTAssertEqual(
            try item(in: menu, "Quit DS Menu Bar").action,
            #selector(AppDelegate.requestQuit(_:))
        )
    }

    /// Without these, Cut/Copy/Paste/Select All/Undo do nothing in the
    /// Settings window's path and port fields.
    func testEditMenuCarriesTheTextEditingShortcuts() throws {
        let menu = try submenu(named: "Edit")

        XCTAssertEqual(
            menu.items.filter { !$0.isSeparatorItem }.map(\.title),
            ["Undo", "Redo", "Cut", "Copy", "Paste", "Delete", "Select All"]
        )

        try assertShortcut(in: menu, "Undo", key: "z", modifiers: .command)
        try assertShortcut(in: menu, "Redo", key: "z", modifiers: [.command, .shift])
        try assertShortcut(in: menu, "Cut", key: "x", modifiers: .command)
        try assertShortcut(in: menu, "Copy", key: "c", modifiers: .command)
        try assertShortcut(in: menu, "Paste", key: "v", modifiers: .command)
        try assertShortcut(in: menu, "Select All", key: "a", modifiers: .command)

        XCTAssertEqual(try item(in: menu, "Paste").action, #selector(NSText.paste(_:)))
        XCTAssertEqual(try item(in: menu, "Undo").action, Selector(("undo:")))
    }

    /// Dispatching to nil is what lets the text-editing items reach the field
    /// editor and the application items reach NSApp or the app delegate.
    func testEveryActionTravelsTheResponderChain() {
        let menus = MainMenu.make()
        for submenu in menus.main.items.compactMap(\.submenu) {
            // An item holding a submenu is targeted at that submenu by AppKit.
            for item in submenu.items where !item.isSeparatorItem && item.submenu == nil {
                XCTAssertNil(item.target, "\(submenu.title) ▸ \(item.title)")
                XCTAssertNotNil(item.action, "\(submenu.title) ▸ \(item.title)")
            }
        }
    }

    /// The Settings window dropped its start/stop button, so the lifecycle
    /// commands live here and in the status-item menu.
    func testServerMenuCarriesLifecycleCommands() throws {
        let menu = try submenu(named: "Server")

        XCTAssertEqual(
            menu.items.filter { !$0.isSeparatorItem }.map(\.title),
            ["Start Server", "Stop Server", "Restart Server"]
        )
        XCTAssertEqual(
            try item(in: menu, "Start Server").action,
            #selector(AppDelegate.startServer(_:))
        )
        XCTAssertEqual(
            try item(in: menu, "Stop Server").action,
            #selector(AppDelegate.stopServer(_:))
        )
        XCTAssertEqual(
            try item(in: menu, "Restart Server").action,
            #selector(AppDelegate.restartServer(_:))
        )
    }

    /// NSApp forwards unhandled application actions to its delegate, which
    /// only works while these stay exposed to the Objective-C runtime.
    func testTheAppDelegateRespondsToTheMenuActions() {
        XCTAssertTrue(
            AppDelegate.instancesRespond(to: #selector(AppDelegate.showAboutWindow(_:)))
        )
        XCTAssertTrue(
            AppDelegate.instancesRespond(to: #selector(AppDelegate.showSettingsWindow(_:)))
        )
        XCTAssertTrue(
            AppDelegate.instancesRespond(to: #selector(AppDelegate.requestQuit(_:)))
        )
        XCTAssertTrue(
            AppDelegate.instancesRespond(to: #selector(AppDelegate.startServer(_:)))
        )
        XCTAssertTrue(
            AppDelegate.instancesRespond(to: #selector(AppDelegate.stopServer(_:)))
        )
        XCTAssertTrue(
            AppDelegate.instancesRespond(to: #selector(AppDelegate.restartServer(_:)))
        )
    }

    // MARK: - Helpers

    private func submenu(named title: String) throws -> NSMenu {
        let menus = MainMenu.make()
        return try XCTUnwrap(
            menus.main.items.first { $0.title == title }?.submenu,
            "No \(title) submenu"
        )
    }

    private func item(in menu: NSMenu, _ title: String) throws -> NSMenuItem {
        try XCTUnwrap(menu.items.first { $0.title == title }, "No \(title) item")
    }

    private func assertShortcut(
        in menu: NSMenu,
        _ title: String,
        key: String,
        modifiers: NSEvent.ModifierFlags,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let item = try item(in: menu, title)
        XCTAssertEqual(item.keyEquivalent, key, title, file: file, line: line)
        XCTAssertEqual(
            item.keyEquivalentModifierMask,
            modifiers,
            title,
            file: file,
            line: line
        )
    }
}
