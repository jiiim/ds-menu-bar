// SPDX-FileCopyrightText: Copyright James Martin and DS Menu Bar contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The current request phase and its average throughput as reported by
/// ds4-server. The menu-bar rendering is deliberately ten monospaced
/// characters wide so phase and rate changes never resize the status item.
struct ServerPerformance: Equatable {
    enum Phase: String {
        case idle = "-"
        case prefill = "P"
        case generation = "G"
    }

    let phase: Phase
    let tokensPerSecond: Double?

    static let idle = ServerPerformance(phase: .idle, tokensPerSecond: nil)

    var menuBarPhase: String {
        hasDisplayableRate ? phase.rawValue : Phase.idle.rawValue
    }

    var menuBarRate: String {
        hasDisplayableRate ? Self.rateField(tokensPerSecond) : "----"
    }

    var menuBarText: String {
        "\(menuBarPhase) \(menuBarRate) t/s"
    }

    var hasDisplayableRate: Bool {
        phase != .idle && Self.isDisplayable(tokensPerSecond)
    }

    /// The two rendered fields, which is everything the menu bar shows.
    /// ds4-server reports far more precision than four columns can display, so
    /// consecutive records routinely reduce to the same identity — and
    /// replacing one with another of those changes nothing on screen.
    struct DisplayIdentity: Equatable {
        let phase: String
        let rate: String
    }

    var displayIdentity: DisplayIdentity {
        DisplayIdentity(phase: menuBarPhase, rate: menuBarRate)
    }

    /// Four columns at every magnitude. Prefill rates can exceed 1,000 t/s,
    /// so compact notation avoids widening the menu-bar item on fast hardware.
    static func rateField(_ rate: Double?) -> String {
        guard let rate, isDisplayable(rate) else { return "----" }
        switch rate {
        case ..<99.95:
            return String(format: "%4.1f", locale: Locale(identifier: "en_US_POSIX"), rate)
        case ..<999.5:
            return String(format: "%4.0f", locale: Locale(identifier: "en_US_POSIX"), rate)
        case ..<9_950:
            return String(format: "%3.1fk", locale: Locale(identifier: "en_US_POSIX"), rate / 1_000)
        case ..<99_500:
            return String(format: "%3.0fk", locale: Locale(identifier: "en_US_POSIX"), rate / 1_000)
        default:
            return "99k+"
        }
    }

    private static func isDisplayable(_ rate: Double?) -> Bool {
        guard let rate else { return false }
        return rate.isFinite && rate >= 0
    }
}

/// When the menu bar is allowed to change, expressed without timers or a clock
/// so the transitions can be exercised directly. ServerManager owns the two
/// timers and performs whatever effects a decision returns.
///
/// ds4-server reports a rate per decoded chunk — tens of records per second on
/// a fast model — which is both unreadable and a needless stream of view
/// updates. So: publish a phase change at once, coalesce same-phase rate
/// changes to `publishInterval`, and when a request ends hold its final rate
/// for `holdInterval` instead of blanking the display immediately. A value that
/// renders to the same characters as the one already shown is not published at
/// all.
struct PerformanceDisplayPolicy {
    static let publishInterval: TimeInterval = 0.5
    static let holdInterval: TimeInterval = 1.5

    enum Effect: Equatable {
        case display(ServerPerformance)
        case schedulePublish(after: TimeInterval)
        case cancelPublish
        case scheduleIdle(after: TimeInterval)
        case cancelIdle
    }

    private(set) var displayed: ServerPerformance = .idle
    private var pending: ServerPerformance?
    private var lastPublish = Date.distantPast
    private var publishScheduled = false
    private var idleScheduled = false

    /// A record parsed out of the server log.
    mutating func receive(_ update: ServerPerformance, now: Date) -> [Effect] {
        if update == .idle {
            return holdBeforeIdle(now: now)
        }
        guard update.hasDisplayableRate else { return [] }

        var effects = cancelIdle()
        guard update.phase == displayed.phase else {
            // A phase change is the informative event; show it without waiting
            // out a coalescing window opened by the previous phase.
            return effects + cancelPublish() + publish(update, now: now)
        }

        let remaining = Self.publishInterval - now.timeIntervalSince(lastPublish)
        guard remaining > 0 else {
            // Publishing now supersedes anything still queued behind a timer
            // that has come due but not yet run.
            return effects + cancelPublish() + publish(update, now: now)
        }

        pending = update
        if !publishScheduled {
            publishScheduled = true
            effects.append(.schedulePublish(after: remaining))
        }
        return effects
    }

    mutating func publishTimerFired(now: Date) -> [Effect] {
        publishScheduled = false
        guard let update = pending else { return [] }
        pending = nil
        return publish(update, now: now)
    }

    mutating func idleTimerFired(now: Date) -> [Effect] {
        idleScheduled = false
        return publish(.idle, now: now)
    }

    /// The user turned the display off. Drop everything in flight.
    mutating func reset(now: Date) -> [Effect] {
        let effects = cancelPublish() + cancelIdle()
        guard displayed != .idle else { return effects }
        return effects + publish(.idle, now: now)
    }

    // MARK: - Private

    private mutating func holdBeforeIdle(now: Date) -> [Effect] {
        var effects: [Effect] = []
        if let queued = pending {
            // The request's final rate is the one worth showing; do not let a
            // coalescing window swallow it.
            effects += cancelPublish() + publish(queued, now: now)
        }
        // `displayed` only ever holds .idle or a value that passed
        // hasDisplayableRate, so this is the already-idle case: nothing to
        // hold, and nothing to blank.
        guard displayed.hasDisplayableRate else { return effects }
        guard !idleScheduled else { return effects }
        idleScheduled = true
        return effects + [.scheduleIdle(after: Self.holdInterval)]
    }

    private mutating func publish(
        _ update: ServerPerformance,
        now: Date
    ) -> [Effect] {
        let wasDisplaying = displayed.displayIdentity
        displayed = update
        lastPublish = now
        // The coalescing window is still consumed — this counts as the publish
        // for this interval — but a value that renders and reads identically
        // gives the menu bar nothing to redraw.
        guard update.displayIdentity != wasDisplaying else { return [] }
        return [.display(update)]
    }

    private mutating func cancelPublish() -> [Effect] {
        pending = nil
        guard publishScheduled else { return [] }
        publishScheduled = false
        return [.cancelPublish]
    }

    private mutating func cancelIdle() -> [Effect] {
        guard idleScheduled else { return [] }
        idleScheduled = false
        return [.cancelIdle]
    }
}

/// Incremental line parser for the performance records ds4-server writes to
/// stderr. It retains a partial final line because a filesystem write event is
/// not a promise that the newest line was written in one operation.
struct ServerPerformanceLogParser {
    private var buffered = Data()

    mutating func ingest(_ data: Data) -> [ServerPerformance] {
        buffered.append(data)
        var updates: [ServerPerformance] = []

        while let newline = buffered.firstIndex(of: 0x0a) {
            let lineData = buffered[..<newline]
            buffered.removeSubrange(...newline)
            let line = String(decoding: lineData, as: UTF8.self)
            if let update = Self.parse(line) {
                updates.append(update)
            }
        }
        return updates
    }

    mutating func reset() {
        buffered.removeAll(keepingCapacity: true)
    }

    private static func parse(_ line: String) -> ServerPerformance? {
        guard line.contains("ds4-server:") else { return nil }

        if line.contains(" decoding chunk="), let rate = averageRate(in: line) {
            return ServerPerformance(phase: .generation, tokensPerSecond: rate)
        }
        if line.contains(" chunk "), line.contains("/"),
           let rate = averageRate(in: line) {
            return ServerPerformance(phase: .prefill, tokensPerSecond: rate)
        }
        if (line.contains(" gen=") && line.contains(" finish=")) ||
            line.contains("shutdown requested") {
            return .idle
        }
        return nil
    }

    private static func averageRate(in line: String) -> Double? {
        guard let start = line.range(of: " avg=")?.upperBound,
              let end = line[start...].range(of: " t/s")?.lowerBound,
              let value = Double(line[start..<end]),
              value.isFinite,
              value >= 0
        else { return nil }
        return value
    }
}

/// Reads only bytes appended after monitoring starts. Rotation and log clearing
/// truncate the active inode, so a smaller file resets both the offset and any
/// partial line left by the prior contents.
///
/// Unchecked because the confinement is by queue, not by type: every caller in
/// ProcessManager touches this only inside `performanceQueue.async`, which is
/// serial, so the file handle, offset, and parser are never reached
/// concurrently. Any new call site must hold to that.
final class ServerPerformanceLogReader: @unchecked Sendable {
    private var handle: FileHandle?
    private var offset: UInt64 = 0
    private var parser = ServerPerformanceLogParser()

    func start(path: String) {
        stop()
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)),
              let end = try? handle.seekToEnd()
        else { return }
        self.handle = handle
        offset = end
    }

    func readAvailable() -> [ServerPerformance] {
        guard let handle else { return [] }
        do {
            let end = try handle.seekToEnd()
            if end < offset {
                offset = 0
                parser.reset()
            }
            guard end > offset else { return [] }
            try handle.seek(toOffset: offset)
            let data = try handle.readToEnd() ?? Data()
            offset += UInt64(data.count)
            return parser.ingest(data)
        } catch {
            return []
        }
    }

    func rewind() {
        offset = 0
        parser.reset()
    }

    func stop() {
        try? handle?.close()
        handle = nil
        offset = 0
        parser.reset()
    }
}
