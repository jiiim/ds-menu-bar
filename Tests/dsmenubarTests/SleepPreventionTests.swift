// SPDX-FileCopyrightText: Copyright James Martin and DS Menu Bar contributors
// SPDX-License-Identifier: MIT

import XCTest

@testable import dsmenubar

/// The keep-awake decision is a three-input state table, and getting it wrong
/// means either a Mac that sleeps through an unattended generation or a laptop
/// held awake on battery. The policy is pure so the whole table is checkable
/// without IOKit or a power source.
final class SleepPreventionTests: XCTestCase {

    // MARK: - Policy

    func testPreferenceOffIsAlwaysOff() {
        for status in Self.everyStatus {
            for onExternalPower in [true, false] {
                XCTAssertEqual(
                    KeepAwakePolicy.state(
                        preferenceEnabled: false,
                        status: status,
                        onExternalPower: onExternalPower
                    ),
                    .off
                )
            }
        }
    }

    func testAssertionIsHeldOnlyForALiveServerOnExternalPower() {
        let live: [ServerStatus] = [.starting, .restarting, .running(pid: 1), .stopping]
        for status in live {
            XCTAssertEqual(
                KeepAwakePolicy.state(
                    preferenceEnabled: true,
                    status: status,
                    onExternalPower: true
                ),
                .active
            )
            XCTAssertEqual(
                KeepAwakePolicy.state(
                    preferenceEnabled: true,
                    status: status,
                    onExternalPower: false
                ),
                .waitingForPower
            )
        }
    }

    /// A stopped server outranks the power source: there is nothing to keep the
    /// Mac awake for, so the subtitle must not blame the power adapter.
    func testNoLiveServerReportsStoppedRegardlessOfPower() {
        for status in [ServerStatus.stopped, .error("boom")] {
            for onExternalPower in [true, false] {
                XCTAssertEqual(
                    KeepAwakePolicy.state(
                        preferenceEnabled: true,
                        status: status,
                        onExternalPower: onExternalPower
                    ),
                    .serverStopped
                )
            }
        }
    }

    func testOnlyTheEnabledStatesExplainThemselvesInTheMenu() {
        XCTAssertNil(KeepAwakeState.off.menuSubtitle)
        XCTAssertEqual(KeepAwakeState.active.menuSubtitle, "Active")
        XCTAssertEqual(
            KeepAwakeState.waitingForPower.menuSubtitle,
            "Waiting for a power adapter"
        )
        XCTAssertEqual(KeepAwakeState.serverStopped.menuSubtitle, "Server stopped")
    }

    // MARK: - Assertion

    /// Takes a real assertion: `identifier` is only set when IOKit reports
    /// success, so this fails if the create call is malformed.
    func testAssertionIsHeldAndReleasedIdempotently() {
        let assertion = IdleSleepAssertion(name: "DS Menu Bar tests")
        XCTAssertFalse(assertion.isHeld)

        assertion.hold()
        XCTAssertTrue(assertion.isHeld)
        assertion.hold()
        XCTAssertTrue(assertion.isHeld)

        assertion.release()
        XCTAssertFalse(assertion.isHeld)
        assertion.release()
        XCTAssertFalse(assertion.isHeld)
    }

    // MARK: - Power monitor

    func testPowerMonitorStartsAndStopsRepeatedly() {
        let monitor = ExternalPowerMonitor()
        // Whether this Mac is on a power adapter is not the test's business;
        // that it answers without a battery present is.
        _ = monitor.isOnExternalPower
        monitor.start()
        monitor.start()
        monitor.stop()
        monitor.stop()
    }

    private static let everyStatus: [ServerStatus] = [
        .stopped, .starting, .restarting, .running(pid: 1), .stopping, .error("x"),
    ]
}
