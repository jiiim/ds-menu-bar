// SPDX-FileCopyrightText: Copyright James Martin and DS Menu Bar contributors
// SPDX-License-Identifier: MIT

import XCTest

@testable import dsmenubar

/// The wording and the state rule behind the menu's last-activity line.
final class ServerActivityRecencyTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func ago(_ seconds: TimeInterval) -> String {
        ServerActivityRecency.describe(since: now.addingTimeInterval(-seconds), now: now)
    }

    func testUnusedUntilARequestArrives() {
        XCTAssertEqual(ServerActivityRecency.describe(since: nil, now: now), "unused")
    }

    func testBoundaries() {
        XCTAssertEqual(ago(0), "less than a minute ago")
        XCTAssertEqual(ago(59), "less than a minute ago")
        XCTAssertEqual(ago(60), "1 minute ago")
        XCTAssertEqual(ago(119), "1 minute ago")
        XCTAssertEqual(ago(120), "2 minutes ago")
        XCTAssertEqual(ago(3_599), "59 minutes ago")
        XCTAssertEqual(ago(3_600), "1 hour ago")
        XCTAssertEqual(ago(7_200), "2 hours ago")
        XCTAssertEqual(ago(86_399), "23 hours ago")
        XCTAssertEqual(ago(86_400), "1 day ago")
        XCTAssertEqual(ago(86_400 * 3), "3 days ago")
    }

    func testAFutureTimestampReadsAsTheMinimumAge() {
        XCTAssertEqual(
            ServerActivityRecency.describe(since: now.addingTimeInterval(120), now: now),
            "less than a minute ago"
        )
    }

    func testMenuTitleShowsTheValueOnlyWhileStarted() {
        let used = now.addingTimeInterval(-300)
        XCTAssertEqual(
            ServerActivityRecency.menuTitle(for: .starting, activity: nil, now: now),
            "Last activity: unused"
        )
        XCTAssertEqual(
            ServerActivityRecency.menuTitle(for: .running(pid: 1), activity: used, now: now),
            "Last activity: 5 minutes ago"
        )
        XCTAssertEqual(
            ServerActivityRecency.menuTitle(for: .stopped, activity: used, now: now),
            "Last activity: ---"
        )
        XCTAssertEqual(
            ServerActivityRecency.menuTitle(for: .stopping, activity: used, now: now),
            "Last activity: ---"
        )
        XCTAssertEqual(
            ServerActivityRecency.menuTitle(for: .restarting, activity: used, now: now),
            "Last activity: ---"
        )
        XCTAssertEqual(
            ServerActivityRecency.menuTitle(for: .error("boom"), activity: used, now: now),
            "Last activity: ---"
        )
    }
}
