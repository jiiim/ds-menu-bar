// SPDX-FileCopyrightText: Copyright James Martin and DS Menu Bar contributors
// SPDX-License-Identifier: MIT

import XCTest

@testable import dsmenubar

/// Tests for `ServerStatus` and its display-string extensions (`isStartingUp`
/// in ServerManager.swift; `isTransitional`, `steadyGlyph`, `menuText`,
/// `actionTitle`, `canStart`, `canStop`, `canRestart` in MenuBarContent.swift).
/// These drive what the menubar icon, menu, and Server menu show for each
/// lifecycle state, so a wrong case in any of the switches would show the
/// wrong thing to the user with no compiler error.
final class ServerStatusTests: XCTestCase {

    // MARK: - isStartingUp

    func testIsStartingUp() {
        XCTAssertTrue(ServerStatus.starting.isStartingUp)
        XCTAssertTrue(ServerStatus.restarting.isStartingUp)
        XCTAssertFalse(ServerStatus.stopped.isStartingUp)
        XCTAssertFalse(ServerStatus.running(pid: 1).isStartingUp)
        XCTAssertFalse(ServerStatus.stopping.isStartingUp)
        XCTAssertFalse(ServerStatus.error("x").isStartingUp)
    }

    // MARK: - isTransitional

    func testIsTransitional() {
        XCTAssertTrue(ServerStatus.starting.isTransitional)
        XCTAssertTrue(ServerStatus.stopping.isTransitional)
        XCTAssertTrue(ServerStatus.restarting.isTransitional)
        XCTAssertFalse(ServerStatus.stopped.isTransitional)
        XCTAssertFalse(ServerStatus.running(pid: 1).isTransitional)
        XCTAssertFalse(ServerStatus.error("x").isTransitional)
    }

    // MARK: - steadyGlyph

    func testSteadyGlyph() {
        XCTAssertEqual(ServerStatus.running(pid: 1).steadyGlyph, "✦")
        XCTAssertEqual(ServerStatus.stopped.steadyGlyph, "✧")
        XCTAssertEqual(ServerStatus.starting.steadyGlyph, "✧")
        XCTAssertEqual(ServerStatus.stopping.steadyGlyph, "✧")
        XCTAssertEqual(ServerStatus.restarting.steadyGlyph, "✧")
        XCTAssertEqual(ServerStatus.error("x").steadyGlyph, "✧")
    }

    // MARK: - menuText

    func testMenuText() {
        XCTAssertEqual(ServerStatus.stopped.menuText, "Stopped")
        XCTAssertEqual(ServerStatus.starting.menuText, "Starting…")
        XCTAssertEqual(ServerStatus.restarting.menuText, "Restarting…")
        XCTAssertEqual(ServerStatus.running(pid: 4242).menuText, "Running (PID 4242)")
        XCTAssertEqual(ServerStatus.stopping.menuText, "Stopping…")
        XCTAssertEqual(ServerStatus.error("boom").menuText, "Error: boom")
    }

    // MARK: - actionTitle

    func testActionTitle() {
        XCTAssertEqual(ServerStatus.stopped.actionTitle, "Start Server")
        XCTAssertEqual(ServerStatus.error("x").actionTitle, "Start Server")
        XCTAssertEqual(ServerStatus.starting.actionTitle, "Cancel Start")
        XCTAssertEqual(ServerStatus.restarting.actionTitle, "Cancel Restart")
        XCTAssertEqual(ServerStatus.running(pid: 1).actionTitle, "Stop Server")
        XCTAssertEqual(ServerStatus.stopping.actionTitle, "Stop Server")
    }

    // MARK: - Server menu enablement

    func testServerMenuEnablement() {
        XCTAssertTrue(ServerStatus.stopped.canStart)
        XCTAssertTrue(ServerStatus.error("x").canStart)
        XCTAssertFalse(ServerStatus.starting.canStart)
        XCTAssertFalse(ServerStatus.running(pid: 1).canStart)
        XCTAssertFalse(ServerStatus.stopping.canStart)
        XCTAssertFalse(ServerStatus.restarting.canStart)

        XCTAssertTrue(ServerStatus.starting.canStop)
        XCTAssertTrue(ServerStatus.running(pid: 1).canStop)
        XCTAssertTrue(ServerStatus.restarting.canStop)
        XCTAssertFalse(ServerStatus.stopped.canStop)
        XCTAssertFalse(ServerStatus.stopping.canStop)
        XCTAssertFalse(ServerStatus.error("x").canStop)

        XCTAssertTrue(ServerStatus.running(pid: 1).canRestart)
        XCTAssertFalse(ServerStatus.starting.canRestart)
        XCTAssertFalse(ServerStatus.restarting.canRestart)
        XCTAssertFalse(ServerStatus.stopping.canRestart)
        XCTAssertFalse(ServerStatus.stopped.canRestart)
        XCTAssertFalse(ServerStatus.error("x").canRestart)
    }

    // MARK: - holdsServerProcess

    func testHoldsServerProcess() {
        XCTAssertTrue(ServerStatus.starting.holdsServerProcess)
        XCTAssertTrue(ServerStatus.restarting.holdsServerProcess)
        XCTAssertTrue(ServerStatus.running(pid: 1).holdsServerProcess)
        XCTAssertTrue(ServerStatus.stopping.holdsServerProcess)
        XCTAssertFalse(ServerStatus.stopped.holdsServerProcess)
        XCTAssertFalse(ServerStatus.error("x").holdsServerProcess)
    }

    // MARK: - requiresQuitConfirmation

    func testRequiresQuitConfirmation() {
        XCTAssertTrue(ServerStatus.starting.requiresQuitConfirmation)
        XCTAssertTrue(ServerStatus.restarting.requiresQuitConfirmation)
        XCTAssertTrue(ServerStatus.running(pid: 1).requiresQuitConfirmation)
        // .stopping matches holdsServerProcess but not this: a shutdown is
        // already under way, so there is no work left to confirm stopping.
        XCTAssertFalse(ServerStatus.stopping.requiresQuitConfirmation)
        XCTAssertFalse(ServerStatus.stopped.requiresQuitConfirmation)
        XCTAssertFalse(ServerStatus.error("x").requiresQuitConfirmation)
    }

    // MARK: - Equatable

    func testEquatable() {
        XCTAssertEqual(ServerStatus.running(pid: 5), ServerStatus.running(pid: 5))
        XCTAssertNotEqual(ServerStatus.running(pid: 5), ServerStatus.running(pid: 6))
        XCTAssertEqual(ServerStatus.error("a"), ServerStatus.error("a"))
        XCTAssertNotEqual(ServerStatus.error("a"), ServerStatus.error("b"))
        XCTAssertNotEqual(ServerStatus.stopped, ServerStatus.stopping)
    }
}
