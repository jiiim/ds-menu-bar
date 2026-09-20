// SPDX-FileCopyrightText: Copyright James Martin and DS Menu Bar contributors
// SPDX-License-Identifier: MIT

import AppKit
import CoreText
import Foundation
import XCTest

@testable import dsmenubar

final class ServerPerformanceTests: XCTestCase {
    func testParsesPhasesRatesAndPartialLines() {
        var parser = ServerPerformanceLogParser()

        XCTAssertEqual(
            parser.ingest(Data("0915 23:05:02 ds4-server: chat ctx=0..882:882 prompt start\n".utf8)),
            []
        )

        let prefill = "0915 23:05:04 ds4-server: chat ctx=0..882:882 prefill chunk "
            + "882/882 (100.0%) chunk=0.00 t/s avg=388.30 t/s 2.271s\n"
        XCTAssertEqual(
            parser.ingest(Data(prefill.utf8)),
            [ServerPerformance(phase: .prefill, tokensPerSecond: 388.30)]
        )

        let firstHalf = "0915 23:05:05 ds4-server: chat ctx=882..932:50 gen=50 "
            + "decoding chunk=37.54 t/s avg=37."
        XCTAssertTrue(parser.ingest(Data(firstHalf.utf8)).isEmpty)
        XCTAssertEqual(
            parser.ingest(Data("54 t/s 1.332s\n".utf8)),
            [ServerPerformance(phase: .generation, tokensPerSecond: 37.54)]
        )

        XCTAssertEqual(
            parser.ingest(Data(
                "0915 23:05:12 ds4-server: chat ctx=0..882:882 gen=318 finish=stop 10.610s\n".utf8
            )),
            [.idle]
        )
        XCTAssertEqual(
            parser.ingest(Data(
                "0915 23:05:13 ds4-server: shutdown requested, draining requests\n".utf8
            )),
            [.idle]
        )
    }

    func testIgnoresUnrelatedAndMisleadingLines() {
        var parser = ServerPerformanceLogParser()
        let lines = """
        ds4: GLM compact indexed prefill chunk=2048 score_rows=1024
        0915 23:05:04 ds4-server: chat ctx=0..10:10 prompt done 1.0s
        0915 23:05:05 ds4-server: chat ctx=0..10:10 invalid tool call finish=stop
        """
        XCTAssertTrue(parser.ingest(Data((lines + "\n").utf8)).isEmpty)
    }

    func testMenuBarTextIsFixedWidth() {
        let values = [
            ServerPerformance.idle,
            ServerPerformance(phase: .prefill, tokensPerSecond: nil),
            ServerPerformance(phase: .generation, tokensPerSecond: .nan),
            ServerPerformance(phase: .prefill, tokensPerSecond: 8.4),
            ServerPerformance(phase: .generation, tokensPerSecond: 36.7),
            ServerPerformance(phase: .prefill, tokensPerSecond: 629),
            ServerPerformance(phase: .prefill, tokensPerSecond: 1_234),
            ServerPerformance(phase: .prefill, tokensPerSecond: 12_345),
        ]

        XCTAssertEqual(values.map(\.menuBarText), [
            "- ---- t/s",
            "- ---- t/s",
            "- ---- t/s",
            "P  8.4 t/s",
            "G 36.7 t/s",
            "P  629 t/s",
            "P 1.2k t/s",
            "P  12k t/s",
        ])
        XCTAssertTrue(values.allSatisfy { $0.menuBarText.count == 10 })
    }

    @MainActor
    func testRenderedMenuBarFieldsKeepEveryGlyphPosition() {
        let values = [
            ServerPerformance.idle,
            ServerPerformance(phase: .prefill, tokensPerSecond: 8.4),
            ServerPerformance(phase: .generation, tokensPerSecond: 36.7),
            ServerPerformance(phase: .prefill, tokensPerSecond: 629),
            ServerPerformance(phase: .prefill, tokensPerSecond: 1_234),
            ServerPerformance(phase: .prefill, tokensPerSecond: 12_345),
        ]
        let positions = values.map {
            glyphPositions(in: StatusBarTitle.make(glyph: "✦", performance: $0))
        }

        XCTAssertTrue(positions.allSatisfy { $0.count == positions[0].count })
        for candidate in positions.dropFirst() {
            XCTAssertEqual(candidate, positions[0])
        }
    }

    private func glyphPositions(in title: NSAttributedString) -> [CGFloat] {
        let line = CTLineCreateWithAttributedString(title)
        return (0..<title.length).map {
            CGFloat(CTLineGetOffsetForStringIndex(line, $0, nil))
        } + [CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))]
    }

    // MARK: - Display policy

    /// The rate field holds four columns, so ds4-server's extra precision is
    /// discarded before anything is drawn. Two records that reduce to the same
    /// characters are the same value as far as the user is concerned.
    func testDisplayIdentityIgnoresPrecisionTheFieldsCannotShow() {
        let coarse = ServerPerformance(phase: .generation, tokensPerSecond: 12.31)
        let finer = ServerPerformance(phase: .generation, tokensPerSecond: 12.34)
        XCTAssertNotEqual(coarse, finer)
        XCTAssertEqual(coarse.displayIdentity, finer.displayIdentity)

        let fast = ServerPerformance(phase: .prefill, tokensPerSecond: 388.30)
        let faster = ServerPerformance(phase: .prefill, tokensPerSecond: 388.40)
        XCTAssertEqual(fast.displayIdentity, faster.displayIdentity)

        let changed = ServerPerformance(phase: .generation, tokensPerSecond: 13.31)
        XCTAssertNotEqual(coarse.displayIdentity, changed.displayIdentity)
        // Same rate, different phase: the glyph changes even though the field
        // does not.
        XCTAssertNotEqual(
            coarse.displayIdentity,
            ServerPerformance(phase: .prefill, tokensPerSecond: 12.31).displayIdentity
        )
    }

    /// A converged average produces a record every few dozen milliseconds that
    /// renders to the same four characters. Publishing those redrew the status
    /// item twice a second to no visible effect.
    func testPolicySuppressesAPublishThatChangesNothingOnScreen() {
        var policy = PerformanceDisplayPolicy()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let shown = ServerPerformance(phase: .generation, tokensPerSecond: 30.0)
        let indistinguishable = ServerPerformance(phase: .generation, tokensPerSecond: 30.04)
        let different = ServerPerformance(phase: .generation, tokensPerSecond: 31.0)

        XCTAssertEqual(policy.receive(shown, now: start), [.display(shown)])
        // The coalescing window has elapsed, so this takes the publish path
        // and is dropped there rather than being queued.
        XCTAssertEqual(policy.receive(indistinguishable, now: start.addingTimeInterval(0.5)), [])
        XCTAssertEqual(policy.displayed, indistinguishable)

        // The suppressed publish still consumed the window, so a value that
        // does change the display is coalesced against it.
        XCTAssertEqual(
            policy.receive(different, now: start.addingTimeInterval(0.75)),
            [.schedulePublish(after: 0.25)]
        )
        XCTAssertEqual(
            policy.publishTimerFired(now: start.addingTimeInterval(1)),
            [.display(different)]
        )
    }

    func testPolicyPublishesAPhaseChangeWithoutWaitingOutTheWindow() {
        var policy = PerformanceDisplayPolicy()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let prefill = ServerPerformance(phase: .prefill, tokensPerSecond: 400)
        let generation = ServerPerformance(phase: .generation, tokensPerSecond: 30)

        XCTAssertEqual(policy.receive(prefill, now: start), [.display(prefill)])
        // Well inside the 0.5s coalescing window opened by the publish above.
        XCTAssertEqual(
            policy.receive(generation, now: start.addingTimeInterval(0.1)),
            [.display(generation)]
        )
        XCTAssertEqual(policy.displayed, generation)
    }

    func testPolicyCoalescesSamePhaseRatesAndPublishesTheNewest() {
        var policy = PerformanceDisplayPolicy()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let first = ServerPerformance(phase: .generation, tokensPerSecond: 30)
        let second = ServerPerformance(phase: .generation, tokensPerSecond: 31)
        let third = ServerPerformance(phase: .generation, tokensPerSecond: 32)

        XCTAssertEqual(policy.receive(first, now: start), [.display(first)])
        XCTAssertEqual(
            policy.receive(second, now: start.addingTimeInterval(0.1)),
            [.schedulePublish(after: 0.4)]
        )
        // Already scheduled: a further update replaces the queued value
        // without arming a second timer.
        XCTAssertEqual(policy.receive(third, now: start.addingTimeInterval(0.2)), [])
        XCTAssertEqual(policy.displayed, first)

        XCTAssertEqual(
            policy.publishTimerFired(now: start.addingTimeInterval(0.5)),
            [.display(third)]
        )
        XCTAssertEqual(policy.displayed, third)
    }

    /// A timer that has come due but not yet run must not publish its stale
    /// value over an update that arrived in the meantime.
    func testPolicyDiscardsAQueuedValueSupersededByADirectPublish() {
        var policy = PerformanceDisplayPolicy()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let first = ServerPerformance(phase: .generation, tokensPerSecond: 30)
        let queued = ServerPerformance(phase: .generation, tokensPerSecond: 31)
        let latest = ServerPerformance(phase: .generation, tokensPerSecond: 32)

        XCTAssertEqual(policy.receive(first, now: start), [.display(first)])
        XCTAssertEqual(
            policy.receive(queued, now: start.addingTimeInterval(0.1)),
            [.schedulePublish(after: 0.4)]
        )
        XCTAssertEqual(
            policy.receive(latest, now: start.addingTimeInterval(0.6)),
            [.cancelPublish, .display(latest)]
        )
        XCTAssertEqual(policy.publishTimerFired(now: start.addingTimeInterval(0.6)), [])
        XCTAssertEqual(policy.displayed, latest)
    }

    func testPolicyHoldsTheFinalRateOfARequestBeforeGoingIdle() {
        var policy = PerformanceDisplayPolicy()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let rate = ServerPerformance(phase: .generation, tokensPerSecond: 30)
        let final = ServerPerformance(phase: .generation, tokensPerSecond: 31)

        XCTAssertEqual(policy.receive(rate, now: start), [.display(rate)])
        XCTAssertEqual(
            policy.receive(final, now: start.addingTimeInterval(0.1)),
            [.schedulePublish(after: 0.4)]
        )
        // The request ends while the last measurement is still queued: flush
        // it, then start the hold.
        XCTAssertEqual(
            policy.receive(.idle, now: start.addingTimeInterval(0.2)),
            [.cancelPublish, .display(final), .scheduleIdle(after: 1.5)]
        )
        // A second finish record does not restart the hold.
        XCTAssertEqual(policy.receive(.idle, now: start.addingTimeInterval(0.3)), [])
        XCTAssertEqual(policy.displayed, final)

        XCTAssertEqual(
            policy.idleTimerFired(now: start.addingTimeInterval(1.7)),
            [.display(.idle)]
        )
        XCTAssertEqual(policy.displayed, .idle)
    }

    func testPolicyCancelsAPendingHoldWhenTheNextRequestStarts() {
        var policy = PerformanceDisplayPolicy()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let generation = ServerPerformance(phase: .generation, tokensPerSecond: 30)
        let prefill = ServerPerformance(phase: .prefill, tokensPerSecond: 400)

        XCTAssertEqual(policy.receive(generation, now: start), [.display(generation)])
        XCTAssertEqual(
            policy.receive(.idle, now: start.addingTimeInterval(0.1)),
            [.scheduleIdle(after: 1.5)]
        )
        XCTAssertEqual(
            policy.receive(prefill, now: start.addingTimeInterval(0.2)),
            [.cancelIdle, .display(prefill)]
        )
    }

    func testPolicyIgnoresIdleWhenNothingIsDisplayedAndUnusableRates() {
        var policy = PerformanceDisplayPolicy()
        let start = Date(timeIntervalSinceReferenceDate: 0)

        XCTAssertEqual(policy.receive(.idle, now: start), [])
        XCTAssertEqual(
            policy.receive(
                ServerPerformance(phase: .generation, tokensPerSecond: nil),
                now: start
            ),
            []
        )
        XCTAssertEqual(
            policy.receive(
                ServerPerformance(phase: .prefill, tokensPerSecond: .infinity),
                now: start
            ),
            []
        )
        XCTAssertEqual(policy.displayed, .idle)
    }

    func testPolicyResetDropsEverythingInFlight() {
        var policy = PerformanceDisplayPolicy()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let rate = ServerPerformance(phase: .generation, tokensPerSecond: 30)

        XCTAssertEqual(policy.receive(rate, now: start), [.display(rate)])
        XCTAssertEqual(
            policy.receive(
                ServerPerformance(phase: .generation, tokensPerSecond: 31),
                now: start.addingTimeInterval(0.1)
            ),
            [.schedulePublish(after: 0.4)]
        )
        XCTAssertEqual(
            policy.receive(.idle, now: start.addingTimeInterval(0.2)),
            [
                .cancelPublish,
                .display(ServerPerformance(phase: .generation, tokensPerSecond: 31)),
                .scheduleIdle(after: 1.5),
            ]
        )

        XCTAssertEqual(
            policy.reset(now: start.addingTimeInterval(0.3)),
            [.cancelIdle, .display(.idle)]
        )
        XCTAssertEqual(policy.reset(now: start.addingTimeInterval(0.4)), [])
    }

    func testReaderStartsAtEOFAndHandlesTruncation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsmenubar-performance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let log = directory.appendingPathComponent("server.log")
        try Data("old output\n".utf8).write(to: log)
        let writer = try FileHandle(forWritingTo: log)
        defer { try? writer.close() }

        let reader = ServerPerformanceLogReader()
        reader.start(path: log.path)
        XCTAssertTrue(reader.readAvailable().isEmpty)

        try writer.seekToEnd()
        try writer.write(contentsOf: Data(
            "ds4-server: chat ctx=0..10:10 prompt start\n".utf8
        ))
        XCTAssertEqual(
            reader.readAvailable(),
            []
        )

        try writer.truncate(atOffset: 0)
        reader.rewind()
        try writer.write(contentsOf: Data(
            "ds4-server: chat ctx=10..60:50 gen=50 decoding chunk=30.0 t/s avg=29.5 t/s 1.0s\n".utf8
        ))
        XCTAssertEqual(
            reader.readAvailable(),
            [ServerPerformance(phase: .generation, tokensPerSecond: 29.5)]
        )
    }
}
