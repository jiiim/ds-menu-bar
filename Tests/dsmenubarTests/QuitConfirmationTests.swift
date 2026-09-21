// SPDX-FileCopyrightText: Copyright James Martin and DS Menu Bar contributors
// SPDX-License-Identifier: MIT

import XCTest

@testable import dsmenubar

/// The full status x preference x pending matrix behind every quit path. The
/// decision is small enough to test exhaustively, and getting a case wrong has
/// two visible failure modes: a prompt during a scripted quit, or a server
/// stopped without one.
final class QuitConfirmationTests: XCTestCase {

    private static let statuses: [ServerStatus] = [
        .stopped,
        .starting,
        .restarting,
        .running(pid: 1),
        .stopping,
        .error("boom"),
    ]

    func testPreferenceOffAlwaysProceeds() {
        for status in Self.statuses {
            XCTAssertEqual(
                QuitConfirmation.decision(
                    status: status,
                    preferenceEnabled: false,
                    promptIsPending: false
                ),
                .proceed,
                "\(status)"
            )
            XCTAssertEqual(
                QuitConfirmation.decision(
                    status: status,
                    preferenceEnabled: false,
                    promptIsPending: true
                ),
                .proceed,
                "\(status)"
            )
        }
    }

    func testInactiveStatesProceed() {
        for status in [ServerStatus.stopped, .stopping, .error("boom")] {
            XCTAssertEqual(
                QuitConfirmation.decision(
                    status: status,
                    preferenceEnabled: true,
                    promptIsPending: false
                ),
                .proceed,
                "\(status)"
            )
        }
    }

    func testActiveStatesPrompt() {
        for status in [ServerStatus.starting, .restarting, .running(pid: 1)] {
            XCTAssertEqual(
                QuitConfirmation.decision(
                    status: status,
                    preferenceEnabled: true,
                    promptIsPending: false
                ),
                .prompt,
                "\(status)"
            )
        }
    }

    func testPendingPromptCancelsDuplicates() {
        for status in [ServerStatus.starting, .restarting, .running(pid: 1)] {
            XCTAssertEqual(
                QuitConfirmation.decision(
                    status: status,
                    preferenceEnabled: true,
                    promptIsPending: true
                ),
                .cancelDuplicate,
                "\(status)"
            )
        }
    }
}
