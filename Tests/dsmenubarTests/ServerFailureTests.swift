// SPDX-FileCopyrightText: Copyright James Martin and DS Menu Bar contributors
// SPDX-License-Identifier: MIT

import XCTest

@testable import dsmenubar

@MainActor
final class ServerFailureTests: XCTestCase {
    func testEarlyExitReportsServerDiagnosticInsteadOfHelpExample() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsmenubar-early-exit-\(UUID().uuidString)")
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let serverURL = directory.appendingPathComponent("ds4-server")
        let script = """
        #!/bin/sh
        echo 'ds4-server: unknown option: --ple' >&2
        echo 'ds4-server' >&2
        echo 'Usage: ds4-server [options]' >&2
        echo 'curl http://127.0.0.1:8000/v1/models' >&2
        exit 2
        """
        try Data(script.utf8).write(to: serverURL)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: serverURL.path
        )

        let modelURL = directory.appendingPathComponent("model.gguf")
        try makeGGUF(architecture: "glm5-next").write(to: modelURL)

        let server = ServerManager()
        var configuration = server.configurationSnapshot()
        configuration.serverPath = serverURL.path
        configuration.modelPath = modelURL.path
        configuration.logPath = directory.appendingPathComponent("server.log").path
        configuration.port = 62_491
        configuration.kvDiskEnabled = false
        server.config.replace(with: configuration)

        let failed = expectation(description: "launch failure reported")
        var failure: ServerLaunchFailure?
        server.onLaunchFailure = {
            failure = $0
            failed.fulfill()
        }

        server.start()
        await fulfillment(of: [failed], timeout: 2)

        XCTAssertEqual(failure?.message, "ds4-server: unknown option: --ple")
        XCTAssertEqual(server.status, .error("ds4-server: unknown option: --ple"))
    }

    func testOnlyErrorStatusIsMarkedAsAnError() {
        XCTAssertTrue(ServerStatus.error("failed").isError)
        XCTAssertFalse(ServerStatus.stopped.isError)
        XCTAssertFalse(ServerStatus.running(pid: 1).isError)
        XCTAssertFalse(ServerStatus.starting.isError)
    }

    func testFailureDestinationFollowsCorrectiveSettingsPane() {
        XCTAssertEqual(
            ServerLaunchFailure(
                message: "Invalid server configuration: choose a DSpark support GGUF",
                source: .manual
                    ).settingsDestination,
            .mtp
        )
        XCTAssertEqual(
            ServerLaunchFailure(
                message: "vision model not readable at /tmp/vision.gguf",
                source: .manual
                    ).settingsDestination,
            .model
        )
        XCTAssertEqual(
            ServerLaunchFailure(message: "ds4-server not executable", source: .manual).settingsDestination,
            .general
        )
    }

    func testFailureTitlesDistinguishStartAndRestart() {
        let manual = ServerLaunchFailure(message: "bad configuration", source: .manual)

        XCTAssertEqual(manual.notificationTitle, "ds4-server could not start")
        XCTAssertEqual(ServerLaunchFailure(message: "bad", source: .restart).notificationTitle,
                       "ds4-server could not restart")
    }

    func testManualStartPublishesOneFailureEvent() {
        let server = ServerManager()
        var configuration = server.configurationSnapshot()
        configuration.serverPath = "/tmp/dsmenubar-missing-\(UUID().uuidString)"
        server.config.replace(with: configuration)
        var failures: [ServerLaunchFailure] = []
        server.onLaunchFailure = { failures.append($0) }

        server.start()

        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures.first?.source, .manual)
        XCTAssertTrue(failures.first?.message.contains("not found") == true)
    }

    func testNotificationBodyIsTruncatedForLongFailures() {
        let message = String(repeating: "x", count: 300)
        let failure = ServerLaunchFailure(message: message, source: .restart)

        XCTAssertEqual(failure.notificationBody.count, 240)
        XCTAssertTrue(failure.notificationBody.hasSuffix("…"))
    }

    func testSettingsNavigationConsumesPendingDestination() {
        UserDefaults.standard.removeObject(forKey: SettingsNavigation.pendingPaneKey)
        XCTAssertNil(SettingsNavigation.consumePendingPane())

        SettingsNavigation.request(.mtp)
        XCTAssertEqual(SettingsNavigation.consumePendingPane(), .mtp)
        XCTAssertNil(SettingsNavigation.consumePendingPane())
    }

    private func makeGGUF(architecture: String) -> Data {
        var data = Data([0x47, 0x47, 0x55, 0x46])
        append(UInt32(3), to: &data)
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
