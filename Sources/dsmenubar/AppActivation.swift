// SPDX-FileCopyrightText: Copyright James Martin and DS Menu Bar contributors
// SPDX-License-Identifier: MIT

import AppKit

/// Menu-bar apps (LSUIElement) never auto-front their windows and are
/// excluded from Cmd-Tab. AppActivation compensates: while any real window
/// (Settings or About) is visible the app runs as a regular app (Dock icon,
/// Cmd-Tab entry), windows are focused and pulled above other apps' windows
/// when opened, and every open window is re-fronted whenever the menu bar
/// menu is used.
@MainActor
enum AppActivation {
    /// Install the app-wide observers. Call once at launch.
    static func install() {
        let center = NotificationCenter.default

        // The menu bar icon was clicked / its menu is in use: pull open
        // windows back above other apps'. No activation here — that would
        // dismiss the menu.
        center.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                frontAll()
            }
        }

        // A window is closing: once it's gone, drop back to a plain menu bar
        // app if it was the last one. (Deferred a turn — willClose fires
        // while the window still counts as visible.)
        center.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if !windows().contains(where: { $0.isVisible }) {
                        NSApp.setActivationPolicy(.accessory)
                    }
                }
            }
        }
    }

    /// A window scene appeared: promote to a regular app so Cmd-Tab lists it,
    /// focus the app, and front its windows. SwiftUI may take several event-loop
    /// turns to create a Settings window, especially while another window is
    /// closing, so retry briefly until the newly opened window is visible.
    static func windowOpened() {
        NSApp.setActivationPolicy(.regular)
        activateVisibleWindow(attemptsRemaining: 4)
    }

    private static func activateVisibleWindow(attemptsRemaining: Int) {
        NSApp.activate(ignoringOtherApps: true)
        frontAll()

        // Only pick among already-visible windows. A `Window(id:)` scene keeps
        // its NSWindow around after closing, so an unfiltered lookup can reopen
        // a different singleton window such as About.
        if let window = NSApp.keyWindow ?? windows().last(where: \.isVisible) {
            window.makeKeyAndOrderFront(nil)
            return
        }

        guard attemptsRemaining > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            MainActor.assumeIsolated {
                activateVisibleWindow(attemptsRemaining: attemptsRemaining - 1)
            }
        }
    }

    /// Order every visible app window above other apps' windows, without
    /// changing focus.
    private static func frontAll() {
        for window in windows() where window.isVisible {
            window.orderFrontRegardless()
        }
    }

    /// The app's real windows: excludes the status item's menu bar window and
    /// other non-focusable chrome.
    private static func windows() -> [NSWindow] {
        NSApp.windows.filter(\.canBecomeKey)
    }
}
