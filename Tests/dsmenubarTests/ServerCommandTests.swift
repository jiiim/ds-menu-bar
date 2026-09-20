// SPDX-FileCopyrightText: Copyright 2026 James Martin
// SPDX-License-Identifier: MIT

import XCTest

@testable import dsmenubar

final class ServerCommandTests: XCTestCase {

    func testDefaultArgumentsUseTheLocalMetalWorkflow() {
        let args = DS4ServerCommand.arguments(
            configuration: ServerConfiguration.Config(),
            resolvedModelPath: "/tmp/model.gguf",
            resolvedMTPPath: "/tmp/mtp.gguf"
        )

        XCTAssertEqual(args, [
            "--metal",
            "--model", "/tmp/model.gguf",
            "--ctx", "1000000",
            "--host", "127.0.0.1",
            "--port", "8000",
            "--power", "100"
        ])
    }

    func testOptionalArgumentsFollowConfiguration() {
        var config = ServerConfiguration.Config()
        config.defaultTokens = 2_048
        config.threads = 8
        config.powerPercent = 75
        config.prefillChunk = 1_024
        config.warmWeights = true
        config.quality = true
        config.corsEnabled = true
        config.traceEnabled = true
        config.tracePath = "~/trace.jsonl"
        config.batchedSessions = 3
        config.mixedPrefillQuantum = 256
        config.ssdStreamingEnabled = true
        config.ssdStreamingCold = true
        config.ssdStreamingCacheExperts = " 40GB "
        config.ssdStreamingFullLayers = 2
        config.ssdStreamingPreloadExperts = 6
        config.kvDiskEnabled = true
        config.kvCacheRejectDifferentQuant = true
        config.disableExactDSMLToolReplay = true
        config.mtpEnabled = false

        let args = DS4ServerCommand.arguments(
            configuration: config,
            resolvedModelPath: "/tmp/model.gguf",
            resolvedMTPPath: "/tmp/mtp.gguf"
        )

        // Compared as a whole: a per-element `contains` check would pass even if
        // a flag were paired with the wrong value.
        XCTAssertEqual(args, [
            "--metal",
            "--model", "/tmp/model.gguf",
            "--ctx", "1000000",
            "--host", "127.0.0.1",
            "--port", "8000",
            "--power", "75",
            "--tokens", "2048",
            "--threads", "8",
            "--prefill-chunk", "1024",
            "--warm-weights",
            "--quality",
            "--cors",
            "--trace", DS4ServerCommand.expandingTilde("~/trace.jsonl"),
            "--batched-session", "3",
            "--mixed-prefill-quantum", "256",
            "--ssd-streaming",
            "--ssd-streaming-cold",
            "--ssd-streaming-cache-experts", "40GB",
            "--ssd-streaming-preload-experts", "6",
            "--kv-disk-dir", "/tmp/ds4-kv",
            "--kv-disk-space-mb", "131072",
            "--kv-cache-min-tokens", "512",
            "--kv-cache-cold-max-tokens", "30000",
            "--kv-cache-continued-interval-tokens", "25000",
            "--kv-cache-boundary-trim-tokens", "32",
            "--kv-cache-boundary-align-tokens", "2048",
            "--tool-memory-max-ids", "100000",
            "--kv-cache-reject-different-quant",
            "--disable-exact-dsml-tool-replay"
        ])
    }

    func testDisabledTraceRetainsPathWithoutAddingArgument() {
        var config = ServerConfiguration.Config()
        config.traceEnabled = false
        config.tracePath = "~/retained-trace.jsonl"

        let args = DS4ServerCommand.arguments(
            configuration: config,
            resolvedModelPath: "/tmp/model.gguf",
            resolvedMTPPath: "/tmp/mtp.gguf"
        )

        XCTAssertFalse(args.contains("--trace"))
        XCTAssertEqual(config.tracePath, "~/retained-trace.jsonl")
    }

    func testDisablingKVDiskAndSSDStreamingDropsTheirArguments() {
        var config = ServerConfiguration.Config()
        config.kvDiskEnabled = false
        config.ssdStreamingEnabled = false
        config.ssdStreamingCold = true
        config.ssdStreamingPreloadExperts = 4

        let args = DS4ServerCommand.arguments(
            configuration: config,
            resolvedModelPath: "/tmp/model.gguf",
            resolvedMTPPath: "/tmp/mtp.gguf"
        )

        XCTAssertEqual(args, [
            "--metal",
            "--model", "/tmp/model.gguf",
            "--ctx", "1000000",
            "--host", "127.0.0.1",
            "--port", "8000",
            "--power", "100"
        ])
    }

    func testMTPArgumentsUseResolvedSupportModel() {
        var config = ServerConfiguration.Config()
        config.mtpEnabled = true
        config.mtpDraft = 8
        config.mtpMargin = 3.5

        let args = DS4ServerCommand.arguments(
            configuration: config,
            resolvedModelPath: "/tmp/model.gguf",
            resolvedMTPPath: "/tmp/mtp.gguf",
            modelProfile: .from(architecture: "deepseek4"),
            supportProfile: DS4SupportProfile(kind: .legacyMTP, architecture: "deepseek4_mtp_support")
        )

        XCTAssertTrue(args.contains("--mtp-model"))
        XCTAssertTrue(args.contains("/tmp/mtp.gguf"))
        XCTAssertTrue(args.contains("--mtp-draft"))
        XCTAssertTrue(args.contains("8"))
        XCTAssertTrue(args.contains("--mtp-margin"))
        XCTAssertTrue(args.contains("3.5"))
    }

    func testDefaultsRequireServerSelection() {
        let config = ServerConfiguration.Config()
        XCTAssertEqual(config.serverPath, "")
        XCTAssertEqual(config.modelPath, "ds4flash.gguf")
        XCTAssertEqual(
            config.validationErrors()[.serverPath],
            "Choose a ds4-server executable"
        )
    }

    func testQwenCommandUsesSelfContainedModelAndModelBounds() {
        let model = DS4ModelProfile(
            family: .qwen38,
            architecture: "qwen4exp",
            contextLength: 262_144,
            nextnPredictLayers: 1,
            embeddingLength: 4_096,
            qwenNGramRowCount: 10_000,
            qwenNGramRowDimension: 256,
            hasNativeQwenNGrams: true
        )
        var config = ServerConfiguration.Config()
        config.serverPath = "/opt/ds4/ds4-server"
        config.ctxSize = 8_192
        config.prefillChunk = 1_024
        config.mtpMode = .embedded
        config.mtpDraft = 8

        XCTAssertTrue(config.validationErrors(modelProfile: model).isEmpty)
        let args = DS4ServerCommand.arguments(
            configuration: config,
            resolvedModelPath: "/tmp/qwen.gguf",
            resolvedMTPPath: "",
            modelProfile: model
        )
        XCTAssertEqual(Array(args.prefix(6)), [
            "--metal", "--model", "/tmp/qwen.gguf", "--ctx", "8192", "--host"
        ])
        XCTAssertTrue(args.contains("--prefill-chunk"))
        XCTAssertTrue(args.contains("--mtp"))
        XCTAssertFalse(args.contains("--mtp-draft"))
        XCTAssertFalse(args.contains("--ple"))

        config.prefillChunk = 65_537
        XCTAssertNotNil(config.validationErrors(modelProfile: model)[.prefillChunk])
        config.prefillChunk = 1_024
        config.ssdStreamingEnabled = true
        XCTAssertNotNil(config.validationErrors(modelProfile: model)[.ssdStreamingEnabled])
    }

    func testDefaultsScaleWithUnifiedMemory() {
        let gibibyte = UInt64(1_024 * 1_024 * 1_024)
        let compactQwen = DS4TuningProfile.defaults(
            for: .qwen38,
            physicalMemoryBytes: 64 * gibibyte
        )
        let middleQwen = DS4TuningProfile.defaults(
            for: .qwen38,
            physicalMemoryBytes: 96 * gibibyte
        )
        let largeQwen = DS4TuningProfile.defaults(
            for: .qwen38,
            physicalMemoryBytes: 128 * gibibyte
        )

        XCTAssertEqual(compactQwen.ctxSize, 131_072)
        XCTAssertEqual(compactQwen.prefillChunk, 2_048)
        XCTAssertEqual(middleQwen.ctxSize, 131_072)
        XCTAssertEqual(middleQwen.prefillChunk, 4_096)
        XCTAssertEqual(largeQwen.ctxSize, 262_144)
        XCTAssertEqual(largeQwen.prefillChunk, 0)
        var largeConfig = ServerConfiguration.Config()
        largeQwen.applying(to: &largeConfig)
        let largeArguments = DS4ServerCommand.arguments(
            configuration: largeConfig,
            resolvedModelPath: "/tmp/qwen.gguf",
            resolvedMTPPath: "",
            modelProfile: .from(architecture: "qwen4exp")
        )
        XCTAssertFalse(largeArguments.contains("--prefill-chunk"))
        XCTAssertEqual(
            DS4TuningProfile.defaults(
                for: .deepSeek,
                physicalMemoryBytes: 64 * gibibyte
            ).ctxSize,
            393_216
        )
    }

    func testQwenDefaultsAreCappedByModelContext() {
        let model = DS4ModelProfile(
            family: .qwen38,
            architecture: "qwen4exp",
            contextLength: 65_536
        )

        let config = ServerConfiguration.Config()
            .selectingModel(path: "/tmp/qwen.gguf", profile: model)

        XCTAssertEqual(config.ctxSize, 65_536)
        XCTAssertLessThanOrEqual(config.prefillChunk, config.ctxSize)
        XCTAssertEqual(config.integerConstraint(for: .ctxSize, modelProfile: model)?.recommendedValue, 65_536)
    }

    func testValidationDefersQwenNGramCompatibilityToServer() {
        let legacyModel = DS4ModelProfile(
            family: .qwen38,
            architecture: "qwen4exp",
            hasNativeQwenNGrams: false
        )
        let error = ServerConfiguration.Config()
            .validationErrors(modelProfile: legacyModel)[.modelPath]

        XCTAssertNil(error)
    }

    func testQwenEnvironmentSettingsAndPreview() {
        let model = DS4ModelProfile(
            family: .qwen38,
            architecture: "qwen4exp",
            nextnPredictLayers: 1
        )
        var config = ServerConfiguration.Config()
        config.serverPath = "/tmp/ds4 server/ds4-server"
        config.mtpMode = .embedded
        config.qwenMTPDepth = .twoDrafts
        config.qwenYarnFactor = .four
        config.visionEnabled = true
        config.qwenImageMaxTokens = 16_383

        let expected = [
            "DS4_QWEN4_MTP_DEPTH": "3",
            "DS4_QWEN4_YARN_FACTOR": "4",
            "DS4_QWEN4_IMAGE_MAX_TOKENS": "16383"
        ]
        XCTAssertEqual(
            DS4ServerCommand.environmentOverrides(configuration: config, modelProfile: model),
            expected
        )

        let preview = DS4ServerCommand.preview(configuration: config, modelProfile: model)
        for (key, value) in expected {
            XCTAssertTrue(preview.contains("\(key)=\(value)"), key)
        }
        XCTAssertTrue(preview.contains("'/tmp/ds4 server/ds4-server'"))
    }

    func testManagedQwenEnvironmentDoesNotLeakFromParentOrInactiveFeatures() {
        let model = DS4ModelProfile(family: .qwen38, architecture: "qwen4exp")
        let config = ServerConfiguration.Config()
        let inherited = Dictionary(uniqueKeysWithValues: DS4ServerCommand.managedQwenEnvironmentKeys.map {
            ($0, "inherited")
        })
        let environment = DS4ServerCommand.launchEnvironment(
            configuration: config,
            modelProfile: model,
            inheriting: inherited.merging(["PATH": "/bin"]) { current, _ in current }
        )

        XCTAssertEqual(environment["PATH"], "/bin")
        XCTAssertNil(environment["DS4_QWEN4_MTP_DEPTH"])
        XCTAssertNil(environment["DS4_QWEN4_YARN_FACTOR"])
        XCTAssertNil(environment["DS4_QWEN4_IMAGE_MAX_TOKENS"])

        let preview = DS4ServerCommand.preview(configuration: config, modelProfile: model)
        XCTAssertTrue(preview.hasPrefix("/usr/bin/env "))
        for key in DS4ServerCommand.managedQwenEnvironmentKeys {
            XCTAssertTrue(preview.contains(key), key)
        }

        XCTAssertTrue(DS4ServerCommand.environmentOverrides(
            configuration: config,
            modelProfile: .from(architecture: "glm5-next")
        ).isEmpty)

        let nonQwenPreview = DS4ServerCommand.preview(
            configuration: config,
            modelProfile: .from(architecture: "glm5-next")
        )
        XCTAssertTrue(nonQwenPreview.hasPrefix("/usr/bin/env "))
        for key in DS4ServerCommand.managedQwenEnvironmentKeys {
            XCTAssertTrue(nonQwenPreview.contains("-u " + key), key)
        }
    }

    func testFullGLMDefaultsAndCommandUseStreamingWithoutManualPrefill() {
        let model = DS4ModelProfile(
            family: .glm53Full,
            architecture: "glm-dsa",
            contextLength: 1_048_576,
            blockCount: 79,
            expertCount: 256,
            leadingDenseBlockCount: 3,
            nextnPredictLayers: 1
        )
        var config = ServerConfiguration.Config().selectingModel(path: "/tmp/glm53.gguf", profile: model)
        XCTAssertEqual(config.ctxSize, DS4TuningProfile.defaults(for: model).ctxSize)
        XCTAssertEqual(config.mixedPrefillQuantum, 1_024)
        XCTAssertTrue(config.ssdStreamingEnabled)
        config.prefillChunk = 2_048
        config.ssdStreamingFullLayers = 4

        let args = DS4ServerCommand.arguments(
            configuration: config,
            resolvedModelPath: "/tmp/glm53.gguf",
            resolvedMTPPath: "",
            modelProfile: model
        )
        XCTAssertTrue(args.contains("--ssd-streaming"))
        XCTAssertTrue(args.contains("--ssd-streaming-full-layers"))
        XCTAssertFalse(args.contains("--prefill-chunk"))
    }

    func testDeepSeek41CommandOmitsManualPrefillAndMTP() {
        let model = DS4ModelProfile(
            family: .deepSeek41,
            architecture: "deepseek41",
            contextLength: 1_048_576,
            hasVisualRouterBiases: true
        )
        var config = ServerConfiguration.Config().selectingModel(path: "/tmp/v41.gguf", profile: model)
        XCTAssertEqual(config.ctxSize, DS4TuningProfile.defaults(for: model).ctxSize)
        config.prefillChunk = 2_048
        config.mtpMode = .embedded
        config.visionEnabled = true
        config.visionPath = "/tmp/v41-vision.gguf"
        let vision = DS4VisionProfile(
            kind: .deepSeek41,
            architecture: "deepseek4-vision",
            projectionDimension: 5_120
        )

        let args = DS4ServerCommand.arguments(
            configuration: config,
            resolvedModelPath: "/tmp/v41.gguf",
            resolvedMTPPath: "/tmp/stale-mtp.gguf",
            resolvedVisionPath: "/tmp/v41-vision.gguf",
            modelProfile: model,
            visionProfile: vision
        )
        XCTAssertEqual(args, [
            "--metal", "--model", "/tmp/v41.gguf",
            "--ctx", "\(config.ctxSize)", "--host", "127.0.0.1", "--port", "8000", "--power", "100",
            "--vision", "/tmp/v41-vision.gguf"
        ])
    }

    func testModelAwareNumericConstraintsEnforceContextPowerAndStreamingMetadata() {
        let qwen = DS4ModelProfile(family: .qwen38, architecture: "qwen4exp", contextLength: 262_144)
        var config = ServerConfiguration.Config()
        config.ctxSize = 262_145
        config.powerPercent = 99
        XCTAssertNotNil(config.validationErrors(modelProfile: qwen)[.ctxSize])
        XCTAssertNotNil(config.validationErrors(modelProfile: qwen)[.powerPercent])
        config.qwenYarnFactor = .four
        config.ctxSize = 1_048_576
        XCTAssertNil(config.validationErrors(modelProfile: qwen)[.ctxSize])
        config.ctxSize = 1_048_577
        XCTAssertNotNil(config.validationErrors(modelProfile: qwen)[.ctxSize])

        let glm = DS4ModelProfile(
            family: .glm52,
            architecture: "glm-dsa",
            blockCount: 79,
            expertCount: 256,
            leadingDenseBlockCount: 3
        )
        config = ServerConfiguration.Config()
        config.ssdStreamingEnabled = true
        config.ssdStreamingFullLayers = 77
        config.ssdStreamingPreloadExperts = 19_457
        let errors = config.validationErrors(modelProfile: glm)
        XCTAssertNotNil(errors[.ssdStreamingFullLayers])
        XCTAssertNotNil(errors[.ssdStreamingPreloadExperts])
    }

    func testAllNonIntegerNumericDescriptorsEnforceParserBounds() {
        let config = ServerConfiguration.Config()
        XCTAssertTrue(config.decimalConstraint(for: .mtpMargin)?.contains(0) == true)
        XCTAssertTrue(config.decimalConstraint(for: .mtpMargin)?.contains(1_000) == true)
        XCTAssertTrue(config.decimalConstraint(for: .mtpMargin)?.contains(1_000.1) == false)
        XCTAssertTrue(config.decimalConstraint(for: .dsparkConfidence)?.contains(1) == true)
        XCTAssertTrue(config.decimalConstraint(for: .dsparkConfidence)?.contains(1.01) == false)

        let memory = config.numericTextConstraint(for: .simulateUsedMemory)!
        XCTAssertTrue(memory.contains("\(DS4ConfigurationLimits.maxGiB)GB"))
        XCTAssertFalse(memory.contains("\(DS4ConfigurationLimits.maxGiB + 1)GB"))

        let glm = DS4ModelProfile(
            family: .glm53Full,
            architecture: "glm-dsa",
            blockCount: 10,
            expertCount: 8,
            leadingDenseBlockCount: 2
        )
        let cache = config.numericTextConstraint(for: .ssdStreamingCacheExperts, modelProfile: glm)!
        XCTAssertTrue(cache.contains("64"))
        XCTAssertFalse(cache.contains("65"))
        XCTAssertTrue(cache.contains("40GB"))

        XCTAssertEqual(config.integerConstraint(for: .mixedPrefillQuantum, modelProfile: glm)?.minimum, 1_024)
        XCTAssertEqual(
            config.integerConstraint(
                for: .prefillChunk,
                modelProfile: .from(architecture: "qwen4exp")
            )?.recommendedValue,
            DS4TuningProfile.defaults(for: .qwen38).prefillChunk
        )
    }

    func testEveryIntegerSettingsFieldHasInclusiveBounds() {
        let config = ServerConfiguration.Config()
        let fullGLM = DS4ModelProfile(
            family: .glm53Full,
            architecture: "glm-dsa",
            contextLength: 1_048_576,
            blockCount: 79,
            expertCount: 256,
            leadingDenseBlockCount: 3
        )
        let fields: [ServerConfiguration.Config.Field] = [
            .port, .defaultTokens, .ctxSize, .threads, .powerPercent, .prefillChunk,
            .batchedSessions, .mixedPrefillQuantum, .ssdStreamingFullLayers,
            .ssdStreamingPreloadExperts, .kvDiskSpaceMB, .kvCacheMinTokens,
            .kvCacheColdMaxTokens, .kvCacheContinuedIntervalTokens,
            .kvCacheBoundaryTrimTokens, .kvCacheBoundaryAlignTokens,
            .toolMemoryMaxIDs, .mtpDraft, .qwenImageMaxTokens, .logMaxSizeMB
        ]

        for field in fields {
            let profile: DS4ModelProfile
            switch field {
            case .prefillChunk, .qwenImageMaxTokens:
                profile = .from(architecture: "qwen4exp")
            case .mtpDraft:
                profile = .from(architecture: "deepseek4")
            default:
                profile = fullGLM
            }
            let constraint = config.integerConstraint(for: field, modelProfile: profile)
            XCTAssertNotNil(constraint, field.rawValue)
            guard let constraint else { continue }
            XCTAssertTrue(constraint.contains(constraint.minimum), field.rawValue)
            XCTAssertTrue(constraint.contains(constraint.maximum), field.rawValue)
            XCTAssertFalse(constraint.contains(constraint.minimum - 1), field.rawValue)
            XCTAssertFalse(constraint.contains(constraint.maximum + 1), field.rawValue)
            XCTAssertGreaterThan(constraint.step, 0, field.rawValue)
            XCTAssertFalse(constraint.source.isEmpty, field.rawValue)
        }
    }

    func testMTPDraftConstraintOnlyAppliesToLegacyExternalMTP() {
        let config = ServerConfiguration.Config()
        XCTAssertNotNil(config.integerConstraint(
            for: .mtpDraft,
            modelProfile: .from(architecture: "deepseek4")
        ))
        XCTAssertNil(config.integerConstraint(
            for: .mtpDraft,
            modelProfile: .from(architecture: "qwen4exp")
        ))
        XCTAssertNil(config.integerConstraint(
            for: .mtpDraft,
            modelProfile: .from(architecture: "glm5-next")
        ))
    }

    func testQwenImageTokenValidationUsesUpstreamBounds() {
        let qwen = DS4ModelProfile.from(architecture: "qwen4exp")
        var config = ServerConfiguration.Config()
        config.visionEnabled = true
        config.qwenImageMaxTokens = 63
        XCTAssertNotNil(config.validationErrors(modelProfile: qwen)[.qwenImageMaxTokens])
        config.qwenImageMaxTokens = 16_383
        XCTAssertNil(config.validationErrors(modelProfile: qwen)[.qwenImageMaxTokens])
    }

    func testEmbeddedMTPRequiresAdvertisedWeights() {
        var config = ServerConfiguration.Config()
        config.mtpMode = .embedded
        let withoutMTP = DS4ModelProfile.from(architecture: "qwen4exp")
        XCTAssertNotNil(config.validationErrors(modelProfile: withoutMTP)[.mtpMode])
        XCTAssertFalse(DS4ServerCommand.arguments(
            configuration: config,
            resolvedModelPath: "/tmp/qwen.gguf",
            resolvedMTPPath: "",
            modelProfile: withoutMTP
        ).contains("--mtp"))
    }

    func testQwenEmbeddedMTPCanUseNativeSessionBatching() {
        let qwen = DS4ModelProfile(
            family: .qwen38,
            architecture: "qwen4exp",
            nextnPredictLayers: 1
        )
        var config = ServerConfiguration.Config()
        config.batchedSessions = 4
        config.mtpMode = .embedded
        config.mtpExactSampling = true

        let errors = config.validationErrors(modelProfile: qwen)
        XCTAssertNil(errors[.batchedSessions])
        XCTAssertNil(errors[.mtpMode])

        let args = DS4ServerCommand.arguments(
            configuration: config,
            resolvedModelPath: "/tmp/qwen.gguf",
            resolvedMTPPath: "",
            modelProfile: qwen
        )
        XCTAssertTrue(args.contains("--batched-session"))
        XCTAssertTrue(args.contains("--mtp"))
        XCTAssertTrue(args.contains("--mtp-exact-sampling"))
    }

    func testSessionBatchingRejectsMTPForOtherModelsAndModes() {
        let glm = DS4ModelProfile(
            family: .glm53Flash,
            architecture: "glm5-next",
            nextnPredictLayers: 1
        )
        var embedded = ServerConfiguration.Config()
        embedded.batchedSessions = 2
        embedded.mtpMode = .embedded
        XCTAssertNotNil(embedded.validationErrors(modelProfile: glm)[.batchedSessions])

        let deepSeek = DS4ModelProfile.from(architecture: "deepseek4")
        for mode in [MTPMode.external, .dspark] {
            var config = ServerConfiguration.Config()
            config.batchedSessions = 2
            config.mtpMode = mode
            XCTAssertNotNil(
                config.validationErrors(modelProfile: deepSeek)[.batchedSessions],
                mode.rawValue
            )
        }

        // A Qwen GGUF without nextn weights cannot speculate at all, so it
        // keeps the conflict even though the family is otherwise eligible.
        let qwenWithoutNextn = DS4ModelProfile(
            family: .qwen38,
            architecture: "qwen4exp",
            nextnPredictLayers: 0
        )
        var bare = ServerConfiguration.Config()
        bare.batchedSessions = 2
        bare.mtpMode = .embedded
        XCTAssertNotNil(bare.validationErrors(modelProfile: qwenWithoutNextn)[.batchedSessions])
    }

    /// The Settings panes and `validationErrors` must not drift apart; both
    /// read the conflict from `hasBatchedSessionMTPConflict`.
    func testBatchedSessionMTPConflictMatchesTheValidationError() {
        let qwen = DS4ModelProfile(
            family: .qwen38,
            architecture: "qwen4exp",
            nextnPredictLayers: 1
        )
        let profiles = [qwen, .from(architecture: "deepseek4"), .from(architecture: "glm5-next"), .unknown]
        for profile in profiles {
            for mode in MTPMode.allCases {
                for sessions in [0, 4] {
                    var config = ServerConfiguration.Config()
                    config.batchedSessions = sessions
                    config.mtpMode = mode
                    XCTAssertEqual(
                        config.hasBatchedSessionMTPConflict(modelProfile: profile),
                        config.validationErrors(modelProfile: profile)[.batchedSessions] != nil,
                        "\(profile.family.rawValue) \(mode.rawValue) \(sessions)"
                    )
                }
            }
        }
    }

    /// Ports 1–1023 are privileged. ds4-server runs as a child of the app,
    /// with the app's uid, so a bind there always fails with EACCES — which
    /// arrives as a line in the server log long after Settings could have said
    /// so. Validation owns the whole unusable range, not just the arithmetic
    /// one above 65535.
    func testValidationRejectsPrivilegedPorts() {
        var config = ServerConfiguration.Config()
        config.serverPath = "/opt/ds4/ds4-server"

        for port in [1, 80, 443, 1_023] {
            config.port = port
            XCTAssertEqual(
                config.validationErrors(modelProfile: .unknown)[.port],
                "Port must be between 1024 and 65535",
                "\(port)"
            )
        }

        for port in [1_024, 8_000, 65_535] {
            config.port = port
            XCTAssertNil(config.validationErrors(modelProfile: .unknown)[.port], "\(port)")
        }
    }

    func testValidationRejectsParserLimitsAndConflicts() {
        var config = ServerConfiguration.Config()
        config.port = 65_536
        config.powerPercent = 0
        config.ctxSize = 0
        config.defaultTokens = -1
        config.batchedSessions = 2
        config.mixedPrefillQuantum = 0
        config.mtpEnabled = true
        config.mtpDraft = 17
        config.mtpMargin = 1_001
        config.ssdStreamingEnabled = true
        config.ssdStreamingCacheExperts = "40MB"
        // KV bounds are only validated for an enabled cache, which is not the
        // default.
        config.kvDiskEnabled = true
        config.kvCacheMinTokens = 10_000
        config.kvCacheColdMaxTokens = 9_999

        let errors = config.validationErrors(modelProfile: .from(architecture: "deepseek4"))

        XCTAssertNotNil(errors[ServerConfiguration.Config.Field.port])
        XCTAssertNotNil(errors[ServerConfiguration.Config.Field.powerPercent])
        XCTAssertNotNil(errors[ServerConfiguration.Config.Field.ctxSize])
        XCTAssertNotNil(errors[ServerConfiguration.Config.Field.defaultTokens])
        XCTAssertNotNil(errors[ServerConfiguration.Config.Field.mixedPrefillQuantum])
        XCTAssertNotNil(errors[ServerConfiguration.Config.Field.batchedSessions])
        XCTAssertNotNil(errors[ServerConfiguration.Config.Field.mtpDraft])
        XCTAssertNotNil(errors[ServerConfiguration.Config.Field.mtpMargin])
        XCTAssertNotNil(errors[ServerConfiguration.Config.Field.ssdStreamingEnabled])
        XCTAssertNotNil(errors[ServerConfiguration.Config.Field.mtpMode])
        XCTAssertNotNil(errors[ServerConfiguration.Config.Field.ssdStreamingCacheExperts])
        XCTAssertNotNil(errors[ServerConfiguration.Config.Field.kvCacheColdMaxTokens])
    }

    func testSSDStreamingConflictOnlyAppliesToExternalSupportModels() {
        let deepSeek = DS4ModelProfile.from(architecture: "deepseek4")
        for mode in [MTPMode.external, .dspark] {
            var config = ServerConfiguration.Config()
            config.ssdStreamingEnabled = true
            config.mtpMode = mode
            let errors = config.validationErrors(modelProfile: deepSeek)
            XCTAssertNotNil(errors[.ssdStreamingEnabled], mode.rawValue)
            XCTAssertNotNil(errors[.mtpMode], mode.rawValue)
        }

        var off = ServerConfiguration.Config()
        off.ssdStreamingEnabled = true
        XCTAssertNil(off.validationErrors(modelProfile: deepSeek)[.ssdStreamingEnabled])

        var embedded = ServerConfiguration.Config()
        embedded.ssdStreamingEnabled = true
        embedded.mtpMode = .embedded
        XCTAssertNil(
            embedded.validationErrors(
                modelProfile: .from(architecture: "glm5-next")
            )[.ssdStreamingEnabled]
        )
    }

    func testConditionalFieldsAreIgnoredWhenFeatureIsDisabled() {
        var config = ServerConfiguration.Config()
        config.serverPath = "/opt/ds4/ds4-server"
        config.ssdStreamingEnabled = false
        config.ssdStreamingCacheExperts = "not-a-cache-value"
        config.ssdStreamingFullLayers = -2
        config.ssdStreamingPreloadExperts = -1
        config.kvDiskEnabled = false
        config.kvDiskDir = ""
        config.kvDiskSpaceMB = 0
        config.kvCacheMinTokens = 0
        config.toolMemoryMaxIDs = 0
        config.mtpEnabled = false
        config.mtpPath = ""
        config.mtpDraft = 0
        config.mtpMargin = -1

        XCTAssertTrue(config.isValid)
    }

    /// `arguments` runs on unvalidated Settings drafts (the live command
    /// preview), so Double formatting has to survive values that validation
    /// would reject rather than trapping in `Int(_:)`.
    func testMarginFormattingSurvivesOutOfRangeDrafts() {
        XCTAssertEqual(DS4ServerCommand.format(3), "3")
        XCTAssertEqual(DS4ServerCommand.format(3.5), "3.5")
        XCTAssertEqual(DS4ServerCommand.format(0), "0")
        // A rejected value is shown, not substituted — "0" would read as valid.
        XCTAssertEqual(DS4ServerCommand.format(.infinity), "inf")
        XCTAssertEqual(DS4ServerCommand.format(.nan), "nan")
        XCTAssertEqual(DS4ServerCommand.format(1e21), "1e+21")
        XCTAssertEqual(DS4ServerCommand.format(-1e21), "-1e+21")
    }

    /// The launch path reports one message, so the choice has to be stable:
    /// `Dictionary.values.first` varies run to run for the same configuration.
    func testFirstValidationErrorFollowsFieldOrder() {
        var config = ServerConfiguration.Config()
        config.serverPath = "/opt/ds4/ds4-server"
        config.host = ""          // earlier in Field order
        config.port = 70_000
        config.ctxSize = 0

        let first = config.firstValidationError()
        XCTAssertEqual(first, config.validationErrors()[.host])
        // Stable across repeated calls on independent copies.
        for _ in 0..<50 {
            var copy = ServerConfiguration.Config(host: "", port: 70_000)
            copy.serverPath = "/opt/ds4/ds4-server"
            XCTAssertEqual(copy.firstValidationError(), first)
        }
        var valid = ServerConfiguration.Config()
        valid.serverPath = "/opt/ds4/ds4-server"
        XCTAssertNil(valid.firstValidationError())
    }

    func testPreviewRendersAnOutOfRangeDraftWithoutTrapping() {
        var config = ServerConfiguration.Config()
        config.mtpEnabled = true
        config.mtpMargin = 1e21          // rejected by validation, still previewable
        config.serverPath = "/tmp/dir with spaces/ds4-server"

        XCTAssertFalse(config.validationErrors(modelProfile: .from(architecture: "deepseek4")).isEmpty)
        let preview = DS4ServerCommand.preview(configuration: config, modelProfile: .from(architecture: "deepseek4"))
        XCTAssertTrue(preview.contains("'/tmp/dir with spaces/ds4-server'"))
        XCTAssertTrue(preview.hasSuffix("2>&1"))
    }

    func testNormalizedClampsDraftTokensFromAnOlderBlob() {
        var config = ServerConfiguration.Config()
        config.mtpDraft = 99
        XCTAssertEqual(config.normalized().mtpDraft, DS4ConfigurationLimits.maxMTPDraft)
        config.mtpDraft = 0
        XCTAssertEqual(config.normalized().mtpDraft, DS4ConfigurationLimits.minMTPDraft)
    }

    func testSSDCacheExpertSyntax() {
        XCTAssertTrue(ServerConfiguration.Config.isValidSSDCacheExperts("8"))
        XCTAssertTrue(ServerConfiguration.Config.isValidSSDCacheExperts("40GB"))
        XCTAssertTrue(ServerConfiguration.Config.isValidSSDCacheExperts(" 40gb "))
        XCTAssertFalse(ServerConfiguration.Config.isValidSSDCacheExperts("0"))
        XCTAssertFalse(ServerConfiguration.Config.isValidSSDCacheExperts("0GB"))
        XCTAssertFalse(ServerConfiguration.Config.isValidSSDCacheExperts("40MB"))
        XCTAssertFalse(ServerConfiguration.Config.isValidSSDCacheExperts("GB"))
        XCTAssertFalse(ServerConfiguration.Config.isValidSSDCacheExperts("+5gb"))
        XCTAssertFalse(ServerConfiguration.Config.isValidSSDCacheExperts("4294967296"))
        XCTAssertFalse(ServerConfiguration.Config.isValidSSDCacheExperts("17179869184GB"))
    }

    func testRelativeResourcePathsResolveAgainstTheServerDirectory() {
        XCTAssertEqual(
            DS4ServerCommand.resolving("gguf/model.gguf", relativeTo: "/opt/ds4"),
            "/opt/ds4/gguf/model.gguf"
        )
        // Already-absolute and tilde paths are anchored on their own.
        XCTAssertEqual(
            DS4ServerCommand.resolving("/models/model.gguf", relativeTo: "/opt/ds4"),
            "/models/model.gguf"
        )
        XCTAssertEqual(
            DS4ServerCommand.resolving("~/model.gguf", relativeTo: "/opt/ds4"),
            (("~/model.gguf" as NSString).expandingTildeInPath)
        )
        // An unset path must stay empty so callers read it as "not configured"
        // rather than as the server directory itself.
        XCTAssertEqual(DS4ServerCommand.resolving("", relativeTo: "/opt/ds4"), "")
    }

    func testPathNormalizationPreservesConfiguredPathStyle() {
        XCTAssertEqual(
            DS4ServerCommand.normalizingPath("/Volumes///aa/ds4/./ds4-server"),
            "/Volumes/aa/ds4/ds4-server"
        )
        XCTAssertEqual(
            DS4ServerCommand.normalizingPath("gguf///models/../model.gguf"),
            "gguf/model.gguf"
        )
        XCTAssertEqual(DS4ServerCommand.normalizingPath("a/../../b"), "../b")
        XCTAssertEqual(
            DS4ServerCommand.normalizingPath("~/models///model.gguf"),
            "~/models/model.gguf"
        )
        XCTAssertEqual(
            DS4ServerCommand.normalizingPath("  ~/models/model.gguf  "),
            "~/models/model.gguf"
        )
        XCTAssertEqual(
            DS4ServerCommand.normalizingPath("  /Volumes/aa/model.gguf  "),
            "/Volumes/aa/model.gguf"
        )
        XCTAssertEqual(DS4ServerCommand.normalizingPath(""), "")
    }

    func testStoredGGUFPathsArePresentedRelativeToServerDirectory() {
        XCTAssertEqual(
            DS4ServerCommand.presentingResourcePath(
                "/Volumes///aa/ds4/gguf/model.gguf",
                relativeTo: "/Volumes/aa/ds4"
            ),
            "gguf/model.gguf"
        )
        XCTAssertEqual(
            DS4ServerCommand.presentingResourcePath(
                "/Volumes/aa/ds4-models/model.gguf",
                relativeTo: "/Volumes/aa/ds4"
            ),
            "/Volumes/aa/ds4-models/model.gguf"
        )
        XCTAssertEqual(
            DS4ServerCommand.presentingResourcePath(
                "/Volumes/aa/ds4/gguf/model.gguf",
                relativeTo: "/Volumes/aa/other-ds4"
            ),
            "/Volumes/aa/ds4/gguf/model.gguf"
        )
        XCTAssertEqual(
            DS4ServerCommand.presentingResourcePath(
                "gguf///model.gguf",
                relativeTo: "/Volumes/aa/ds4"
            ),
            "gguf/model.gguf"
        )
        let homeModel = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("external/model.gguf").path
        XCTAssertEqual(
            DS4ServerCommand.presentingResourcePath(
                homeModel,
                relativeTo: "/Volumes/aa/ds4"
            ),
            "~/external/model.gguf"
        )
    }

    func testGGUFPathsAreStoredAbsolute() {
        XCTAssertEqual(
            DS4ServerCommand.storingResourcePath(
                "gguf///model.gguf",
                relativeTo: "/Volumes/aa/ds4"
            ),
            "/Volumes/aa/ds4/gguf/model.gguf"
        )
        XCTAssertEqual(
            DS4ServerCommand.storingResourcePath(
                "/models///model.gguf",
                relativeTo: "/Volumes/aa/ds4"
            ),
            "/models/model.gguf"
        )
        XCTAssertEqual(
            DS4ServerCommand.storingResourcePath(
                "  gguf/model.gguf  ",
                relativeTo: "/Volumes/aa/ds4"
            ),
            "/Volumes/aa/ds4/gguf/model.gguf"
        )
    }

    func testServerPathsAreStoredAbsoluteAndPresentedWithTilde() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(
            DS4ServerCommand.storingAbsolutePath("~/ds4/ds4-server"),
            "\(home)/ds4/ds4-server"
        )
        XCTAssertEqual(
            DS4ServerCommand.storingAbsolutePath("  ~/ds4/ds4-server  "),
            "\(home)/ds4/ds4-server"
        )
        XCTAssertEqual(
            DS4ServerCommand.presentingPath("\(home)///ds4/ds4-server"),
            "~/ds4/ds4-server"
        )
        XCTAssertEqual(
            DS4ServerCommand.storingAbsolutePath("bin/ds4-server"),
            (FileManager.default.currentDirectoryPath as NSString)
                .appendingPathComponent("bin/ds4-server")
        )
    }

    /// A log or trace path is a picked folder plus a typed name, and splitting
    /// it has to return exactly what was combined.
    func testCreatedFilePathsSplitIntoFolderAndName() {
        XCTAssertEqual(
            DS4ServerCommand.storingFilePath(
                directory: "~/Library/Logs//dsmenubar/",
                name: "  ds4.log  "
            ),
            "~/Library/Logs/dsmenubar/ds4.log"
        )
        XCTAssertEqual(
            DS4ServerCommand.storingFilePath(directory: "/var/log/ds4", name: "ds4.log"),
            "/var/log/ds4/ds4.log"
        )
        XCTAssertEqual(
            DS4ServerCommand.fileDirectory(of: "~/Library/Logs/dsmenubar/ds4.log"),
            "~/Library/Logs/dsmenubar"
        )
        XCTAssertEqual(
            DS4ServerCommand.fileName(of: "~/Library/Logs/dsmenubar/ds4.log"),
            "ds4.log"
        )

        // An empty name would turn the file path into its own directory.
        XCTAssertEqual(
            DS4ServerCommand.storingFilePath(directory: "/var/log/ds4", name: "   "),
            "/var/log/ds4"
        )
    }

    /// The preview is the app's promise about what it will run, so it has to
    /// resolve relative paths exactly as `ProcessManager.launch` does.
    func testPreviewResolvesRelativePathsLikeTheLaunchPath() {
        var config = ServerConfiguration.Config()
        config.serverPath = "/opt/ds4/ds4-server"
        config.modelPath = "gguf/GLM-5.3-Flash-Q2.gguf"
        config.mtpPath = "gguf/support.gguf"
        config.visionPath = "gguf/vision.gguf"
        config.visionEnabled = true
        config.mtpMode = .external

        let glm = DS4ModelProfile.from(architecture: "glm5-next")
        let preview = DS4ServerCommand.preview(configuration: config, modelProfile: glm)
        XCTAssertTrue(
            preview.contains("--model /opt/ds4/gguf/GLM-5.3-Flash-Q2.gguf"),
            preview
        )
        XCTAssertTrue(preview.contains("--vision /opt/ds4/gguf/vision.gguf"), preview)

        let serverDirectory = DS4ServerCommand.serverDirectory(for: config.serverPath)
        XCTAssertEqual(serverDirectory, "/opt/ds4")

        let deepSeek = DS4ModelProfile.from(architecture: "deepseek4")
        let launchArgs = DS4ServerCommand.arguments(
            configuration: config,
            resolvedModelPath: DS4ServerCommand.resolving(config.modelPath, relativeTo: serverDirectory),
            resolvedMTPPath: DS4ServerCommand.resolving(config.mtpPath, relativeTo: serverDirectory),
            resolvedVisionPath: DS4ServerCommand.resolving(config.visionPath, relativeTo: serverDirectory),
            modelProfile: deepSeek,
            supportProfile: DS4SupportProfile(kind: .legacyMTP, architecture: nil)
        )
        XCTAssertTrue(launchArgs.contains("/opt/ds4/gguf/support.gguf"), "\(launchArgs)")

        let deepSeekPreview = DS4ServerCommand.preview(
            configuration: config,
            modelProfile: deepSeek,
            supportProfile: DS4SupportProfile(kind: .legacyMTP, architecture: nil)
        )
        XCTAssertTrue(
            deepSeekPreview.contains("--mtp-model /opt/ds4/gguf/support.gguf"),
            deepSeekPreview
        )
    }

    func testSimulatedMemorySyntax() {
        XCTAssertTrue(ServerConfiguration.Config.isValidMemoryBudget("8"))
        XCTAssertTrue(ServerConfiguration.Config.isValidMemoryBudget("40GB"))
        XCTAssertTrue(ServerConfiguration.Config.isValidMemoryBudget(" 40gb "))
        XCTAssertFalse(ServerConfiguration.Config.isValidMemoryBudget("0"))
        XCTAssertFalse(ServerConfiguration.Config.isValidMemoryBudget("40MB"))
        XCTAssertFalse(ServerConfiguration.Config.isValidMemoryBudget("GB"))
    }

    func testHealthProbeURLHostMapsWildcardBindAddressesToLoopback() {
        // Wildcards are not connectable through URLSession; probe loopback.
        XCTAssertEqual(DS4ServerCommand.healthProbeURLHost(for: "0.0.0.0"), "127.0.0.1")
        // One address, many spellings. The mapping parses rather than matches,
        // so every way of writing the IPv6 wildcard lands on loopback — not
        // just the two ds4-server happens to document.
        for wildcard in ["::", "[::]", "::0", "[::0]", "0:0:0:0:0:0:0:0", "[0000::0]"] {
            XCTAssertEqual(DS4ServerCommand.healthProbeURLHost(for: wildcard), "[::1]", wildcard)
        }
        // The same wildcard wearing an IPv4-mapped prefix resolves to the IPv4
        // loopback, which is what such a listener actually accepts.
        XCTAssertEqual(
            DS4ServerCommand.healthProbeURLHost(for: "[::ffff:0.0.0.0]"), "127.0.0.1")
        XCTAssertEqual(DS4ServerCommand.healthProbeURLHost(for: "::ffff:0:0"), "127.0.0.1")
        // Everything else is a real destination and must pass through: a
        // specific LAN address or hostname is how the user scoped the server.
        XCTAssertEqual(DS4ServerCommand.healthProbeURLHost(for: "127.0.0.1"), "127.0.0.1")
        XCTAssertEqual(DS4ServerCommand.healthProbeURLHost(for: "localhost"), "localhost")
        XCTAssertEqual(DS4ServerCommand.healthProbeURLHost(for: "192.168.1.10"), "192.168.1.10")
        // A specific IPv6 address comes back bracketed whichever way it went
        // in: the result is a URL host component, and URLComponents rejects
        // the bare form.
        XCTAssertEqual(DS4ServerCommand.healthProbeURLHost(for: "::1"), "[::1]")
        XCTAssertEqual(DS4ServerCommand.healthProbeURLHost(for: "[::1]"), "[::1]")
        XCTAssertEqual(DS4ServerCommand.healthProbeURLHost(for: "[fe80::1]"), "[fe80::1]")
        // inet_pton parses a scope ID, so a link-local address stays on the
        // address path and comes back bracketed; URLComponents then encodes
        // the zone per RFC 6874 (%en0 → %25en0) and builds a usable URL.
        XCTAssertEqual(
            DS4ServerCommand.healthProbeURLHost(for: "[fe80::1%en0]"), "[fe80::1%en0]")
        XCTAssertEqual(
            DS4ServerCommand.healthProbeURLHost(for: "fe80::1%en0"), "[fe80::1%en0]")
        // A name is returned in the same single spelling, brackets removed —
        // CFNetwork resolves "[localhost]", but the probe and --host must not
        // disagree about what the host is called.
        XCTAssertEqual(DS4ServerCommand.healthProbeURLHost(for: "[localhost]"), "localhost")
    }

    /// Brackets are URL syntax, not part of an address, and getaddrinfo
    /// rejects them. Stripping them once keeps the bind, the pre-relaunch port
    /// wait, and --host all looking at the same host.
    func testNormalizedHostStripsURLBrackets() {
        XCTAssertEqual(DS4ServerCommand.normalizedHost("[::]"), "::")
        XCTAssertEqual(DS4ServerCommand.normalizedHost("[::1]"), "::1")
        // Brackets are stripped by shape, not by what they wrap: nothing here
        // validates that the contents are an IPv6 address.
        XCTAssertEqual(DS4ServerCommand.normalizedHost("[localhost]"), "localhost")
        XCTAssertEqual(DS4ServerCommand.normalizedHost("0.0.0.0"), "0.0.0.0")
        XCTAssertEqual(DS4ServerCommand.normalizedHost("localhost"), "localhost")
        // Nothing to unwrap: leave malformed input exactly as typed so launch
        // reports the host the user actually entered.
        XCTAssertEqual(DS4ServerCommand.normalizedHost("[]"), "[]")
        XCTAssertEqual(DS4ServerCommand.normalizedHost("["), "[")
        XCTAssertEqual(DS4ServerCommand.normalizedHost("[::"), "[::")
    }

    /// The probe remap must never reach the server: --host is what exposes
    /// ds4-server beyond loopback, so a loopback value there would silently
    /// undo the access the user configured. The configured host passes through
    /// untouched apart from URL brackets, which a bind cannot take.
    func testConfiguredHostReachesTheServerWithOnlyBracketsStripped() {
        let expected = [
            ("0.0.0.0", "0.0.0.0"),
            ("::", "::"),
            ("[::]", "::"),
            ("[::1]", "::1"),
            ("192.168.1.10", "192.168.1.10"),
            ("localhost", "localhost")
        ]

        for (configured, sent) in expected {
            var config = ServerConfiguration.Config()
            config.host = configured
            let args = DS4ServerCommand.arguments(
                configuration: config,
                resolvedModelPath: "/tmp/model.gguf",
                resolvedMTPPath: "/tmp/mtp.gguf"
            )

            guard let flag = args.firstIndex(of: "--host") else {
                XCTFail("--host missing for \(configured)")
                continue
            }
            XCTAssertEqual(args[args.index(after: flag)], sent, configured)
        }
    }
}
