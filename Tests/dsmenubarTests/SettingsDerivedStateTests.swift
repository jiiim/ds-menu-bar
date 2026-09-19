// SPDX-FileCopyrightText: Copyright 2026 James Martin
// SPDX-License-Identifier: MIT

import Foundation
import XCTest

@testable import dsmenubar

/// Settings inspects the selected GGUFs off the main thread and then decides
/// whether the result still applies to the draft it came back to. The
/// re-inspect-or-reuse decision is the part that can silently show a stale
/// profile, so it is asserted here directly rather than through the view.
final class SettingsDerivedStateTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsmenubar-derived-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
    }

    // MARK: - Fixtures

    private func writeModel(
        named name: String,
        architecture: String,
        tensorNames: [String] = []
    ) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try makeGGUF(architecture: architecture, tensorNames: tensorNames).write(to: url)
        return url
    }

    private func config(modelPath: String) -> ServerConfiguration.Config {
        var config = ServerConfiguration.Config()
        config.serverPath = directory.appendingPathComponent("ds4-server").path
        config.modelPath = modelPath
        return config
    }

    /// The previous pass, as it would stand after inspecting `config` and
    /// getting `model` back.
    private func previous(
        for config: ServerConfiguration.Config,
        model: DS4ModelProfile
    ) -> SettingsDerivedPrevious {
        SettingsDerivedPrevious(
            inputs: SettingsDerivedInputs(config),
            model: model,
            modelError: nil,
            support: .unavailable,
            vision: DS4VisionProfile(
                kind: .incompatible,
                architecture: nil,
                projectionDimension: nil
            ),
            identities: SettingsDerivedFileIdentities.inspecting(config)
        )
    }

    // MARK: - Reuse vs. re-inspect

    func testUnchangedPathAndFileReusesThePreviousProfile() throws {
        let model = try writeModel(named: "model.gguf", architecture: "glm5-next")
        let config = config(modelPath: model.path)

        // A sentinel the inspector could never produce from the file on disk:
        // seeing it back proves the previous value was carried forward rather
        // than re-read.
        let sentinel = DS4ModelProfile.unknown
        let result = SettingsDerivedRefresh.compute(
            config: config,
            inputs: SettingsDerivedInputs(config),
            previous: previous(for: config, model: sentinel),
            forceRefresh: false
        )

        XCTAssertEqual(result.model, sentinel, "an unchanged file must not be re-inspected")
    }

    func testFileReplacedInPlaceIsReinspectedDespiteTheSamePath() throws {
        let model = try writeModel(named: "model.gguf", architecture: "glm5-next")
        let config = config(modelPath: model.path)
        let stale = previous(for: config, model: .unknown)

        // Same path, different contents *and* a different length, so the size
        // half of the identity catches it without depending on mtime
        // granularity between two writes in the same instant.
        try makeGGUF(architecture: "deepseek4_mtp_support").write(to: model)

        let result = SettingsDerivedRefresh.compute(
            config: config,
            inputs: SettingsDerivedInputs(config),
            previous: stale,
            forceRefresh: false
        )

        XCTAssertNotEqual(
            result.model, .unknown,
            "a file replaced under an unchanged path must be re-inspected"
        )
    }

    func testForceRefreshReinspectsEvenWhenNothingChanged() throws {
        let model = try writeModel(named: "model.gguf", architecture: "glm5-next")
        let config = config(modelPath: model.path)

        let result = SettingsDerivedRefresh.compute(
            config: config,
            inputs: SettingsDerivedInputs(config),
            previous: previous(for: config, model: .unknown),
            forceRefresh: true
        )

        XCTAssertNotEqual(result.model, .unknown, "forceRefresh must re-read the file")
    }

    func testChangedPathIsReinspected() throws {
        let first = try writeModel(named: "first.gguf", architecture: "glm5-next")
        let second = try writeModel(named: "second.gguf", architecture: "glm5-next")

        let previousConfig = config(modelPath: first.path)
        let currentConfig = config(modelPath: second.path)

        let result = SettingsDerivedRefresh.compute(
            config: currentConfig,
            inputs: SettingsDerivedInputs(currentConfig),
            previous: previous(for: previousConfig, model: .unknown),
            forceRefresh: false
        )

        XCTAssertNotEqual(result.model, .unknown, "a different path must be inspected")
    }

    // MARK: - Empty selection

    func testEmptyModelPathIsUnknownWithoutAnError() {
        let config = config(modelPath: "")

        let result = SettingsDerivedRefresh.compute(
            config: config,
            inputs: SettingsDerivedInputs(config),
            previous: previous(for: config, model: .unknown),
            forceRefresh: true
        )

        XCTAssertEqual(result.model, .unknown)
        XCTAssertNil(
            result.modelError,
            "an unset path is asked for by validationErrors, not reported as a bad file"
        )
    }

    // MARK: - Apply checks

    func testApplyReusesTheServerErrorForAnUnchangedExecutable() throws {
        let server = directory.appendingPathComponent("ds4-server")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: server)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: server.path
        )
        let model = try writeModel(named: "model.gguf", architecture: "glm5-next")
        var candidate = ServerConfiguration.Config()
        candidate.serverPath = server.path
        candidate.modelPath = model.path

        let identity = SettingsFileIdentity(path: server.path)
        let checks = SettingsApplyChecks.compute(
            candidate: candidate,
            previousServerPath: candidate.serverPath,
            previousServerIdentity: identity,
            previousServerError: "cached refusal"
        )

        XCTAssertEqual(
            checks.serverError, "cached refusal",
            "an executable already checked this session must not be re-run"
        )
    }

    func testApplyRechecksAnExecutableReplacedInPlace() throws {
        let server = directory.appendingPathComponent("ds4-server")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: server)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: server.path
        )
        let model = try writeModel(named: "model.gguf", architecture: "glm5-next")
        var candidate = ServerConfiguration.Config()
        candidate.serverPath = server.path
        candidate.modelPath = model.path

        let staleIdentity = SettingsFileIdentity(path: server.path)
        // Same path, different binary: the cached answer must not survive.
        try Data("#!/bin/sh\necho replaced\nexit 0\n".utf8).write(to: server)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: server.path
        )

        let checks = SettingsApplyChecks.compute(
            candidate: candidate,
            previousServerPath: candidate.serverPath,
            previousServerIdentity: staleIdentity,
            previousServerError: "cached refusal"
        )

        XCTAssertNotEqual(
            checks.serverError, "cached refusal",
            "a replaced binary must be re-run rather than trusted"
        )
    }

    func testApplyAlwaysChecksWhenNothingWasCheckedBefore() throws {
        let model = try writeModel(named: "model.gguf", architecture: "glm5-next")
        var candidate = ServerConfiguration.Config()
        candidate.serverPath = directory.appendingPathComponent("absent").path
        candidate.modelPath = model.path

        let checks = SettingsApplyChecks.compute(
            candidate: candidate,
            previousServerPath: candidate.serverPath,
            previousServerIdentity: nil,
            previousServerError: nil
        )

        XCTAssertNotNil(
            checks.serverError,
            "a nil previous identity must not be read as a match"
        )
    }

    func testApplyReinspectsSupportPathRestoredByModelProfile() throws {
        let server = directory.appendingPathComponent("ds4-server")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: server)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: server.path
        )
        let model = try writeModel(named: "model.gguf", architecture: "deepseek4")
        let legacy = try writeModel(
            named: "legacy.gguf",
            architecture: "deepseek4_mtp_support",
            tensorNames: [
                "mtp.0.e_proj.weight",
                "mtp.0.h_proj.weight",
                "mtp.0.hc_head_base.weight",
            ]
        )
        let dspark = try writeModel(
            named: "dspark.gguf",
            architecture: "deepseek4-dspark",
            tensorNames: [
                "mtp.0.main_proj.weight",
                "mtp.0.block.weight",
                "mtp.1.block.weight",
                "mtp.2.block.weight",
                "mtp.2.markov_head.markov_w1.weight",
                "mtp.2.confidence_head.proj.weight",
            ]
        )
        var candidate = ServerConfiguration.Config()
        candidate.serverPath = server.path
        candidate.modelPath = model.path
        candidate.mtpPath = legacy.path

        let initial = SettingsApplyChecks.compute(
            candidate: candidate,
            previousServerPath: "",
            previousServerIdentity: nil,
            previousServerError: nil
        )
        XCTAssertEqual(initial.support.kind, .legacyMTP)

        let selectedKey = ServerConfiguration.Config.modelKey(
            for: candidate.modelPath,
            serverPath: candidate.serverPath
        )
        var savedConfig = candidate
        savedConfig.mtpPath = dspark.path
        savedConfig.mtpMode = .dspark
        candidate.modelProfiles[selectedKey] = DS4TuningProfile(configuration: savedConfig)

        let restored = candidate.selectingModel(
            path: candidate.modelPath,
            serverPath: candidate.serverPath,
            profile: initial.model,
            storingCurrentAs: "previous-model"
        )
        let plannedConfig: ServerConfiguration.Config
        switch SettingsApplyReinspection.plan(inspected: candidate, restored: restored) {
        case .auxiliaryFiles(let config):
            plannedConfig = config
        case .none, .allFiles:
            return XCTFail("restoring a different support path must trigger auxiliary inspection")
        }
        let refreshed = initial.reinspectingAuxiliaryFiles(for: plannedConfig)

        XCTAssertEqual(refreshed.support.kind, .dspark)
        XCTAssertEqual(
            refreshed.identities.support,
            SettingsDerivedFileIdentities.inspecting(plannedConfig).support
        )
        XCTAssertTrue(refreshed.mtpIsReadable)
        XCTAssertEqual(refreshed.model, initial.model)
        XCTAssertEqual(refreshed.serverIdentity, initial.serverIdentity)
    }

    func testApplyReinspectionPlanSkipsAnUnchangedConfiguration() {
        let config = ServerConfiguration.Config()

        switch SettingsApplyReinspection.plan(inspected: config, restored: config) {
        case .none:
            break
        case .auxiliaryFiles, .allFiles:
            XCTFail("an unchanged configuration must reuse the initial inspection")
        }
    }

    func testApplyReinspectionPlanCoversServerAndModelPathChanges() {
        let inspected = ServerConfiguration.Config()
        var restoredServer = inspected
        restoredServer.serverPath = "/tmp/replaced-server"
        var restoredModel = inspected
        restoredModel.modelPath = "/tmp/replaced-model.gguf"

        for restored in [restoredServer, restoredModel] {
            switch SettingsApplyReinspection.plan(
                inspected: inspected,
                restored: restored
            ) {
            case .allFiles(let planned):
                XCTAssertEqual(planned, restored)
            case .none, .auxiliaryFiles:
                XCTFail("server and model path changes must trigger full inspection")
            }
        }
    }

    // MARK: - File identity

    func testIdentityIsUnavailableForAMissingPathAndChangesOnWrite() throws {
        let missing = directory.appendingPathComponent("nope.gguf").path
        XCTAssertEqual(SettingsFileIdentity(path: missing), .unavailable)

        let file = directory.appendingPathComponent("file.bin")
        try Data("one".utf8).write(to: file)
        let before = SettingsFileIdentity(path: file.path)
        try Data("considerably longer contents".utf8).write(to: file)

        XCTAssertNotEqual(before, SettingsFileIdentity(path: file.path))
    }

    // MARK: - Pane routing

    func testEveryConfigFieldIsShownOnSomePane() {
        // `containing` is exhaustive by construction; this fails the day a new
        // field is added to a pane's Form but not to the routing switch, which
        // is what decides where Apply sends the user to see the refusal.
        for field in ServerConfiguration.Config.Field.allCases {
            let pane = SettingsPane.containing(field)
            XCTAssertTrue(
                SettingsPane.allCases.contains(pane),
                "\(field) routed to an unknown pane"
            )
        }
    }

    // MARK: - GGUF fixture

    private func makeGGUF(
        architecture: String,
        version: UInt32 = 3,
        tensorNames: [String] = []
    ) -> Data {
        var data = Data([0x47, 0x47, 0x55, 0x46])
        append(version, to: &data)
        append(UInt64(tensorNames.count), to: &data)
        append(UInt64(1), to: &data)
        append(utf8: "general.architecture", to: &data)
        append(UInt32(8), to: &data)
        append(utf8: architecture, to: &data)
        for name in tensorNames {
            append(utf8: name, to: &data)
            append(UInt32(0), to: &data)
            append(UInt32(0), to: &data)
            append(UInt64(0), to: &data)
        }
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
