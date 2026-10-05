// SPDX-FileCopyrightText: Copyright James Martin and DS Menu Bar contributors
// SPDX-License-Identifier: MIT

import XCTest

@testable import dsmenubar

/// Switching the configured model without walking the file system again.
/// ServerManager owns its collaborators, so each test builds a harness with a
/// suite-backed configuration, a temporary server script, and minimal GGUFs.
@MainActor
final class ModelSwitchingTests: XCTestCase {

    // MARK: - Harness

    @MainActor
    private final class Harness {
        let directory: URL
        let manager: ServerManager
        private let suiteName: String

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("dsmenubar-model-switching-\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )

            suiteName = "dsmenubar-model-switching-tests-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))

            var config = ServerConfiguration.Config()
            config.serverPath = directory.appendingPathComponent("ds4-server").path
            config.modelPath = directory.appendingPathComponent("placeholder.gguf").path
            config.logPath = directory.appendingPathComponent("server.log").path
            config.kvDiskEnabled = false

            // Never becomes healthy and never exits, so `.starting` holds for
            // as long as a test needs it to.
            let scriptURL = URL(fileURLWithPath: config.serverPath)
            try Data("#!/bin/sh\nexec /bin/sleep 60\n".utf8).write(to: scriptURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: scriptURL.path
            )

            let configuration = ServerConfiguration(defaults: defaults)
            configuration.replace(with: config)

            manager = ServerManager(
                config: configuration,
                processManager: ProcessManager(forceKillGrace: 0.5, portWaitTimeout: 0.5),
                healthChecker: HealthChecker(
                    fastInterval: 1,
                    steadyInterval: 1,
                    stallAdvisoryInterval: 3_600,
                    failureThreshold: 3
                ),
                stabilityWindow: 300
            )
        }

        func shutDown() {
            manager.stop()
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }

        func writeModel(named name: String, architecture: String) throws -> URL {
            let url = directory.appendingPathComponent(name)
            try Self.makeGGUF(architecture: architecture).write(to: url)
            return url
        }

        /// Select `selected` and store a distinct tuning profile for it and for
        /// `other`, so a later switch has something to restore. Returns both
        /// canonical model keys.
        @discardableResult
        func seedProfiles(
            selecting selected: URL,
            alongside other: URL
        ) throws -> (selected: String, other: String) {
            var config = manager.configurationSnapshot()
            let selectedKey = ServerConfiguration.Config.modelKey(
                for: selected.path, serverPath: config.serverPath
            )
            let otherKey = ServerConfiguration.Config.modelKey(
                for: other.path, serverPath: config.serverPath
            )

            var selectedProfile = DS4TuningProfile(configuration: config)
            selectedProfile.ctxSize = 8_192
            selectedProfile.threads = 4
            var otherProfile = DS4TuningProfile(configuration: config)
            otherProfile.ctxSize = 32_768
            otherProfile.threads = 16

            config.modelPath = selected.path
            config.ctxSize = selectedProfile.ctxSize
            config.threads = selectedProfile.threads
            config.modelProfiles = [selectedKey: selectedProfile, otherKey: otherProfile]
            manager.config.replace(with: config)

            return (selectedKey, otherKey)
        }

        /// The header GGUFModelInspector needs to recognise a family: magic, a
        /// version, one tensor, and `general.architecture`.
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

    // MARK: - Tests

    /// The point of the feature: each model keeps its own tuning, and switching
    /// back does not inherit whatever the other model was tuned to.
    func testSwitchModelRestoresTheProfileSavedForThatModel() throws {
        let harness = try Harness()
        defer { harness.shutDown() }

        let modelA = try harness.writeModel(named: "alpha.gguf", architecture: "glm5-next")
        let modelB = try harness.writeModel(named: "beta.gguf", architecture: "deepseek4")
        let keys = try harness.seedProfiles(selecting: modelA, alongside: modelB)

        XCTAssertTrue(harness.manager.switchModel(toPath: modelB.path))
        XCTAssertEqual(harness.manager.configurationSnapshot().ctxSize, 32_768)
        XCTAssertEqual(harness.manager.configurationSnapshot().threads, 16)
        XCTAssertEqual(activeKey(harness), keys.other)

        XCTAssertTrue(harness.manager.switchModel(toPath: modelA.path))
        XCTAssertEqual(harness.manager.configurationSnapshot().ctxSize, 8_192)
        XCTAssertEqual(harness.manager.configurationSnapshot().threads, 4)
        XCTAssertEqual(activeKey(harness), keys.selected)
    }

    /// ds4-server reads its model once at startup, so a switch mid-run must be
    /// refused rather than silently deferred to the next launch.
    func testSwitchModelIsRefusedWhileAServerProcessIsLive() throws {
        let harness = try Harness()
        defer { harness.shutDown() }

        let modelB = try harness.writeModel(named: "beta.gguf", architecture: "deepseek4")

        harness.manager.start()
        XCTAssertTrue(harness.manager.status.holdsServerProcess, "the launch has begun")
        let before = harness.manager.configurationSnapshot()

        XCTAssertFalse(harness.manager.switchModel(toPath: modelB.path))
        XCTAssertEqual(harness.manager.configurationSnapshot(), before)
    }

    func testSwitchModelRefusesAFileThatIsNotThere() throws {
        let harness = try Harness()
        defer { harness.shutDown() }

        let before = harness.manager.configurationSnapshot()
        let missing = harness.directory.appendingPathComponent("absent.gguf").path

        XCTAssertFalse(harness.manager.switchModel(toPath: missing))
        XCTAssertEqual(harness.manager.configurationSnapshot(), before)
    }

    func testConfiguredModelsListTheActiveModelAndEveryStoredProfile() throws {
        let harness = try Harness()
        defer { harness.shutDown() }

        let modelA = try harness.writeModel(named: "alpha.gguf", architecture: "glm5-next")
        let modelB = try harness.writeModel(named: "beta.gguf", architecture: "deepseek4")
        let keys = try harness.seedProfiles(selecting: modelA, alongside: modelB)

        let listed = harness.manager.configuredModels
        XCTAssertEqual(
            listed.map(\.id), [keys.selected, keys.other], "alpha sorts before beta"
        )
        XCTAssertEqual(listed.first(where: \.isActive)?.id, keys.selected)
        XCTAssertEqual(
            listed.first(where: { $0.id == keys.selected })?.displayName, "alpha.gguf"
        )
        XCTAssertTrue(listed.allSatisfy(\.isAvailable))

        // A model the user deleted stays listed so the path can be fixed, but
        // it stops being selectable.
        try FileManager.default.removeItem(at: modelB)
        let afterDeletion = harness.manager.configuredModels
        XCTAssertEqual(afterDeletion.count, 2, "a stale entry is reported, not dropped")
        XCTAssertEqual(
            afterDeletion.first(where: { $0.id == keys.other })?.isAvailable, false
        )
    }

    private func activeKey(_ harness: Harness) -> String {
        let config = harness.manager.configurationSnapshot()
        return ServerConfiguration.Config.modelKey(
            for: config.modelPath, serverPath: config.serverPath
        )
    }
}
