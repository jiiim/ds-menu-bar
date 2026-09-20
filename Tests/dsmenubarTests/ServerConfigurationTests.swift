// SPDX-FileCopyrightText: Copyright 2026 James Martin
// SPDX-License-Identifier: MIT

import XCTest

@testable import dsmenubar

/// Tests for `ServerConfiguration.Config`'s `Codable` behavior — in
/// particular the lenient custom decoder, whose whole point is that a saved
/// blob missing a key (an older build, or a field added by a future build)
/// falls back to that field's default instead of discarding the entire
/// saved configuration.
final class ServerConfigurationTests: XCTestCase {

    func testPerformanceDisplayPreferencePersistsOutsideServerConfig() throws {
        let suiteName = "dsmenubar-tests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Unable to create isolated defaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let configuration = ServerConfiguration(defaults: defaults)
        let serverConfig = configuration.snapshot()
        XCTAssertFalse(configuration.showsPerformanceInMenuBar)

        configuration.setShowsPerformanceInMenuBar(true)

        XCTAssertTrue(configuration.showsPerformanceInMenuBar)
        XCTAssertEqual(configuration.snapshot(), serverConfig)
        XCTAssertTrue(ServerConfiguration(defaults: defaults).showsPerformanceInMenuBar)
    }

    func testKeepAwakePreferencePersistsOutsideServerConfig() throws {
        let suiteName = "dsmenubar-tests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Unable to create isolated defaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let configuration = ServerConfiguration(defaults: defaults)
        let serverConfig = configuration.snapshot()
        XCTAssertFalse(configuration.keepsAwakeWhileRunning)

        configuration.setKeepsAwakeWhileRunning(true)

        XCTAssertTrue(configuration.keepsAwakeWhileRunning)
        XCTAssertEqual(configuration.snapshot(), serverConfig)
        XCTAssertTrue(ServerConfiguration(defaults: defaults).keepsAwakeWhileRunning)
    }

    func testInitialSetupIsPromptedOnlyBeforeItIsCompleted() throws {
        let suiteName = "dsmenubar-tests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Unable to create isolated defaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let configuration = ServerConfiguration(defaults: defaults)
        XCTAssertTrue(configuration.needsInitialSetup)
        XCTAssertEqual(configuration.snapshot().serverPath, "")

        configuration.completeInitialSetup(serverPath: "", modelPath: "")
        XCTAssertTrue(configuration.needsInitialSetup)

        configuration.completeInitialSetup(
            serverPath: "~/custom/ds4-server",
            modelPath: "~/models/custom.gguf"
        )

        XCTAssertFalse(configuration.needsInitialSetup)
        XCTAssertEqual(
            configuration.snapshot().serverPath,
            DS4ServerCommand.expandingTilde("~/custom/ds4-server")
        )
        XCTAssertEqual(
            configuration.snapshot().modelPath,
            DS4ServerCommand.expandingTilde("~/models/custom.gguf")
        )
        XCTAssertEqual(
            ServerConfiguration(defaults: defaults).snapshot().serverPath,
            DS4ServerCommand.expandingTilde("~/custom/ds4-server")
        )
    }

    // MARK: - Round trip

    func testRoundTripPreservesCustomValues() throws {
        let original = ServerConfiguration.Config(
            serverPath: "~/custom/ds4-server",
            modelPath: "~/custom/model.gguf",
            host: "0.0.0.0",
            port: 9001,
            ctxSize: 2_000_000,
            kvDiskDir: "/var/tmp/kv",
            kvDiskSpaceMB: 65_536,
            kvCacheContinuedIntervalTokens: 12_500,
            mtpPath: "custom-mtp.gguf",
            qwenMTPDepth: .twoDrafts,
            qwenYarnFactor: .four,
            qwenImageMaxTokens: 8_192,
            mtpDraft: 8,
            mtpMode: .external,
            traceEnabled: false,
            tracePath: "~/custom-trace.jsonl",
            logPath: "~/custom.log",
            logMaxSizeMB: 250,
            launchAtLogin: true
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ServerConfiguration.Config.self, from: data)

        XCTAssertEqual(decoded, original)
    }

    func testLegacyTracePathMigratesToSeparateEnabledState() throws {
        let enabled = try JSONDecoder().decode(
            ServerConfiguration.Config.self,
            from: Data(#"{"tracePath":"~/legacy-trace.jsonl"}"#.utf8)
        )
        XCTAssertTrue(enabled.traceEnabled)
        XCTAssertEqual(enabled.tracePath, "~/legacy-trace.jsonl")

        let disabled = try JSONDecoder().decode(
            ServerConfiguration.Config.self,
            from: Data(#"{"tracePath":""}"#.utf8)
        )
        XCTAssertFalse(disabled.traceEnabled)
        XCTAssertEqual(disabled.tracePath, ServerConfiguration.Config().tracePath)
    }

    // MARK: - Lenient decode of missing keys

    func testEmptyBlobDecodesToDefaults() throws {
        let data = "{}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ServerConfiguration.Config.self, from: data)

        XCTAssertEqual(decoded, ServerConfiguration.Config())
    }

    func testMissingKeysFallBackToDefaultsIndividually() throws {
        // Only these two keys present; everything else must fall back to its
        // default rather than the decode failing outright.
        let json: [String: Any] = [
            "port": 9999,
            "mtpEnabled": true,
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(ServerConfiguration.Config.self, from: data)

        let defaults = ServerConfiguration.Config()
        XCTAssertEqual(decoded.port, 9999)
        XCTAssertEqual(decoded.mtpEnabled, true)
        // Everything else: unaffected by the partial blob.
        XCTAssertEqual(decoded.serverPath, defaults.serverPath)
        XCTAssertEqual(decoded.modelPath, defaults.modelPath)
        XCTAssertEqual(decoded.host, defaults.host)
        XCTAssertEqual(decoded.ctxSize, defaults.ctxSize)
        XCTAssertEqual(decoded.kvDiskDir, defaults.kvDiskDir)
        XCTAssertEqual(decoded.kvDiskSpaceMB, defaults.kvDiskSpaceMB)
        XCTAssertEqual(decoded.kvCacheContinuedIntervalTokens, defaults.kvCacheContinuedIntervalTokens)
        XCTAssertEqual(decoded.mtpPath, defaults.mtpPath)
        XCTAssertEqual(decoded.mtpDraft, defaults.mtpDraft)
        XCTAssertEqual(decoded.qwenMTPDepth, defaults.qwenMTPDepth)
        XCTAssertEqual(decoded.qwenYarnFactor, defaults.qwenYarnFactor)
        XCTAssertEqual(decoded.qwenImageMaxTokens, defaults.qwenImageMaxTokens)
        XCTAssertEqual(decoded.traceEnabled, defaults.traceEnabled)
        XCTAssertEqual(decoded.tracePath, defaults.tracePath)
        XCTAssertEqual(decoded.logPath, defaults.logPath)
        XCTAssertEqual(decoded.logMaxSizeMB, defaults.logMaxSizeMB)
        XCTAssertEqual(decoded.launchAtLogin, defaults.launchAtLogin)
    }

    func testUnknownKeysAreIgnoredNotFatal() throws {
        let json: [String: Any] = [
            "port": 1234,
            "someFieldFromAFutureBuild": "whatever",
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(ServerConfiguration.Config.self, from: data)

        XCTAssertEqual(decoded.port, 1234)
    }

    func testRemovedPLESettingsAreIgnoredDuringMigration() throws {
        let legacy = """
        {
          "serverPath": "/tmp/ds4-server",
          "modelPath": "/tmp/qwen.gguf",
          "plePath": "/tmp/legacy-ple.gguf",
          "qwenPLEPrefetch": "full",
          "qwenPLEEvictTokens": "4096"
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(ServerConfiguration.Config.self, from: legacy)
        XCTAssertEqual(decoded.serverPath, "/tmp/ds4-server")
        XCTAssertEqual(decoded.modelPath, "/tmp/qwen.gguf")

        let encoded = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
        XCTAssertFalse(encoded.contains("plePath"))
        XCTAssertFalse(encoded.contains("qwenPLE"))
    }

    func testModelProfilesRoundTripAndLegacyMTPMigration() throws {
        var config = ServerConfiguration.Config(modelPath: "/tmp/deepseek.gguf")
        config.mtpMode = .external
        config.mtpDraft = 8
        config.modelProfiles[ServerConfiguration.Config.modelKey(
            for: config.modelPath,
            serverPath: config.serverPath
        )] = DS4TuningProfile(configuration: config)

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ServerConfiguration.Config.self, from: data)
        XCTAssertEqual(decoded, config)
        XCTAssertEqual(decoded.modelProfiles.count, 1)

        let legacy = "{\"mtpEnabled\":true}".data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(ServerConfiguration.Config.self, from: legacy).mtpMode, .external)
    }

    func testExistingVisionPathMigratesToEnabled() throws {
        let legacy = "{\"visionPath\":\"/tmp/vision.gguf\"}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ServerConfiguration.Config.self, from: legacy)

        XCTAssertEqual(decoded.visionPath, "/tmp/vision.gguf")
        XCTAssertTrue(decoded.visionEnabled)
    }

    func testQwenEnvironmentSettingsRoundTripInModelProfile() throws {
        var config = ServerConfiguration.Config(modelPath: "/tmp/qwen.gguf")
        config.qwenMTPDepth = .oneDraft
        config.qwenYarnFactor = .two
        config.qwenImageMaxTokens = 2_048
        config = config.storingCurrentModelProfile()

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ServerConfiguration.Config.self, from: data)
        XCTAssertEqual(decoded, config)

        let restored = decoded.selectingModel(
            path: "/tmp/qwen.gguf",
            profile: .from(architecture: "qwen4exp")
        )
        XCTAssertEqual(restored.qwenMTPDepth, .oneDraft)
        XCTAssertEqual(restored.qwenYarnFactor, .two)
        XCTAssertEqual(restored.qwenImageMaxTokens, 2_048)
    }

    func testDSparkConfidenceRoundTripsAutomaticAndCustom() throws {
        var automatic = ServerConfiguration.Config()
        automatic.dsparkConfidence = nil
        let automaticData = try JSONEncoder().encode(automatic)
        XCTAssertNil(
            try JSONDecoder().decode(ServerConfiguration.Config.self, from: automaticData)
                .dsparkConfidence
        )

        automatic.dsparkConfidence = 0.75
        let customData = try JSONEncoder().encode(automatic)
        XCTAssertEqual(
            try JSONDecoder().decode(ServerConfiguration.Config.self, from: customData)
                .dsparkConfidence,
            0.75
        )
    }

    func testAutomaticDSparkConfidenceTracksSamplingMode() {
        var config = ServerConfiguration.Config()
        XCTAssertEqual(config.automaticDSparkConfidence, 0.6)

        config.mtpExactSampling = true
        XCTAssertEqual(config.automaticDSparkConfidence, 0.8)
    }

    func testValidationRejectsAModelDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsmenubar-model-directory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let modelDirectory = directory.appendingPathComponent("models")
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)

        XCTAssertEqual(
            DS4SelectionValidation.modelError(for: modelDirectory.path),
            "Choose a model file, not a directory."
        )
    }

    /// Whitespace in the host is always a typo: ds4-server cannot bind it and
    /// URLComponents will not build a health-check URL from it. Validation
    /// names the field the user mistyped instead of letting a launch fail and
    /// reporting it as a URL problem.
    func testHostWithWhitespaceIsRejectedByName() {
        var config = ServerConfiguration.Config()

        for host in [" 0.0.0.0", "0.0.0.0 ", "0.0.0.0\t", " [::] ", "my host"] {
            config.host = host
            XCTAssertEqual(
                config.validationErrors(modelProfile: .unknown)[.host],
                "Host cannot contain whitespace",
                host
            )
        }

        // An all-whitespace host is empty, and must still say so rather than
        // complaining about the spaces it is entirely made of.
        config.host = "   "
        XCTAssertEqual(
            config.validationErrors(modelProfile: .unknown)[.host],
            "Host cannot be empty"
        )

        for host in ["0.0.0.0", "::", "[::]", "localhost", "192.168.1.10"] {
            config.host = host
            XCTAssertNil(config.validationErrors(modelProfile: .unknown)[.host], host)
        }
    }

    func testUnknownModelDoesNotValidateOrEmitModelSpecificTuning() {
        var config = ServerConfiguration.Config()
        config.serverPath = "/opt/ds4/ds4-server"
        config.mtpMode = .external
        config.mtpPath = ""
        XCTAssertTrue(config.validationErrors(modelProfile: .unknown).isEmpty)
        let args = DS4ServerCommand.arguments(
            configuration: config,
            resolvedModelPath: "/tmp/unknown.gguf",
            resolvedMTPPath: "",
            modelProfile: .unknown
        )
        XCTAssertFalse(args.contains("--mtp-model"))
    }

    func testNormalizationStoresSelectionPathsAbsolute() {
        var config = ServerConfiguration.Config()
        config.serverPath = "/opt/ds4/ds4-server"
        config.modelPath = "gguf/main.gguf"
        config.mtpPath = "gguf/support.gguf"
        config.visionPath = "gguf/vision.gguf"

        let normalized = config.normalized()

        XCTAssertEqual(normalized.serverPath, "/opt/ds4/ds4-server")
        XCTAssertEqual(normalized.modelPath, "/opt/ds4/gguf/main.gguf")
        XCTAssertEqual(normalized.mtpPath, "/opt/ds4/gguf/support.gguf")
        XCTAssertEqual(normalized.visionPath, "/opt/ds4/gguf/vision.gguf")
    }

    // MARK: - Tuning defaults

    func testRestoringTuningDefaultsPreservesOperationalSettings() {
        var current = ServerConfiguration.Config()
        current.serverPath = "~/custom/ds4-server"
        current.modelPath = "~/custom/model.gguf"
        current.host = "0.0.0.0"
        current.port = 9001
        current.corsEnabled = true
        current.mtpPath = "custom-mtp.gguf"
        current.kvDiskDir = "/var/tmp/kv"
        current.traceEnabled = true
        current.tracePath = "~/custom-trace.jsonl"
        current.logPath = "~/custom.log"
        current.logMaxSizeMB = 500
        current.launchAtLogin = true

        current.defaultTokens = 2_048
        current.ctxSize = 2_000_000
        current.threads = 8
        current.powerPercent = 75
        current.prefillChunk = 512
        current.warmWeights = true
        current.quality = true
        current.batchedSessions = 4
        current.mixedPrefillQuantum = 64
        current.ssdStreamingEnabled = true
        current.ssdStreamingCold = true
        current.ssdStreamingCacheExperts = "40GB"
        current.ssdStreamingFullLayers = 8
        current.ssdStreamingPreloadExperts = 12
        current.kvDiskEnabled = false
        current.kvDiskSpaceMB = 65_536
        current.kvCacheMinTokens = 1_024
        current.kvCacheColdMaxTokens = 60_000
        current.kvCacheContinuedIntervalTokens = 12_500
        current.kvCacheBoundaryTrimTokens = 16
        current.kvCacheBoundaryAlignTokens = 1_024
        current.kvCacheRejectDifferentQuant = true
        current.disableExactDSMLToolReplay = true
        current.toolMemoryMaxIDs = 50_000
        current.mtpDraft = 8
        current.mtpMargin = 5.0
        current.mtpEnabled = true

        var expected = ServerConfiguration.Config()
        DS4TuningProfile.defaults(for: DS4ModelFamily.unknown).applying(to: &expected)
        expected.serverPath = current.serverPath
        expected.modelPath = current.modelPath
        expected.host = current.host
        expected.port = current.port
        expected.corsEnabled = current.corsEnabled
        expected.mtpPath = current.mtpPath
        expected.kvDiskDir = current.kvDiskDir
        expected.traceEnabled = current.traceEnabled
        expected.tracePath = current.tracePath
        expected.logPath = current.logPath
        expected.logMaxSizeMB = current.logMaxSizeMB
        expected.launchAtLogin = current.launchAtLogin
        expected.modelProfiles[ServerConfiguration.Config.modelKey(
            for: current.modelPath,
            serverPath: current.serverPath
        )] = DS4TuningProfile(configuration: expected)

        XCTAssertEqual(current.restoringTuningDefaults(), expected)
    }
}
