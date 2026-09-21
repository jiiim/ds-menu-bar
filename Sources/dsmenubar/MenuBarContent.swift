// SPDX-FileCopyrightText: Copyright James Martin and DS Menu Bar contributors
// SPDX-License-Identifier: MIT

import AppKit
import Combine

// MARK: - Status presentation

extension ServerStatus {
    var isError: Bool {
        if case .error = self { return true }
        return false
    }

    /// States where the server is mid-transition — the menubar glyph blinks here.
    var isTransitional: Bool {
        switch self {
        case .starting, .stopping, .restarting: return true
        case .stopped, .running, .error: return false
        }
    }

    /// Menubar glyph when not transitioning: filled star = on, open star = off.
    var steadyGlyph: String {
        if case .running = self { return "✦" }   // U+2726 BLACK FOUR POINTED STAR
        return "✧"                                // U+2727 WHITE FOUR POINTED STAR
    }

    /// Human-readable run state shown in the menu.
    var menuText: String {
        switch self {
        case .stopped:          return "Stopped"
        case .starting:         return "Starting…"
        case .restarting:       return "Restarting…"
        case .running(let pid): return "Running (PID \(pid))"
        case .stopping:         return "Stopping…"
        case .error(let msg):   return "Error: \(msg)"
        }
    }

    /// Title of the start/stop/cancel action item.
    var actionTitle: String {
        switch self {
        case .stopped, .error:    return "Start Server"
        case .starting:           return "Cancel Start"
        case .restarting:         return "Cancel Restart"
        case .running, .stopping: return "Stop Server"
        }
    }
}

// MARK: - Menu-bar item

/// Owns the native NSStatusItem and its menu.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let server: ServerManager
    private let openSettings: () -> Void
    private let openAbout: () -> Void
    private let requestQuit: () -> Void
    private let statusItem: NSStatusItem
    private var cancellables = Set<AnyCancellable>()
    private var blinkTimer: AnyCancellable?
    private var blinkOn = false
    private var menuIsOpen = false
    private var rendered: RenderedStatusItem?
    private var renderedStatusInformation: String?

    private let serverItem = NSMenuItem(title: "ds4-server", action: nil, keyEquivalent: "")
    private let statusTextItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let serverActionItem = NSMenuItem(title: "", action: nil, keyEquivalent: "s")
    private let speedItem = NSMenuItem(
        title: "Show Speeds in Menu Bar",
        action: nil,
        keyEquivalent: ""
    )
    private let keepAwakeItem = NSMenuItem(
        title: "Keep Awake While Server Runs",
        action: nil,
        keyEquivalent: ""
    )

    /// What the status button was last given. Every assignment to a status
    /// item's title relayouts the menu bar, and most updates that reach here
    /// carry nothing new — a rate that renders to the same four columns, or a
    /// status change while speeds are hidden.
    private struct RenderedStatusItem: Equatable {
        let glyph: String
        let performance: ServerPerformance.DisplayIdentity?
    }

    init(
        server: ServerManager,
        openSettings: @escaping () -> Void,
        openAbout: @escaping () -> Void,
        requestQuit: @escaping () -> Void
    ) {
        self.server = server
        self.openSettings = openSettings
        self.openAbout = openAbout
        self.requestQuit = requestQuit
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        statusItem.menu = makeMenu()
        observeServer()
        updateBlinkTimer()
        updateStatusButton()
        updateStatusInformation()
        refreshMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        refreshMenu()
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        serverItem.isEnabled = false
        statusTextItem.isEnabled = false
        serverActionItem.target = self
        serverActionItem.action = #selector(toggleServer)
        serverActionItem.keyEquivalentModifierMask = .command
        serverActionItem.isEnabled = true
        speedItem.target = self
        speedItem.action = #selector(toggleSpeedDisplay)
        speedItem.isEnabled = true
        keepAwakeItem.target = self
        keepAwakeItem.action = #selector(toggleKeepAwake)
        keepAwakeItem.isEnabled = true

        menu.addItem(serverItem)
        menu.addItem(statusTextItem)
        menu.addItem(.separator())
        menu.addItem(serverActionItem)
        menu.addItem(item("Open Log in Console", action: #selector(openLog)))
        menu.addItem(speedItem)
        menu.addItem(keepAwakeItem)
        menu.addItem(.separator())
        menu.addItem(item("Settings…", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(item("About DS Menu Bar", action: #selector(showAbout)))
        menu.addItem(.separator())
        menu.addItem(item("Quit DS Menu Bar", action: #selector(quit), keyEquivalent: "q"))
        return menu
    }

    private func item(
        _ title: String,
        action: Selector,
        keyEquivalent: String = ""
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        item.keyEquivalentModifierMask = .command
        item.isEnabled = true
        return item
    }

    /// Observe each input on the narrowest update path it needs. In particular,
    /// throughput records redraw only the visible title: they do not rewrite the
    /// status tooltip, the VoiceOver label, or the open menu.
    ///
    /// Delivery is hopped to the main queue because `@Published` publishes in
    /// `willSet`: a subscriber that runs synchronously still reads the previous
    /// value off the property.
    private func observeServer() {
        server.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                updateBlinkTimer()
                updateStatusButton()
                updateStatusInformation()
                if menuIsOpen { refreshMenu() }
            }
            .store(in: &cancellables)

        server.$performance
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateStatusButton()
            }
            .store(in: &cancellables)

        server.$showsPerformanceInMenuBar
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                updateStatusButton()
                if menuIsOpen { refreshMenu() }
            }
            .store(in: &cancellables)

        Publishers.Merge(
            server.$keepsAwakeWhileRunning.map { _ in () },
            server.$keepAwakeState.map { _ in () }
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in
            guard let self else { return }
            if menuIsOpen { refreshMenu() }
        }
        .store(in: &cancellables)
    }

    /// The blink means something only mid-transition. Running it for the app's
    /// whole lifetime woke the main run loop twice a second with the server
    /// stopped and nothing to animate.
    private func updateBlinkTimer() {
        guard server.status.isTransitional else {
            blinkTimer = nil
            blinkOn = false
            return
        }
        guard blinkTimer == nil else { return }
        blinkTimer = Timer.publish(every: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                blinkOn.toggle()
                updateStatusButton()
            }
    }

    private func updateStatusButton() {
        guard let button = statusItem.button else { return }
        let glyph: String
        if server.status.isTransitional {
            glyph = blinkOn ? "✦" : "✧"
        } else {
            glyph = server.status.steadyGlyph
        }

        let current = RenderedStatusItem(
            glyph: glyph,
            performance: server.showsPerformanceInMenuBar
                ? server.performance.displayIdentity
                : nil
        )
        guard current != rendered else { return }
        rendered = current

        if server.showsPerformanceInMenuBar {
            statusItem.length = NSStatusItem.variableLength
            button.alignment = .center
            button.attributedTitle = StatusBarTitle.make(
                glyph: glyph,
                performance: server.performance
            )
        } else {
            statusItem.length = NSStatusItem.squareLength
            button.alignment = .center
            button.title = glyph
        }
        button.lineBreakMode = .byClipping
    }

    /// Status information is intentionally independent of throughput. A speed
    /// update must not cause assistive technology or the tooltip to receive a
    /// stream of otherwise identical updates.
    private func updateStatusInformation() {
        guard let button = statusItem.button else { return }
        let information = "DS Menu Bar — \(server.status.menuText)"
        guard information != renderedStatusInformation else { return }
        renderedStatusInformation = information
        button.setAccessibilityLabel(information)
        button.toolTip = information
    }

    private func refreshMenu() {
        statusTextItem.title = "Status: \(server.status.menuText)"
        serverActionItem.title = server.status.actionTitle
        speedItem.state = server.showsPerformanceInMenuBar ? .on : .off
        // The check mark is the preference. The subtitle is what it is doing
        // now, which differs whenever the Mac is on battery or nothing is
        // running — an item that claimed to be keeping the Mac awake while it
        // was not would be worse than no item at all.
        keepAwakeItem.state = server.keepsAwakeWhileRunning ? .on : .off
        keepAwakeItem.subtitle = server.keepAwakeState.menuSubtitle
    }

    @objc private func toggleServer() {
        switch server.status {
        case .running, .starting, .restarting, .stopping:
            server.stop()
        case .stopped, .error:
            NSApp.activate()
            server.start()
        }
    }

    @objc private func openLog() {
        ServerLogActions.openInConsole(logPath: server.logPath)
    }

    @objc private func toggleSpeedDisplay() {
        server.setShowsPerformanceInMenuBar(!server.showsPerformanceInMenuBar)
    }

    @objc private func toggleKeepAwake() {
        server.setKeepsAwakeWhileRunning(!server.keepsAwakeWhileRunning)
    }

    @objc private func showSettings() {
        openSettings()
    }

    @objc private func showAbout() {
        openAbout()
    }

    @objc private func quit() {
        // The delegate decides: it prompts while the server is active, and
        // falls through to the same stop-and-terminate otherwise.
        requestQuit()
    }
}

/// Uses fixed-pitch glyphs only for fields whose contents change. The native
/// menu-bar font remains in use for the status glyph, spacing, and units.
@MainActor
enum StatusBarTitle {
    private static let menuFont = NSFont.menuBarFont(ofSize: 0)
    private static let fieldFont = NSFont.monospacedSystemFont(
        ofSize: menuFont.pointSize,
        weight: .regular
    )

    static func make(
        glyph: String,
        performance: ServerPerformance
    ) -> NSAttributedString {
        let title = NSMutableAttributedString()
        title.append(segment("\(glyph) ", font: menuFont))
        title.append(segment(performance.menuBarPhase, font: fieldFont))
        title.append(segment(" ", font: menuFont))
        title.append(segment(performance.menuBarRate, font: fieldFont))
        title.append(segment(" t/s", font: menuFont))
        return title
    }

    private static func segment(_ string: String, font: NSFont) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [.font: font])
    }
}

@MainActor
enum ServerLogActions {
    /// Open the server log in Console.app. If it doesn't exist yet, create it
    /// with the same owner-only permissions used by ProcessManager.
    static func openInConsole(logPath: String) {
        let path = (logPath as NSString).expandingTildeInPath
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            ProcessManager.createOwnerOnlyDirectory(
                (path as NSString).deletingLastPathComponent, fm: fm)
            fm.createFile(atPath: path, contents: nil,
                          attributes: [.posixPermissions: 0o600])
        }
        NSWorkspace.shared.open(
            [URL(fileURLWithPath: path)],
            withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Console.app"),
            configuration: NSWorkspace.OpenConfiguration())
    }
}
