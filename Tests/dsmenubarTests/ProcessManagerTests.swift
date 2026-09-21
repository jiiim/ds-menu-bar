// SPDX-FileCopyrightText: Copyright James Martin and DS Menu Bar contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest

@testable import dsmenubar

@MainActor
final class ProcessManagerTests: XCTestCase {
    func testLaunchFailureReasonIgnoresHelpTextAfterParserError() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsmenubar-launch-error-\(UUID().uuidString)")
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let logURL = directory.appendingPathComponent("server.log")
        let log = """
        === dsmenubar launch 2026-09-15 19:40:57 ===
        exec: /tmp/ds4-server
        cwd:  /tmp
        argv: --ple bogus.gguf
        ---
        0915 19:40:57 ds4-server: unknown option: --ple
        ds4-server
        Serve one loaded DwarfStar model through an HTTP API.

        Usage: ds4-server [options]
        Examples
          curl http://127.0.0.1:8000/v1/models
        """
        try Data(log.utf8).write(to: logURL)

        XCTAssertEqual(
            ProcessManager().launchFailureReason(logPath: logURL.path),
            "0915 19:40:57 ds4-server: unknown option: --ple"
        )
    }

    func testRunningProcessRotatesLogAtConfiguredSize() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsmenubar-live-log-rotate-\(UUID().uuidString)")
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let serverURL = directory.appendingPathComponent("ds4-server")
        let script = """
        #!/bin/sh
        /bin/sleep 0.2
        /usr/bin/head -c 1200000 /dev/zero
        exec /bin/sleep 10
        """
        try Data(script.utf8).write(to: serverURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: serverURL.path)

        let modelURL = directory.appendingPathComponent("model.gguf")
        try makeGGUF(architecture: "glm5-next").write(to: modelURL)
        let logURL = directory.appendingPathComponent("server.log")
        let backupURL = directory.appendingPathComponent("server.log.1")

        var configuration = ServerConfiguration.Config()
        configuration.serverPath = serverURL.path
        configuration.modelPath = modelURL.path
        configuration.logPath = logURL.path
        configuration.logMaxSizeMB = 1

        let manager = ProcessManager()
        let terminated = expectation(description: "server terminated")
        manager.onTerminated = { _ in terminated.fulfill() }
        defer {
            if manager.isProcessRunning {
                manager.terminate()
            }
        }

        XCTAssertNotNil(manager.launch(configuration: configuration))
        let deadline = Date().addingTimeInterval(4)
        while !fileManager.fileExists(atPath: backupURL.path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }

        XCTAssertTrue(fileManager.fileExists(atPath: backupURL.path))
        XCTAssertLessThanOrEqual(
            (try fileManager.attributesOfItem(atPath: backupURL.path)[.size] as? NSNumber)?
                .intValue ?? .max,
            1024 * 1024
        )

        manager.terminate()
        await fulfillment(of: [terminated], timeout: 2)
    }

    /// Toggling the menu-bar display must not disturb the running server, and
    /// enabling it mid-request must start at EOF rather than replaying the
    /// history already in the log.
    func testPerformanceMonitoringTogglesAgainstALiveServer() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsmenubar-live-performance-\(UUID().uuidString)")
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let logURL = directory.appendingPathComponent("server.log")
        let stepURL = directory.appendingPathComponent("step")
        let record = "ds4-server: chat ctx=0..10:10 gen=10 decoding chunk=1.0 t/s avg="

        // Writes one record per step file the test drops in, so the log grows
        // only when the test says so.
        let serverURL = directory.appendingPathComponent("ds4-server")
        let script = """
        #!/bin/sh
        n=1
        while [ $n -le 3 ]; do
            while [ ! -f '\(stepURL.path)'.$n ]; do /bin/sleep 0.02; done
            echo "\(record)$n.0 t/s 1.0s"
            n=$((n + 1))
        done
        exec /bin/sleep 10
        """
        try Data(script.utf8).write(to: serverURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: serverURL.path)

        let modelURL = directory.appendingPathComponent("model.gguf")
        try makeGGUF(architecture: "glm5-next").write(to: modelURL)

        var configuration = ServerConfiguration.Config()
        configuration.serverPath = serverURL.path
        configuration.modelPath = modelURL.path
        configuration.logPath = logURL.path

        let manager = ProcessManager()
        var updates: [ServerPerformance] = []
        manager.onPerformanceChange = { updates.append($0) }
        defer {
            if manager.isProcessRunning {
                manager.terminate()
            }
        }

        // Step 1 lands while monitoring is off and must never be reported, but
        // it still counts as activity: tracking is not gated by the display.
        XCTAssertNotNil(manager.launch(configuration: configuration))
        try await write(step: 1, at: stepURL, awaiting: 1, in: logURL)
        XCTAssertEqual(updates, [])
        try await waitForUsage(manager)
        XCTAssertNotNil(manager.lastUsageAt)

        manager.setPerformanceMonitoring(true)
        try await write(step: 2, at: stepURL, awaiting: 2, in: logURL)
        try await settle()
        XCTAssertEqual(
            updates,
            [ServerPerformance(phase: .generation, tokensPerSecond: 2.0)]
        )

        // Disabling reports idle once and then stays quiet.
        manager.setPerformanceMonitoring(false)
        XCTAssertEqual(updates.last, .idle)
        let afterDisabling = updates.count
        try await write(step: 3, at: stepURL, awaiting: 3, in: logURL)
        try await settle()
        XCTAssertEqual(updates.count, afterDisabling)
        XCTAssertNotNil(manager.lastUsageAt, "tracking must survive disabling the display")
        XCTAssertTrue(manager.isProcessRunning)
    }

    /// Release the server's next record and wait for it to reach the log.
    private func write(
        step: Int,
        at stepURL: URL,
        awaiting records: Int,
        in logURL: URL
    ) async throws {
        try Data().write(to: URL(fileURLWithPath: stepURL.path + ".\(step)"))

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            if log.components(separatedBy: "decoding chunk=").count > records { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Server did not write record \(step)")
    }

    /// Let the write event, the reader's queue hop, and the hop back to main
    /// all drain before asserting.
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(300))
    }

    /// A launch that lands before the previous run's termination handler must
    /// keep its own log handle and process reference. The handler used to read
    /// `logFileHandle` at fire time and nil `process` unconditionally, so a
    /// superseded run closed the live log and dropped the live child.
    ///
    /// ServerManager cannot reach this sequence — start(source:) refuses while
    /// .stopping — so it is driven against ProcessManager directly.
    func testSupersededTerminationLeavesTheNewRunAlone() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsmenubar-supersede-\(UUID().uuidString)")
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let serverURL = directory.appendingPathComponent("ds4-server")
        // Writes after a delay, so the write lands once the superseded handler
        // has already run: a closed descriptor would lose it.
        let script = """
        #!/bin/sh
        /bin/sleep 0.4
        echo listening
        exec /bin/sleep 30
        """
        try Data(script.utf8).write(to: serverURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: serverURL.path)

        let modelURL = directory.appendingPathComponent("model.gguf")
        try makeGGUF(architecture: "glm5-next").write(to: modelURL)

        func configuration(log: String) -> ServerConfiguration.Config {
            var config = ServerConfiguration.Config()
            config.serverPath = serverURL.path
            config.modelPath = modelURL.path
            config.logPath = directory.appendingPathComponent(log).path
            config.kvDiskEnabled = false
            return config
        }
        let configB = configuration(log: "b.log")

        let manager = ProcessManager()
        var terminations = 0
        manager.onTerminated = { _ in terminations += 1 }
        defer {
            if manager.isProcessRunning { manager.terminate() }
        }

        XCTAssertNotNil(manager.launch(configuration: configuration(log: "a.log")))
        let pidA = try XCTUnwrap(manager.currentPID)

        // One main-queue turn: stop, then start again before the first run's
        // termination handler can land.
        manager.terminate()
        XCTAssertNotNil(manager.launch(configuration: configB))
        let pidB = try XCTUnwrap(manager.currentPID)
        XCTAssertNotEqual(pidA, pidB)

        try await Task.sleep(for: .seconds(2))

        XCTAssertTrue(manager.isProcessRunning, "the new run must still be tracked")
        XCTAssertEqual(manager.currentPID, pidB, "the new run's process must not be nilled")

        let log = try String(contentsOfFile: configB.logPath, encoding: .utf8)
        XCTAssertTrue(log.contains("=== dsmenubar launch"), "header must reach the new log")
        XCTAssertTrue(
            log.contains("listening"),
            "the new run's log descriptor must stay open for the server's own output"
        )
        XCTAssertEqual(
            terminations, 0,
            "the superseded run must close its own log without reporting a termination"
        )

        // The live run still reports normally when it is the one that ends.
        manager.terminate()
        try await Task.sleep(for: .seconds(1))
        XCTAssertFalse(manager.isProcessRunning)
        XCTAssertEqual(terminations, 1, "the current run must still report its termination")
    }

    /// A rotation that cannot run is a housekeeping failure, not a launch
    /// failure: the server still starts against the oversized log. It used to
    /// be swallowed by `try?`, which made a broken log directory look like a
    /// server that simply said nothing.
    func testStartupRotationFailureDoesNotStopTheLaunch() throws {
        // root ignores the directory mode this relies on.
        try XCTSkipIf(getuid() == 0, "requires a non-root user")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsmenubar-rotate-denied-\(UUID().uuidString)")
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let logDirectory = directory.appendingPathComponent("logs")
        try fileManager.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        defer {
            try? fileManager.setAttributes([.posixPermissions: 0o755],
                                           ofItemAtPath: logDirectory.path)
            try? fileManager.removeItem(at: directory)
        }

        let serverURL = directory.appendingPathComponent("ds4-server")
        try Data("#!/bin/sh\nexec /bin/sleep 5\n".utf8).write(to: serverURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: serverURL.path)

        let modelURL = directory.appendingPathComponent("model.gguf")
        try makeGGUF(architecture: "glm5-next").write(to: modelURL)

        // Oversized log left by an earlier run: 2 MB against a 1 MB cap.
        let logURL = logDirectory.appendingPathComponent("server.log")
        try Data(repeating: 0x41, count: 2 * 1024 * 1024).write(to: logURL)
        // Deny directory writes, so the rotation cannot create its temp file
        // while the existing log stays open for append.
        try fileManager.setAttributes([.posixPermissions: 0o500],
                                      ofItemAtPath: logDirectory.path)

        var config = ServerConfiguration.Config()
        config.serverPath = serverURL.path
        config.modelPath = modelURL.path
        config.logPath = logURL.path
        config.logMaxSizeMB = 1
        config.kvDiskEnabled = false

        let manager = ProcessManager()
        defer { if manager.isProcessRunning { manager.terminate() } }

        XCTAssertNotNil(manager.launch(configuration: config),
                        "a denied rotation must not stop the launch")
        XCTAssertTrue(manager.isProcessRunning)
        XCTAssertFalse(
            fileManager.fileExists(atPath: logDirectory.appendingPathComponent("server.log.1").path),
            "rotation was denied, so no backup should exist"
        )
    }

    func testRotateLogRetainsNewestBytesAndKeepsActiveDescriptorValid() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsmenubar-log-rotate-\(UUID().uuidString)")
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let log = directory.appendingPathComponent("server.log")
        let backup = directory.appendingPathComponent("server.log.1")
        try Data("0123456789".utf8).write(to: log)
        try Data("old backup".utf8).write(to: backup)

        let activeFD = open(log.path, O_WRONLY | O_APPEND)
        guard activeFD >= 0 else {
            XCTFail("Unable to open test log")
            return
        }
        let activeWriter = FileHandle(fileDescriptor: activeFD, closeOnDealloc: true)
        defer { try? activeWriter.close() }

        try ProcessManager.rotateLog(
            at: log.path,
            maximumBytes: 6,
            activeFileDescriptor: activeFD
        )
        try activeWriter.write(contentsOf: Data("new output".utf8))

        XCTAssertEqual(String(decoding: try Data(contentsOf: backup), as: UTF8.self), "456789")
        XCTAssertEqual(String(decoding: try Data(contentsOf: log), as: UTF8.self), "new output")
    }

    func testClearLogCollectionTruncatesCurrentLogAndRemovesBackup() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsmenubar-log-clear-\(UUID().uuidString)")
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let log = directory.appendingPathComponent("server.log")
        let backup = directory.appendingPathComponent("server.log.1")
        try Data("current log".utf8).write(to: log)
        try Data("rotated log".utf8).write(to: backup)
        let activeFD = open(log.path, O_WRONLY | O_APPEND)
        guard activeFD >= 0 else {
            XCTFail("Unable to open test log")
            return
        }
        let activeWriter = FileHandle(fileDescriptor: activeFD, closeOnDealloc: true)
        defer { try? activeWriter.close() }

        try ProcessManager().clearLogCollection(logPath: log.path)
        try activeWriter.write(contentsOf: Data("new output".utf8))

        XCTAssertEqual(String(decoding: try Data(contentsOf: log), as: UTF8.self), "new output")
        XCTAssertFalse(fileManager.fileExists(atPath: backup.path))
    }

    func testClearLogCollectionAllowsMissingFiles() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsmenubar-missing-log-\(UUID().uuidString)")
            .path

        XCTAssertNoThrow(try ProcessManager().clearLogCollection(logPath: path))
    }

    func testDeleteTraceFileRemovesOnlyARegularFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsmenubar-trace-clear-\(UUID().uuidString)")
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let trace = directory.appendingPathComponent("trace.jsonl")
        try Data("private trace".utf8).write(to: trace)

        try ProcessManager().deleteTraceFile(tracePath: trace.path)

        XCTAssertFalse(fileManager.fileExists(atPath: trace.path))
        XCTAssertThrowsError(try ProcessManager().deleteTraceFile(tracePath: directory.path))
        XCTAssertTrue(fileManager.fileExists(atPath: directory.path))
    }

    func testRegularFileChecksRejectDirectoriesAndAcceptFileSymlinks() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsmenubar-files-\(UUID().uuidString)")
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        XCTAssertFalse(fileManager.isReadableRegularFile(atPath: directory.path))
        XCTAssertFalse(fileManager.isExecutableRegularFile(atPath: directory.path))

        let file = directory.appendingPathComponent("model.gguf")
        try Data("model".utf8).write(to: file)
        let link = directory.appendingPathComponent("model-link.gguf")
        try fileManager.createSymbolicLink(at: link, withDestinationURL: file)

        XCTAssertTrue(fileManager.isReadableRegularFile(atPath: file.path))
        XCTAssertTrue(fileManager.isReadableRegularFile(atPath: link.path))
    }

    func testLaunchRejectsAnExecutableDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsmenubar-server-directory-\(UUID().uuidString)")
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        var configuration = ServerConfiguration.Config()
        configuration.serverPath = directory.path

        let manager = ProcessManager()
        var failure: String?
        manager.onLaunchFailure = { failure = $0 }

        XCTAssertNil(manager.launch(configuration: configuration))
        XCTAssertEqual(
            failure,
            "ds4-server not found or not executable at \(directory.path)"
        )
    }

    func testLaunchDoesNotRunServerHelpDuringPreflight() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsmenubar-no-help-\(UUID().uuidString)")
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let markerURL = directory.appendingPathComponent("help-was-run")
        let serverURL = directory.appendingPathComponent("ds4-server")
        let script = """
        #!/bin/sh
        if [ "$1" = "--help" ]; then
            /usr/bin/touch '\(markerURL.path)'
        fi
        exit 0
        """
        try Data(script.utf8).write(to: serverURL)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: serverURL.path
        )

        let modelURL = directory.appendingPathComponent("model.gguf")
        try makeGGUF(architecture: "glm5-next").write(to: modelURL)

        var configuration = ServerConfiguration.Config()
        configuration.serverPath = serverURL.path
        configuration.modelPath = modelURL.path
        configuration.host = "["

        let manager = ProcessManager()
        var failure: String?
        manager.onLaunchFailure = { failure = $0 }

        XCTAssertNil(manager.launch(configuration: configuration))
        XCTAssertEqual(
            failure,
            "Unable to construct a health-check URL for host ["
        )
        XCTAssertFalse(fileManager.fileExists(atPath: markerURL.path))
    }

    func testLaunchRejectsReadableNonGGUFModel() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsmenubar-invalid-model-\(UUID().uuidString)")
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let serverURL = directory.appendingPathComponent("ds4-server")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: serverURL)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: serverURL.path
        )
        let modelURL = directory.appendingPathComponent("model.gguf")
        try Data("not a GGUF".utf8).write(to: modelURL)

        var configuration = ServerConfiguration.Config()
        configuration.serverPath = serverURL.path
        configuration.modelPath = modelURL.path

        let manager = ProcessManager()
        var failure: String?
        manager.onLaunchFailure = { failure = $0 }

        XCTAssertNil(manager.launch(configuration: configuration))
        XCTAssertEqual(
            failure,
            "model is not a valid GGUF at \(modelURL.path)"
        )
    }

    /// Cache files hold prompt text and model state, and the default location
    /// is inside world-writable /tmp.
    func testLaunchCreatesOwnerOnlyKVCacheDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsmenubar-kv-\(UUID().uuidString)")
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let serverURL = directory.appendingPathComponent("ds4-server")
        try Data("#!/bin/sh\nsleep 5\n".utf8).write(to: serverURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: serverURL.path)

        let modelURL = directory.appendingPathComponent("model.gguf")
        try makeGGUF(architecture: "glm5-next").write(to: modelURL)
        let cacheURL = directory.appendingPathComponent("kv-cache")

        var configuration = ServerConfiguration.Config()
        configuration.serverPath = serverURL.path
        configuration.modelPath = modelURL.path
        configuration.logPath = directory.appendingPathComponent("server.log").path
        configuration.kvDiskEnabled = true
        configuration.kvDiskDir = cacheURL.path

        let manager = ProcessManager()
        defer {
            if manager.isProcessRunning {
                manager.terminate()
            }
        }

        XCTAssertNotNil(manager.launch(configuration: configuration))
        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            fileManager.fileExists(atPath: cacheURL.path, isDirectory: &isDirectory)
        )
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(
            (try fileManager.attributesOfItem(atPath: cacheURL.path)[.posixPermissions]
                as? NSNumber)?.int16Value,
            0o700
        )
    }

    func testLaunchResolvesRelativeModelAndSkipsDisabledVisionPreflight() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsmenubar-process-\(UUID().uuidString)")
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let serverURL = directory.appendingPathComponent("ds4-server")
        try Data("#!/bin/sh\nsleep 5\n".utf8).write(to: serverURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: serverURL.path)

        let modelURL = directory.appendingPathComponent("model.gguf")
        try makeGGUF(architecture: "glm5-next").write(to: modelURL)

        var configuration = ServerConfiguration.Config()
        configuration.serverPath = serverURL.path
        configuration.modelPath = modelURL.lastPathComponent
        configuration.host = "["
        configuration.visionPath = "missing-vision.gguf"
        configuration.visionEnabled = false

        let manager = ProcessManager()
        var failure: String?
        manager.onLaunchFailure = { failure = $0 }

        XCTAssertNil(manager.launch(configuration: configuration))
        XCTAssertEqual(
            failure,
            "Unable to construct a health-check URL for host ["
        )
    }

    func testUnknownModelSkipsUnusedExternalSupportPreflight() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsmenubar-process-unknown-\(UUID().uuidString)")
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let serverURL = directory.appendingPathComponent("ds4-server")
        try Data("#!/bin/sh\nsleep 5\n".utf8).write(to: serverURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: serverURL.path)

        let modelURL = directory.appendingPathComponent("unknown.gguf")
        try makeGGUF(architecture: "qwen3-next").write(to: modelURL)

        for mode in [MTPMode.external, .dspark] {
            var configuration = ServerConfiguration.Config()
            configuration.serverPath = serverURL.path
            configuration.modelPath = modelURL.path
            configuration.mtpMode = mode
            configuration.mtpPath = "missing-support.gguf"
            configuration.host = "["

            let manager = ProcessManager()
            var failure: String?
            manager.onLaunchFailure = { failure = $0 }

            XCTAssertNil(manager.launch(configuration: configuration))
            XCTAssertEqual(
                failure,
                "Unable to construct a health-check URL for host [",
                mode.rawValue
            )
        }
    }

    func testFutureGGUFVersionReachesServerLaunch() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsmenubar-process-future-\(UUID().uuidString)")
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let serverURL = directory.appendingPathComponent("ds4-server")
        try Data("#!/bin/sh\nsleep 5\n".utf8).write(to: serverURL)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: serverURL.path
        )

        let modelURL = directory.appendingPathComponent("future.gguf")
        try makeGGUF(architecture: "future-model", version: 4).write(to: modelURL)

        var configuration = ServerConfiguration.Config()
        configuration.serverPath = serverURL.path
        configuration.modelPath = modelURL.path
        configuration.host = "["

        let manager = ProcessManager()
        var failure: String?
        manager.onLaunchFailure = { failure = $0 }

        XCTAssertNil(manager.launch(configuration: configuration))
        XCTAssertEqual(
            failure,
            "Unable to construct a health-check URL for host ["
        )
    }

    /// A bind wildcard is not a connectable destination, and the spellings
    /// fail differently: CFNetwork rejects `0.0.0.0` outright
    /// (`NSURLErrorBadURL`), while `[::]` builds a valid URL that never
    /// connects. Both would leave the menu on "Starting…" against a healthy
    /// server, so the probe must target loopback instead.
    func testLaunchWithWildcardHostReturnsLoopbackHealthURL() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsmenubar-wildcard-host-\(UUID().uuidString)")
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let serverURL = directory.appendingPathComponent("ds4-server")
        try Data("#!/bin/sh\nsleep 5\n".utf8).write(to: serverURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: serverURL.path)

        let modelURL = directory.appendingPathComponent("model.gguf")
        try makeGGUF(architecture: "glm5-next").write(to: modelURL)

        let expected = [
            ("0.0.0.0", "http://127.0.0.1:8123/v1/models"),
            ("::", "http://[::1]:8123/v1/models"),
            ("[::]", "http://[::1]:8123/v1/models"),
            ("[0:0:0:0:0:0:0:0]", "http://[::1]:8123/v1/models")
        ]

        for (host, url) in expected {
            var configuration = ServerConfiguration.Config()
            configuration.serverPath = serverURL.path
            configuration.modelPath = modelURL.path
            configuration.logPath = directory
                .appendingPathComponent("server-\(UUID().uuidString).log").path
            configuration.host = host
            configuration.port = 8123

            let manager = ProcessManager()
            defer {
                if manager.isProcessRunning {
                    manager.terminate()
                }
            }

            let healthURL = manager.launch(configuration: configuration)
            XCTAssertEqual(healthURL?.absoluteString, url, host)
            // A URL alone would also be returned by a launch that never ran;
            // this is the whole path, child process included.
            XCTAssertTrue(manager.isProcessRunning, host)
        }
    }

    // MARK: - Forced kill

    /// SIGTERM to a stopped or wedged server stays pending, so the forced kill
    /// is what actually ends it.
    func testTerminateForcesAKillWhenSigtermIsIgnored() async throws {
        let server = try makeFakeServer(ignoresSigterm: true, lifetimeSeconds: 60, name: "force-kill")
        defer { try? FileManager.default.removeItem(at: server.directory) }

        let grace: TimeInterval = 0.5
        let manager = ProcessManager(forceKillGrace: grace)
        var info: TerminationInfo?
        let terminated = expectation(description: "the forced kill reports termination")
        manager.onTerminated = { info = $0; terminated.fulfill() }

        XCTAssertNotNil(manager.launch(configuration: configuration(for: server)))
        try await waitForFakeServerReady(server)
        let started = Date()
        manager.terminate()
        await fulfillment(of: [terminated], timeout: 5)

        let elapsed = Date().timeIntervalSince(started)
        XCTAssertGreaterThanOrEqual(elapsed, grace, "SIGTERM must get its full grace")
        XCTAssertLessThan(elapsed, grace + 2, "the kill must land promptly after the grace")
        XCTAssertEqual(info?.intentional, true)
        XCTAssertEqual(info?.clean, false, "a SIGKILL is not a clean exit")
        XCTAssertFalse(manager.isProcessRunning)
    }

    func testTerminateDoesNotForceKillAServerThatExitsOnSigterm() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsmenubar-clean-stop-\(UUID().uuidString)")
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        // The shell exits 0 when SIGTERM arrives; the sleep loop keeps it alive.
        let serverURL = directory.appendingPathComponent("ds4-server")
        let readyMarker = directory.appendingPathComponent("ready")
        let script = """
        #!/bin/sh
        trap 'exit 0' TERM
        touch '\(readyMarker.path)'
        while true; do /bin/sleep 0.05; done
        """
        try Data(script.utf8).write(to: serverURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: serverURL.path)
        let modelURL = directory.appendingPathComponent("model.gguf")
        try makeGGUF(architecture: "glm5-next").write(to: modelURL)

        var config = ServerConfiguration.Config()
        config.serverPath = serverURL.path
        config.modelPath = modelURL.path
        config.logPath = directory.appendingPathComponent("server.log").path
        config.kvDiskEnabled = false

        let manager = ProcessManager(forceKillGrace: 5)
        var info: TerminationInfo?
        let terminated = expectation(description: "termination")
        manager.onTerminated = { info = $0; terminated.fulfill() }
        XCTAssertNotNil(manager.launch(configuration: config))
        let deadline = Date().addingTimeInterval(5)
        while !fileManager.fileExists(atPath: readyMarker.path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(
            fileManager.fileExists(atPath: readyMarker.path),
            "the fake server never signalled readiness"
        )

        let started = Date()
        manager.terminate()
        await fulfillment(of: [terminated], timeout: 3)

        XCTAssertLessThan(
            Date().timeIntervalSince(started), 2,
            "a server that exits on SIGTERM must not wait out the grace"
        )
        XCTAssertEqual(info?.clean, true)
    }

    func testRepeatedTerminateDoesNotPostponeTheForcedKill() async throws {
        let server = try makeFakeServer(ignoresSigterm: true, lifetimeSeconds: 60, name: "repeat-terminate")
        defer { try? FileManager.default.removeItem(at: server.directory) }

        let grace: TimeInterval = 1.5
        let manager = ProcessManager(forceKillGrace: grace)
        let terminated = expectation(description: "termination")
        manager.onTerminated = { _ in terminated.fulfill() }
        XCTAssertNotNil(manager.launch(configuration: configuration(for: server)))
        try await waitForFakeServerReady(server)

        let started = Date()
        manager.terminate()
        try await Task.sleep(for: .milliseconds(400))
        // A second terminate must not push the deadline to 0.4 + grace.
        manager.terminate()
        await fulfillment(of: [terminated], timeout: 5)

        XCTAssertLessThan(
            Date().timeIntervalSince(started), grace + 0.4,
            "a repeated terminate must not postpone the kill"
        )
    }

    func testForcedKillForASupersededRunDoesNotTouchItsReplacement() async throws {
        let serverA = try makeFakeServer(ignoresSigterm: true, lifetimeSeconds: 3, name: "supersede-a")
        defer { try? FileManager.default.removeItem(at: serverA.directory) }
        let serverB = try makeFakeServer(ignoresSigterm: false, lifetimeSeconds: 60, name: "supersede-b")
        defer { try? FileManager.default.removeItem(at: serverB.directory) }

        let manager = ProcessManager(forceKillGrace: 0.5)
        XCTAssertNotNil(manager.launch(configuration: configuration(for: serverA)))
        try await waitForFakeServerReady(serverA)
        let pidA = try XCTUnwrap(manager.currentPID)

        // Stop A (arming its forced kill), then hand the manager a new run
        // before that timer can fire.
        manager.terminate()
        XCTAssertNotNil(manager.launch(configuration: configuration(for: serverB)))
        let pidB = try XCTUnwrap(manager.currentPID)
        XCTAssertNotEqual(pidA, pidB)

        try await Task.sleep(for: .seconds(1.5))
        XCTAssertTrue(manager.isProcessRunning)
        XCTAssertEqual(manager.currentPID, pidB, "A's timer must not kill B")
        manager.terminate()
    }

    func testAManualStopClearsARecordedFailureReason() async throws {
        let server = try makeFakeServer(ignoresSigterm: false, lifetimeSeconds: 60, name: "manual-stop")
        defer { try? FileManager.default.removeItem(at: server.directory) }

        let manager = ProcessManager()
        var info: TerminationInfo?
        let terminated = expectation(description: "termination")
        manager.onTerminated = { info = $0; terminated.fulfill() }
        XCTAssertNotNil(manager.launch(configuration: configuration(for: server)))

        // The health checker records why it is stopping, then the user stops it
        // by hand during the grace.
        manager.terminate(withFailureReason: "unreachable for 3 checks")
        manager.terminate()
        await fulfillment(of: [terminated], timeout: 5)

        XCTAssertNil(info?.failureReason, "a manual stop supersedes the recorded failure")
        XCTAssertEqual(info?.intentional, true)
    }

    func testRestartForcesAKillAndStillReportsThePendingRelaunch() async throws {
        let server = try makeFakeServer(ignoresSigterm: true, lifetimeSeconds: 60, name: "restart-kill")
        defer { try? FileManager.default.removeItem(at: server.directory) }

        let grace: TimeInterval = 0.5
        let manager = ProcessManager(forceKillGrace: grace)
        var info: TerminationInfo?
        let terminated = expectation(description: "termination")
        manager.onTerminated = { info = $0; terminated.fulfill() }
        XCTAssertNotNil(manager.launch(configuration: configuration(for: server)))
        try await waitForFakeServerReady(server)

        let started = Date()
        manager.restart()
        await fulfillment(of: [terminated], timeout: 5)

        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), grace)
        XCTAssertEqual(info?.pendingRestart, true, "the relaunch callback must still fire")
        XCTAssertEqual(info?.clean, false)
    }

    // MARK: - Last usage

    func testAServedRequestSetsLastUsage() async throws {
        let server = try makeUsageServer(
            delay: 0.1,
            record: Self.prefillRecord,
            name: "usage"
        )
        defer { try? FileManager.default.removeItem(at: server.directory) }

        let manager = ProcessManager()
        XCTAssertNil(manager.lastUsageAt)
        XCTAssertNotNil(manager.launch(configuration: server.config))
        defer { if manager.isProcessRunning { manager.terminate() } }

        try await waitForUsage(manager)
        XCTAssertNotNil(manager.lastUsageAt)
    }

    func testRelaunchingClearsLastUsage() async throws {
        let serverA = try makeUsageServer(
            delay: 0.1,
            record: Self.prefillRecord,
            name: "usage-relaunch-a"
        )
        defer { try? FileManager.default.removeItem(at: serverA.directory) }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsmenubar-usage-relaunch-b-\(UUID().uuidString)")
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }
        let serverURL = directory.appendingPathComponent("ds4-server")
        try Data("#!/bin/sh\nexec /bin/sleep 60\n".utf8).write(to: serverURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: serverURL.path)
        let modelURL = directory.appendingPathComponent("model.gguf")
        try makeGGUF(architecture: "glm5-next").write(to: modelURL)
        var configB = ServerConfiguration.Config()
        configB.serverPath = serverURL.path
        configB.modelPath = modelURL.path
        configB.logPath = directory.appendingPathComponent("server.log").path
        configB.kvDiskEnabled = false

        let manager = ProcessManager()
        XCTAssertNotNil(manager.launch(configuration: serverA.config))
        try await waitForUsage(manager)
        XCTAssertNotNil(manager.lastUsageAt)

        manager.terminate()
        let deadline = Date().addingTimeInterval(3)
        while manager.isProcessRunning, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertNotNil(manager.launch(configuration: configB))
        defer { if manager.isProcessRunning { manager.terminate() } }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(manager.lastUsageAt, "a new run starts unused")
    }

    func testARequestStartLineCountsAsActivity() async throws {
        let server = try makeUsageServer(
            delay: 0.1,
            record: "0921 12:00:00 ds4-server: chat ctx=0..27291:27291 TOOLS prompt start",
            name: "usage-prompt-start"
        )
        defer { try? FileManager.default.removeItem(at: server.directory) }

        let manager = ProcessManager()
        XCTAssertNotNil(manager.launch(configuration: server.config))
        defer { if manager.isProcessRunning { manager.terminate() } }

        try await waitForUsage(manager)
        XCTAssertNotNil(manager.lastUsageAt, "a request start with no rate is still activity")
    }

    func testAStaleBatchDoesNotRecordUsage() throws {
        let manager = ProcessManager()
        manager.applyPerformanceBatch(
            ServerLogBatch(updates: [], sawRequestActivity: true),
            monitorID: UUID()
        )
        XCTAssertNil(manager.lastUsageAt, "a batch belonging to no run must be dropped")
    }

    func testARecordWrittenJustBeforeStopIsCounted() async throws {
        let server = try makeUsageServer(
            delay: 0,
            record: Self.prefillRecord,
            name: "usage-stopped"
        )
        defer { try? FileManager.default.removeItem(at: server.directory) }

        let manager = ProcessManager()
        XCTAssertNotNil(manager.launch(configuration: server.config))
        // Wait only until the record is in the file, then stop at once: whether
        // the write event or the stop-time drain consumes it, it must count.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let log = (try? String(contentsOfFile: server.logPath, encoding: .utf8)) ?? ""
            if log.contains("avg=") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        manager.terminate()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNotNil(manager.lastUsageAt)
    }

    private struct UsageServer {
        let directory: URL
        let config: ServerConfiguration.Config
        let logPath: String
    }

    private static let prefillRecord =
        "0921 12:00:00 ds4-server: chat ctx=0..10:10 prefill chunk 1/2 (50.0%) "
        + "chunk=12.34 t/s avg=12.34 t/s 0.100s"

    /// A server that writes one log record after `delay` seconds and then stays
    /// alive, with the GGUF and config a launch needs.
    private func makeUsageServer(
        delay: TimeInterval,
        record: String,
        name: String
    ) throws -> UsageServer {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsmenubar-\(name)-\(UUID().uuidString)")
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let serverURL = directory.appendingPathComponent("ds4-server")
        let logPath = directory.appendingPathComponent("server.log").path
        let script = """
        #!/bin/sh
        /bin/sleep \(delay)
        echo "\(record)"
        exec /bin/sleep 60
        """
        try Data(script.utf8).write(to: serverURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: serverURL.path)
        let modelURL = directory.appendingPathComponent("model.gguf")
        try makeGGUF(architecture: "glm5-next").write(to: modelURL)

        var config = ServerConfiguration.Config()
        config.serverPath = serverURL.path
        config.modelPath = modelURL.path
        config.logPath = logPath
        config.kvDiskEnabled = false
        return UsageServer(directory: directory, config: config, logPath: logPath)
    }

    private func waitForUsage(_ manager: ProcessManager, timeout: TimeInterval = 6) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while manager.lastUsageAt == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - Fake server helpers

    private struct FakeServer {
        let directory: URL
        let serverURL: URL
        let modelURL: URL
        let logPath: String
        /// Written by the script once its signal handling is installed. A
        /// SIGTERM sent before that would kill the shell on its default
        /// disposition, which is what makes the tests race without it.
        let readyMarker: URL
    }

    private func makeFakeServer(
        ignoresSigterm: Bool,
        lifetimeSeconds: Int,
        name: String
    ) throws -> FakeServer {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsmenubar-\(name)-\(UUID().uuidString)")
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let serverURL = directory.appendingPathComponent("ds4-server")
        let readyMarker = directory.appendingPathComponent("ready")
        // `trap ''` sets SIG_IGN, and an ignored signal survives `exec`, so the
        // sleep really does ignore SIGTERM. A normal trap would be replaced
        // before it could run and the forced kill would never be exercised.
        let body = ignoresSigterm
            ? "trap '' TERM\ntouch '\(readyMarker.path)'\nexec /bin/sleep \(lifetimeSeconds)"
            : "exec /bin/sleep \(lifetimeSeconds)"
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: serverURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: serverURL.path)

        let modelURL = directory.appendingPathComponent("model.gguf")
        try makeGGUF(architecture: "glm5-next").write(to: modelURL)

        return FakeServer(
            directory: directory,
            serverURL: serverURL,
            modelURL: modelURL,
            logPath: directory.appendingPathComponent("server.log").path,
            readyMarker: readyMarker
        )
    }

    /// Wait until the fake server has installed its signal handling.
    private func waitForFakeServerReady(_ server: FakeServer) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: server.readyMarker.path),
              Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: server.readyMarker.path),
            "the fake server never signalled readiness"
        )
    }

    private func configuration(for server: FakeServer) -> ServerConfiguration.Config {
        var config = ServerConfiguration.Config()
        config.serverPath = server.serverURL.path
        config.modelPath = server.modelURL.path
        config.logPath = server.logPath
        config.kvDiskEnabled = false
        return config
    }

    private func makeGGUF(architecture: String, version: UInt32 = 3) -> Data {
        var data = Data([0x47, 0x47, 0x55, 0x46])
        append(version, to: &data)
        append(UInt64(0), to: &data)
        append(UInt64(1), to: &data)
        append(utf8: "general.architecture", to: &data)
        append(UInt32(8), to: &data)
        append(utf8: architecture, to: &data)
        return data
    }

    private func append(utf8 value: String, to data: inout Data) {
        let bytes = Array(value.utf8)
        append(UInt64(bytes.count), to: &data)
        data.append(contentsOf: bytes)
    }

    private func append(_ value: UInt32, to data: inout Data) {
        data.append(contentsOf: withUnsafeBytes(of: value.littleEndian, Array.init))
    }

    private func append(_ value: UInt64, to data: inout Data) {
        data.append(contentsOf: withUnsafeBytes(of: value.littleEndian, Array.init))
    }
}
