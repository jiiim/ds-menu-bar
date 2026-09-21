// SPDX-FileCopyrightText: Copyright James Martin and DS Menu Bar contributors
// SPDX-License-Identifier: MIT

import Darwin
import XCTest

@testable import dsmenubar

/// Live orchestration tests. ServerManager owns its collaborators in the app,
/// so these inject a suite-backed configuration, short process graces, a
/// one-second health cadence, a short stability window, and a notification
/// counter. A loopback stub serves the health endpoint; the child process is a
/// script that never binds the port, so the stub owns it.
@MainActor
final class ServerManagerTests: XCTestCase {

    // MARK: - Harness

    private final class NotificationLog {
        private(set) var entries: [(title: String, body: String)] = []

        func record(title: String, body: String) {
            entries.append((title: title, body: body))
        }
    }

    @MainActor
    private final class Harness {
        let manager: ServerManager
        let stub: LoopbackStubServer
        let notifications = NotificationLog()
        let directory: URL
        let logPath: String
        let readyMarker: URL
        let pidFile: URL
        private let suiteName: String

        init(
            autoRestart: Bool?,
            ignoresSigterm: Bool,
            cleanExitOnSigterm: Bool = false,
            forceKillGrace: TimeInterval,
            portWaitTimeout: TimeInterval,
            stabilityWindow: TimeInterval
        ) throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("dsmenubar-manager-\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            readyMarker = directory.appendingPathComponent("ready")
            pidFile = directory.appendingPathComponent("pid")

            let serverURL = directory.appendingPathComponent("ds4-server")
            let body: String
            if ignoresSigterm {
                body = "trap '' TERM\nexec /bin/sleep 60"
            } else if cleanExitOnSigterm {
                // What ds4-server does on SIGTERM: shut down cleanly, status 0.
                body = """
                trap 'exit 0' TERM
                echo $$ > '\(pidFile.path)'
                touch '\(readyMarker.path)'
                while true; do /bin/sleep 0.05; done
                """
            } else {
                body = "exec /bin/sleep 60"
            }
            try Data("#!/bin/sh\n\(body)\n".utf8).write(to: serverURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: serverURL.path
            )
            let modelURL = directory.appendingPathComponent("model.gguf")
            try ServerManagerTests.makeGGUF(architecture: "glm5-next").write(to: modelURL)

            stub = LoopbackStubServer()
            suiteName = "dsmenubar-manager-tests-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))

            let configuration = ServerConfiguration(defaults: defaults)
            if let autoRestart {
                configuration.setAutoRestartServer(autoRestart)
            }
            var config = ServerConfiguration.Config()
            config.serverPath = serverURL.path
            config.modelPath = modelURL.path
            config.host = "127.0.0.1"
            config.port = Int(stub.port)
            config.logPath = directory.appendingPathComponent("server.log").path
            config.kvDiskEnabled = false
            configuration.replace(with: config)
            logPath = config.logPath

            let notificationLog = notifications
            manager = ServerManager(
                config: configuration,
                processManager: ProcessManager(
                    forceKillGrace: forceKillGrace,
                    portWaitTimeout: portWaitTimeout
                ),
                healthChecker: HealthChecker(
                    fastInterval: 1,
                    steadyInterval: 1,
                    stallAdvisoryInterval: 3_600,
                    failureThreshold: 3
                ),
                stabilityWindow: stabilityWindow,
                notificationSink: { title, body in
                    notificationLog.record(title: title, body: body)
                }
            )
        }

        /// Launches recorded in the server log; each launch writes one header.
        func launchCount() -> Int {
            guard let log = try? String(contentsOfFile: logPath, encoding: .utf8) else {
                return 0
            }
            return log.components(separatedBy: "=== dsmenubar launch").count - 1
        }

        func shutDown() {
            manager.stop()
            stub.stop()
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// Spin the main run loop until `condition` holds or `timeout` elapses; a
    /// blocking wait would deadlock the main-queue work these tests drive.
    private func spin(timeout: TimeInterval = 12, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    private func waitFor(
        _ matches: (ServerStatus) -> Bool,
        on manager: ServerManager,
        timeout: TimeInterval = 12
    ) {
        spin(timeout: timeout) { matches(manager.status) }
    }

    private func isRunning(_ status: ServerStatus) -> Bool {
        if case .running = status { return true }
        return false
    }

    // MARK: - Tests

    func testUnresponsiveServerIsRestartedOnce() throws {
        let harness = try Harness(
            autoRestart: nil,
            ignoresSigterm: false,
            forceKillGrace: 0.5,
            portWaitTimeout: 0.5,
            stabilityWindow: 300
        )
        defer { harness.shutDown() }

        harness.stub.statusCode = 200
        harness.manager.start()
        waitFor(isRunning, on: harness.manager)
        XCTAssertTrue(isRunning(harness.manager.status))
        XCTAssertEqual(harness.launchCount(), 1)

        harness.stub.statusCode = 500
        waitFor({ $0 == .stopping }, on: harness.manager)
        XCTAssertEqual(harness.manager.status, .stopping)
        waitFor({ $0 == .restarting }, on: harness.manager)
        XCTAssertEqual(harness.manager.status, .restarting)

        // Answer again before the replacement's polls: one 500 in that run is
        // below the threshold.
        harness.stub.statusCode = 200
        waitFor(isRunning, on: harness.manager)
        XCTAssertTrue(isRunning(harness.manager.status))
        XCTAssertEqual(harness.launchCount(), 2, "exactly one automatic relaunch")
        XCTAssertEqual(harness.notifications.entries.count, 1)
        XCTAssertEqual(harness.notifications.entries.first?.title, "ds4-server was unresponsive")
        XCTAssertEqual(
            harness.notifications.entries.first?.body.contains("has been restarted"),
            true
        )
    }

    func testSecondFailureInsideTheWindowIsReportedWithoutAnotherRestart() throws {
        let harness = try Harness(
            autoRestart: nil,
            ignoresSigterm: false,
            forceKillGrace: 0.5,
            portWaitTimeout: 0.5,
            stabilityWindow: 300
        )
        defer { harness.shutDown() }

        harness.stub.statusCode = 200
        harness.manager.start()
        waitFor(isRunning, on: harness.manager)

        harness.stub.statusCode = 500
        waitFor({ $0 == .restarting }, on: harness.manager)
        harness.stub.statusCode = 200
        waitFor(isRunning, on: harness.manager)
        XCTAssertEqual(harness.launchCount(), 2)

        // The second failure arrives before a replacement has been healthy for
        // the stability window, so the episode is spent.
        harness.stub.statusCode = 500
        waitFor({ if case .error = $0 { return true }; return false }, on: harness.manager)
        guard case .error(let reason) = harness.manager.status else {
            XCTFail("expected .error")
            return
        }
        XCTAssertTrue(reason.contains("unreachable"), reason)

        spin(timeout: 2) { harness.launchCount() > 2 }
        XCTAssertEqual(harness.launchCount(), 2, "a spent episode must not restart again")
        guard case .error = harness.manager.status else {
            XCTFail("expected .error")
            return
        }
        XCTAssertEqual(harness.notifications.entries.count, 2)
        XCTAssertEqual(
            harness.notifications.entries.last?.body.contains("Automatic restart is not repeating."),
            true
        )
    }

    func testCancellingDuringTheAutoRestartWindowLeavesItStopped() throws {
        let harness = try Harness(
            autoRestart: nil,
            ignoresSigterm: false,
            forceKillGrace: 0.5,
            portWaitTimeout: 2.0,
            stabilityWindow: 300
        )
        defer { harness.shutDown() }

        harness.stub.statusCode = 200
        harness.manager.start()
        waitFor(isRunning, on: harness.manager)

        harness.stub.statusCode = 500
        waitFor({ $0 == .restarting }, on: harness.manager)
        harness.manager.stop()
        XCTAssertEqual(harness.manager.status, .stopped)

        // The port-wait timer is still armed; its callback must be dropped, and
        // the pending restart notice must not survive the cancellation.
        spin(timeout: 3) { harness.launchCount() > 1 }
        XCTAssertEqual(harness.launchCount(), 1)
        XCTAssertEqual(harness.manager.status, .stopped)
        XCTAssertTrue(harness.notifications.entries.isEmpty)
    }

    func testManualStopDuringTheGraceLeavesItStoppedAndSilent() throws {
        let harness = try Harness(
            autoRestart: nil,
            ignoresSigterm: true,
            forceKillGrace: 2.0,
            portWaitTimeout: 0.5,
            stabilityWindow: 300
        )
        defer { harness.shutDown() }

        harness.stub.statusCode = 200
        harness.manager.start()
        waitFor(isRunning, on: harness.manager)

        harness.stub.statusCode = 500
        waitFor({ $0 == .stopping }, on: harness.manager)
        let requestsAtDecision = harness.stub.requestsRead
        harness.manager.stop()
        XCTAssertEqual(harness.manager.status, .stopping, "the frozen child is still alive")

        // Past the grace the forced kill lands; the reaper must call it a user
        // stop: no notification, no relaunch.
        waitFor({ $0 == .stopped }, on: harness.manager, timeout: 6)
        XCTAssertEqual(harness.manager.status, .stopped)
        spin(timeout: 2) { harness.stub.requestsRead > requestsAtDecision }
        XCTAssertEqual(harness.stub.requestsRead, requestsAtDecision, "polling must stay stopped")
        XCTAssertEqual(harness.launchCount(), 1)
        XCTAssertTrue(harness.notifications.entries.isEmpty)
    }

    func testAutoRestartOffReportsAndNeverRelaunches() throws {
        let harness = try Harness(
            autoRestart: false,
            ignoresSigterm: false,
            forceKillGrace: 0.5,
            portWaitTimeout: 0.5,
            stabilityWindow: 300
        )
        defer { harness.shutDown() }

        harness.stub.statusCode = 200
        harness.manager.start()
        waitFor(isRunning, on: harness.manager)

        harness.stub.statusCode = 500
        waitFor({ if case .error = $0 { return true }; return false }, on: harness.manager)
        spin(timeout: 2) { harness.launchCount() > 1 }
        XCTAssertEqual(harness.launchCount(), 1)
        XCTAssertEqual(harness.notifications.entries.count, 1)
        XCTAssertEqual(harness.notifications.entries.first?.title, "ds4-server stopped")
        XCTAssertEqual(
            harness.notifications.entries.first?.body.contains("Automatic restart is off."),
            true
        )
        XCTAssertEqual(
            harness.notifications.entries.first?.body.contains("not repeating"),
            false,
            "a disabled preference must not claim a spent episode"
        )
    }

    func testAStaleStabilityItemDoesNotClearANewerRunsEpisode() throws {
        let harness = try Harness(
            autoRestart: nil,
            ignoresSigterm: false,
            forceKillGrace: 0.5,
            portWaitTimeout: 0.5,
            stabilityWindow: 8
        )
        defer { harness.shutDown() }

        harness.stub.statusCode = 200
        harness.manager.start()
        waitFor(isRunning, on: harness.manager)
        let firstHealthyAt = Date()

        // First incident restarts automatically into run B.
        harness.stub.statusCode = 500
        waitFor({ $0 == .restarting }, on: harness.manager)
        harness.stub.statusCode = 200
        waitFor(isRunning, on: harness.manager)
        XCTAssertEqual(harness.launchCount(), 2)

        // Let run A's stability item fire while B is still running, before B's
        // own window closes.
        spin(timeout: 12) { Date().timeIntervalSince(firstHealthyAt) >= 8.5 }
        XCTAssertTrue(isRunning(harness.manager.status), "B must still be running when A's item fires")

        harness.stub.statusCode = 500
        waitFor({ if case .error = $0 { return true }; return false }, on: harness.manager)
        spin(timeout: 2) { harness.launchCount() > 2 }
        XCTAssertEqual(harness.launchCount(), 2, "A's stale item must not clear B's episode")
        XCTAssertEqual(harness.notifications.entries.count, 2)
    }

    func testAnExternallyTerminatedServerIsRestarted() throws {
        let harness = try Harness(
            autoRestart: nil,
            ignoresSigterm: false,
            cleanExitOnSigterm: true,
            forceKillGrace: 0.5,
            portWaitTimeout: 0.5,
            stabilityWindow: 300
        )
        defer { harness.shutDown() }

        harness.stub.statusCode = 200
        harness.manager.start()
        waitFor(isRunning, on: harness.manager)

        // The script exits 0 when SIGTERM arrives, which is what ds4-server
        // does; `pkill` is therefore a clean exit the app did not request.
        spin(timeout: 5) { FileManager.default.fileExists(atPath: harness.pidFile.path) }
        let pidText = try String(contentsOfFile: harness.pidFile.path, encoding: .utf8)
        let pid = try XCTUnwrap(Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(kill(pid, SIGTERM), 0)

        // It must be reported and restarted, not silently left stopped.
        waitFor({ $0 == .restarting }, on: harness.manager)
        waitFor(isRunning, on: harness.manager)
        XCTAssertEqual(harness.launchCount(), 2)
        XCTAssertEqual(harness.notifications.entries.count, 1)
        XCTAssertEqual(
            harness.notifications.entries.first?.title,
            "ds4-server stopped unexpectedly"
        )
        XCTAssertEqual(
            harness.notifications.entries.first?.body.contains("has been restarted"),
            true
        )
    }

    func testAManualStartResetsTheAutoRestartLedger() throws {
        let harness = try Harness(
            autoRestart: nil,
            ignoresSigterm: false,
            forceKillGrace: 0.5,
            portWaitTimeout: 0.5,
            stabilityWindow: 300
        )
        defer { harness.shutDown() }

        // Spend the episode: one automatic restart, then a second failure that
        // is reported instead of repeated.
        harness.stub.statusCode = 200
        harness.manager.start()
        waitFor(isRunning, on: harness.manager)
        harness.stub.statusCode = 500
        waitFor({ $0 == .restarting }, on: harness.manager)
        harness.stub.statusCode = 200
        waitFor(isRunning, on: harness.manager)
        harness.stub.statusCode = 500
        waitFor({ if case .error = $0 { return true }; return false }, on: harness.manager)
        XCTAssertEqual(harness.launchCount(), 2)

        // The hand-started run earns a fresh attempt even though the stability
        // window never elapsed.
        harness.stub.statusCode = 200
        harness.manager.start()
        waitFor(isRunning, on: harness.manager)
        XCTAssertEqual(harness.launchCount(), 3)

        harness.stub.statusCode = 500
        waitFor({ $0 == .restarting }, on: harness.manager)
        harness.stub.statusCode = 200
        waitFor(isRunning, on: harness.manager)
        XCTAssertEqual(harness.launchCount(), 4, "the manual start must clear the ledger")
    }

    // MARK: - GGUF helper

    private static func makeGGUF(architecture: String, version: UInt32 = 3) -> Data {
        var data = Data([0x47, 0x47, 0x55, 0x46])
        append(version, to: &data)
        append(UInt64(0), to: &data)
        append(UInt64(1), to: &data)
        append(utf8: "general.architecture", to: &data)
        append(UInt32(8), to: &data)
        append(utf8: architecture, to: &data)
        return data
    }

    private static func append(utf8 value: String, to data: inout Data) {
        let bytes = Array(value.utf8)
        append(UInt64(bytes.count), to: &data)
        data.append(contentsOf: bytes)
    }

    private static func append(_ value: UInt32, to data: inout Data) {
        data.append(contentsOf: withUnsafeBytes(of: value.littleEndian, Array.init))
    }

    private static func append(_ value: UInt64, to data: inout Data) {
        data.append(contentsOf: withUnsafeBytes(of: value.littleEndian, Array.init))
    }
}
