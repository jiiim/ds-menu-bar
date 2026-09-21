// SPDX-FileCopyrightText: Copyright James Martin and DS Menu Bar contributors
// SPDX-License-Identifier: MIT

import XCTest

@testable import dsmenubar

/// The full truth table behind every automatic restart. Getting a case wrong
/// has two visible failure modes: a restart loop the user did not ask for, or a
/// server left dead when one attempt would have recovered it.
final class AutoRestartPolicyTests: XCTestCase {

    func testRestartsOnlyWhenEnabledRestartableAndUnattempted() {
        let cases: [(preference: Bool, restartable: Bool, attempted: Bool,
                     expected: AutoRestartPolicy.Decision)] = [
            (true, true, false, .restart),
            (true, true, true, .report),
            (true, false, false, .report),
            (true, false, true, .report),
            (false, true, false, .report),
            (false, true, true, .report),
            (false, false, false, .report),
            (false, false, true, .report),
        ]
        for entry in cases {
            XCTAssertEqual(
                AutoRestartPolicy.decision(
                    preferenceEnabled: entry.preference,
                    restartable: entry.restartable,
                    attemptedThisEpisode: entry.attempted
                ),
                entry.expected,
                "preference=\(entry.preference) restartable=\(entry.restartable) "
                    + "attempted=\(entry.attempted)"
            )
        }
    }

    func testStabilityWindowIsFiveMinutes() {
        XCTAssertEqual(AutoRestartPolicy.stabilityWindow, 300)
    }
}
