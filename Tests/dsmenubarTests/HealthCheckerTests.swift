// SPDX-FileCopyrightText: Copyright James Martin and DS Menu Bar contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import XCTest

@testable import dsmenubar

/// HealthChecker decides whether a confirmed-healthy server gets killed, so the
/// interesting behaviour is all in its guards: the consecutive-failure
/// threshold, the generation stamp that discards superseded responses, and the
/// switch to the steady cadence once a startup succeeds. These drive a real
/// loopback HTTP server rather than stubbing URLSession, because the guards are
/// about real response timing.
@MainActor
final class HealthCheckerTests: XCTestCase {

    // MARK: - Loopback stub server

    /// A minimal HTTP/1.1 responder on an OS-assigned 127.0.0.1 port. Answers
    /// whatever `statusCode` is at the time the connection is accepted; set it
    /// to nil to accept and hang up without replying, which is what a server
    /// mid-crash looks like to the poller.
    private final class StubServer: @unchecked Sendable {
        private let listenFD: Int32
        let port: UInt16
        private let lock = NSLock()
        private var _statusCode: Int? = 200
        private var stopped = false
        /// Guards the reply so a test can run assertions while a request is
        /// genuinely in flight, rather than racing the response.
        private let gate = NSCondition()
        private var holdingResponses = false
        private var _requestsRead = 0

        var statusCode: Int? {
            get { lock.withLock { _statusCode } }
            set { lock.withLock { _statusCode = newValue } }
        }

        /// Requests whose line has been read — i.e. the poller really issued
        /// one, rather than being turned away by an earlier guard.
        var requestsRead: Int {
            gate.lock()
            defer { gate.unlock() }
            return _requestsRead
        }

        init() {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            precondition(fd >= 0, "socket() failed")
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = 0
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let bound = withUnsafePointer(to: &addr) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            precondition(bound == 0, "bind failed: \(errno)")
            precondition(listen(fd, 16) == 0, "listen failed: \(errno)")
            var assigned = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &assigned) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(fd, $0, &len)
                }
            }
            listenFD = fd
            port = assigned.sin_port.bigEndian

            Thread.detachNewThread { [self] in serve() }
        }

        private func serve() {
            while true {
                let client = accept(listenFD, nil, nil)
                if client < 0 {
                    if lock.withLock({ stopped }) { return }
                    continue
                }
                // Drain the request line so the client is not writing into a
                // socket nobody read before we reply.
                var buffer = [UInt8](repeating: 0, count: 1024)
                _ = recv(client, &buffer, buffer.count, 0)
                gate.lock()
                _requestsRead += 1
                while holdingResponses { gate.wait() }
                gate.unlock()
                if let code = statusCode {
                    let response = "HTTP/1.1 \(code) \(code == 200 ? "OK" : "Error")\r\n"
                        + "Content-Length: 0\r\nConnection: close\r\n\r\n"
                    _ = response.withCString { send(client, $0, strlen($0), 0) }
                }
                close(client)
                if lock.withLock({ stopped }) { return }
            }
        }

        var url: URL { URL(string: "http://127.0.0.1:\(port)/v1/models")! }

        /// Accept and read, but do not reply until `releaseResponses()`.
        func holdResponses() {
            gate.lock()
            holdingResponses = true
            gate.unlock()
        }

        func releaseResponses() {
            gate.lock()
            holdingResponses = false
            gate.broadcast()
            gate.unlock()
        }

        func stop() {
            lock.withLock { stopped = true }
            releaseResponses()
            close(listenFD)
        }
    }

    /// Spin the main run loop until `condition` holds or `timeout` elapses. The
    /// checker schedules all of its work onto the main queue, so a blocking wait
    /// would deadlock it.
    /// The generous default is for the waits that expect an event: the poll
    /// timer carries up to a second of leeway, so three polls at a one-second
    /// cadence can take six. Waits that expect *no* event pass an explicit short
    /// timeout, since those run to completion every time.
    private func spin(
        timeout: TimeInterval = 15,
        until condition: () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    // MARK: - Readiness

    func testHealthyServerReportsSuccessOnceAndSlowsToSteadyCadence() {
        let server = StubServer()
        defer { server.stop() }

        let checker = HealthChecker(fastInterval: 1, steadyInterval: 30)
        defer { checker.stop() }

        var successes = 0
        var startingUp = true
        checker.isStartingUp = { startingUp }
        checker.isRunning = { !startingUp }
        checker.onHealthSuccess = {
            successes += 1
            startingUp = false
        }
        checker.onUnreachable = { _ in XCTFail("a 200 response must not report unreachable") }

        checker.startPolling(url: server.url)
        spin { successes > 0 }
        XCTAssertEqual(successes, 1)

        // The steady cadence is 30s, so no second success can land in the time
        // a handful of fast-cadence polls would have taken.
        spin(timeout: 1.5) { successes > 1 }
        XCTAssertEqual(successes, 1, "readiness should be reported once per start")
    }

    // MARK: - Failure threshold

    func testUnreachableIsReportedOnlyAfterTheFullRunOfFailures() {
        let server = StubServer()
        server.statusCode = 500
        defer { server.stop() }

        let checker = HealthChecker(fastInterval: 1, failureThreshold: 3)
        defer { checker.stop() }

        var reports: [String] = []
        checker.isStartingUp = { false }
        checker.isRunning = { true }
        checker.onUnreachable = { reports.append($0) }

        checker.startPolling(url: server.url)
        spin { !reports.isEmpty }

        XCTAssertEqual(reports.count, 1)
        XCTAssertTrue(
            reports[0].contains("unreachable for 3 checks"),
            "expected the threshold in the message, got: \(reports[0])"
        )
    }

    func testASuccessBetweenFailuresResetsTheRun() {
        let server = StubServer()
        server.statusCode = 500
        defer { server.stop() }

        // A threshold of 3 with a success landing after the second failure: the
        // count must restart, so the two failures that follow cannot trip it.
        let checker = HealthChecker(fastInterval: 1, failureThreshold: 3)
        defer { checker.stop() }

        var failures = 0
        var reports = 0
        checker.isStartingUp = { false }
        checker.isRunning = { true }
        checker.onUnreachable = { _ in reports += 1 }

        // Count polls by watching the stub flip back and forth.
        checker.startPolling(url: server.url)
        spin(timeout: 3) {
            failures = checker.consecutiveFailures
            return failures >= 2
        }
        XCTAssertEqual(reports, 0, "two failures must not reach a threshold of three")

        server.statusCode = 200
        spin(timeout: 3) { checker.consecutiveFailures == 0 }
        XCTAssertEqual(
            checker.consecutiveFailures, 0,
            "a success must clear the failure run"
        )
        XCTAssertEqual(reports, 0)
    }

    // MARK: - Generation guard

    func testResponsesLandingAfterStopAreDiscarded() {
        let server = StubServer()
        server.statusCode = 500
        server.holdResponses()
        defer { server.stop() }

        let checker = HealthChecker(fastInterval: 1, failureThreshold: 1)
        defer { checker.stop() }

        var reports = 0
        checker.isStartingUp = { false }
        checker.isRunning = { true }
        checker.onUnreachable = { _ in reports += 1 }

        checker.startPolling(url: server.url)
        // Wait for a request the server is holding unanswered. Stopping before
        // one is in flight would test the nil-URL guard in `issueHealthRequest`
        // instead: no request, so no response for the generation stamp to
        // discard.
        spin { server.requestsRead > 0 }
        XCTAssertGreaterThan(server.requestsRead, 0, "no request was ever issued")

        // Supersede the run, then let the 500 it is waiting on come back.
        checker.stop()
        server.releaseResponses()

        spin(timeout: 1.5) { reports > 0 }
        XCTAssertEqual(reports, 0, "a response from a stopped run must not act")
    }

    // MARK: - Stall advisory

    func testStallAdvisoryFiresOnceAndPollingContinues() {
        let server = StubServer()
        server.statusCode = nil   // accept, never answer: a startup still loading
        defer { server.stop() }

        let checker = HealthChecker(fastInterval: 1, stallAdvisoryInterval: 0.1)
        defer { checker.stop() }

        var advisories = 0
        checker.isStartingUp = { true }
        checker.isRunning = { false }
        checker.onStartupStalled = { advisories += 1 }
        checker.onUnreachable = { _ in XCTFail("a starting server must not be reported unreachable") }

        checker.startPolling(url: server.url)
        spin { advisories > 0 }
        XCTAssertEqual(advisories, 1)

        // Still polling, and still only the one advisory.
        spin(timeout: 2) { advisories > 1 }
        XCTAssertEqual(advisories, 1, "the advisory is once per start, not per poll")
    }
}
