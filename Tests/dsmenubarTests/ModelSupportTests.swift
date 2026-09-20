// SPDX-FileCopyrightText: Copyright James Martin and DS Menu Bar contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest

@testable import dsmenubar

final class ModelSupportTests: XCTestCase {
    func testMTPModeTitlesUseUserFacingNames() {
        XCTAssertEqual(MTPMode.off.title, "Off")
        XCTAssertEqual(MTPMode.dspark.title, "DSpark")
        XCTAssertEqual(MTPMode.external.title, "Legacy MTP")
    }

    func testGGUFArchitectureMapsToModelFamily() throws {
        XCTAssertEqual(try inspect(architecture: "glm5-next").family, .glm53Flash)
        XCTAssertEqual(try inspect(architecture: "glm-dsa").family, .glm5Full)
        let deepSeekV4 = try inspect(architecture: "deepseek4")
        XCTAssertEqual(deepSeekV4.family, .deepSeek)
        XCTAssertEqual(deepSeekV4.displayName, "DeepSeek V4")
        XCTAssertTrue(try inspect(architecture: "deepseek4_mtp_support").isSupportArtifact)
        XCTAssertTrue(try inspect(architecture: "deepseek4-dspark").isSupportArtifact)
        XCTAssertTrue(try inspect(architecture: "glm5-next-vision").isSupportArtifact)
        XCTAssertEqual(try inspect(architecture: "qwen3-next").family, .unknown)
    }

    func testNewArchitecturesAndAuxiliaryFilesAreRecognized() throws {
        XCTAssertEqual(try inspect(architecture: "deepseek41").family, .deepSeek41)
        XCTAssertEqual(try inspect(architecture: "qwen4exp").family, .qwen38)
        XCTAssertTrue(try inspect(architecture: "deepseek4-vision").isSupportArtifact)
        XCTAssertTrue(try inspect(architecture: "qwen4-exp-ple").isSupportArtifact)
        XCTAssertTrue(try inspect(architecture: "clip").isSupportArtifact)
    }

    func testFullGLMVersionAndStreamingBoundsComeFromMetadata() throws {
        let url = temporaryURL()
        try makeGGUF(
            architecture: "glm-dsa",
            stringMetadata: ["general.version": "5.3", "general.name": "GLM-5.3"],
            uint32Metadata: [
                "glm-dsa.context_length": 1_048_576,
                "glm-dsa.block_count": 79,
                "glm-dsa.leading_dense_block_count": 3,
                "glm-dsa.expert_count": 256,
                "glm-dsa.nextn_predict_layers": 1
            ]
        ).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let profile = try GGUFModelInspector.profile(at: url.path)
        XCTAssertEqual(profile.family, .glm53Full)
        XCTAssertEqual(profile.displayName, "GLM 5.3 (full)")
        XCTAssertEqual(profile.contextLength, 1_048_576)
        XCTAssertEqual(profile.eligibleStreamingLayerCount, 75)
        XCTAssertEqual(profile.cacheableExpertCount, 19_200)
        XCTAssertTrue(profile.supportsEmbeddedMTP)
    }

    func testFullGLM52IsDistinguishedFromFullGLM53() throws {
        let url = temporaryURL()
        try makeGGUF(
            architecture: "glm-dsa",
            stringMetadata: ["general.version": "5.2", "general.basename": "GLM-5.2"],
            uint32Metadata: ["glm-dsa.nextn_predict_layers": 0]
        ).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let profile = try GGUFModelInspector.profile(at: url.path)
        XCTAssertEqual(profile.family, .glm52)
        XCTAssertEqual(profile.displayName, "GLM 5.2 (full)")
        XCTAssertFalse(profile.supportsEmbeddedMTP)
    }

    /// ds4-server batches sessions and MTP together only for Qwen with real
    /// nextn weights; both halves of that gate are load-bearing.
    func testOnlyQwenWithEmbeddedMTPWeightsSupportsBatchedMTP() {
        let qwen = DS4ModelProfile(family: .qwen38, architecture: "qwen4exp", nextnPredictLayers: 1)
        XCTAssertTrue(qwen.supportsBatchedEmbeddedMTP)

        for withoutNextn in [
            DS4ModelProfile(family: .qwen38, architecture: "qwen4exp", nextnPredictLayers: 0),
            DS4ModelProfile.from(architecture: "qwen4exp")
        ] {
            XCTAssertFalse(withoutNextn.supportsBatchedEmbeddedMTP,
                           String(describing: withoutNextn.nextnPredictLayers))
        }

        for architecture in ["glm5-next", "glm-dsa", "deepseek4", "deepseek41"] {
            let profile = DS4ModelProfile(
                family: DS4ModelProfile.from(architecture: architecture).family,
                architecture: architecture,
                nextnPredictLayers: 1
            )
            XCTAssertFalse(profile.supportsBatchedEmbeddedMTP, architecture)
        }
    }

    func testQwenVisionCompatibilityUsesMainMetadata() throws {
        let model = DS4ModelProfile(
            family: .qwen38,
            architecture: "qwen4exp",
            nextnPredictLayers: 1,
            embeddingLength: 4_096
        )
        let visionURL = temporaryURL()
        try makeGGUF(
            architecture: "clip",
            stringMetadata: ["clip.projector_type": "qwen3vl_merger"],
            uint32Metadata: ["clip.vision.projection_dim": 4_096]
        ).write(to: visionURL)
        defer { try? FileManager.default.removeItem(at: visionURL) }
        let vision = GGUFModelInspector.visionProfile(for: visionURL.path, relativeTo: nil)
        XCTAssertTrue(vision.isCompatible(with: model))
    }

    func testQwenRejectsMissingQuantizedAndWrongShapeNGrams() throws {
        let cases: [([UInt64]?, UInt32)] = [
            (nil, 30),
            ([256, 10_000], 0),
            ([256], 30),
            ([255, 10_000], 30),
            ([256, 9_999], 30)
        ]
        for (dimensions, tensorType) in cases {
            let url = temporaryURL()
            try makeGGUF(
                architecture: "qwen4exp",
                uint32Metadata: [
                    "qwen4exp.ple.row_count": 10_000,
                    "qwen4exp.embedding_length_per_layer_input": 256
                ],
                tensorDimensions: dimensions.map { ["per_layer_token_embd.weight": $0] } ?? [:],
                tensorTypes: ["per_layer_token_embd.weight": tensorType]
            ).write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            let profile = try GGUFModelInspector.profile(at: url.path)
            XCTAssertEqual(profile.hasNativeQwenNGrams, false, "dimensions \(String(describing: dimensions)), type \(tensorType)")
        }
    }

    func testQwenMainGGUFExposesContextMTPAndNativeNGrams() throws {
        let url = temporaryURL()
        try makeGGUF(
            architecture: "qwen4exp",
            uint32Metadata: [
                "qwen4exp.context_length": 262_144,
                "qwen4exp.embedding_length": 4_096,
                "qwen4exp.nextn_predict_layers": 1,
                "qwen4exp.ple.row_count": 10_000,
                "qwen4exp.embedding_length_per_layer_input": 256
            ],
            tensorDimensions: ["per_layer_token_embd.weight": [256, 10_000]],
            tensorTypes: ["per_layer_token_embd.weight": 30]
        ).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let profile = try GGUFModelInspector.profile(at: url.path)
        XCTAssertEqual(profile.family, .qwen38)
        XCTAssertEqual(profile.contextLength, 262_144)
        XCTAssertTrue(profile.supportsEmbeddedMTP)
        XCTAssertEqual(profile.hasNativeQwenNGrams, true)
        XCTAssertEqual(profile.qwenNGramRowCount, 10_000)
        XCTAssertEqual(profile.qwenNGramRowDimension, 256)
    }

    func testDeepSeek41MainGGUFDetectsCompleteVisualRouterInventory() throws {
        let url = temporaryURL()
        let biases = (0..<40).map { "blk.\($0).exp_probs_b_vl.bias" }
        try makeGGUF(
            architecture: "deepseek41",
            tensorNames: biases,
            uint32Metadata: [
                "deepseek41.context_length": 1_048_576,
                "deepseek41.block_count": 40
            ]
        ).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let profile = try GGUFModelInspector.profile(at: url.path)
        XCTAssertEqual(profile.family, .deepSeek41)
        XCTAssertTrue(profile.hasVisualRouterBiases)
    }

    func testDeepSeek41VisualRouterInventoryRequiresEveryLayer() throws {
        let url = temporaryURL()
        let biases = (1...40).map { "blk.\($0).exp_probs_b_vl.bias" }
        try makeGGUF(
            architecture: "deepseek41",
            tensorNames: biases,
            uint32Metadata: ["deepseek41.block_count": 40]
        ).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertFalse(try GGUFModelInspector.profile(at: url.path).hasVisualRouterBiases)
    }

    func testDeepSeek41VisionRequiresPinnedSidecarMetadata() throws {
        let visionURL = temporaryURL()
        try makeGGUF(
            architecture: "deepseek4-vision",
            stringMetadata: [
                "deepseek4-vision.checkpoint_variant": "v4.1-flash",
                "general.source.revision": "df42c109f1defefcbfcedbe7d905718a12266e40"
            ]
        ).write(to: visionURL)
        defer { try? FileManager.default.removeItem(at: visionURL) }
        let profile = GGUFModelInspector.visionProfile(for: visionURL.path, relativeTo: nil)
        XCTAssertEqual(profile.kind, .deepSeek41)
    }

    func testAuxiliaryGGUFsAreRejectedAsMainModels() throws {
        for architecture in ["deepseek4_mtp_support", "deepseek4-dspark", "glm5-next-vision"] {
            var config = ServerConfiguration.Config()
            let profile = try inspect(architecture: architecture)
            let errors = config.validationErrors(modelProfile: profile)
            XCTAssertEqual(
                errors[.modelPath],
                "This is a \(profile.displayName), not a main model. Choose a main model GGUF instead."
            )
            config.modelPath = "/tmp/\(architecture).gguf"
            XCTAssertFalse(config.validationErrors(modelProfile: profile).isEmpty, architecture)
        }
    }

    func testInvalidGGUFIsUnknown() throws {
        let url = temporaryURL()
        try Data([0, 1, 2, 3]).write(to: url)
        XCTAssertEqual(GGUFModelInspector.profile(for: url.path), .unknown)
        try? FileManager.default.removeItem(at: url)
    }

    func testExternalSupportGGUFTypesAreDistinguished() throws {
        let legacyURL = temporaryURL()
        try makeGGUF(
            architecture: "deepseek4_mtp_support",
            tensorNames: [
                "mtp.0.e_proj.weight",
                "mtp.0.h_proj.weight",
                "mtp.0.hc_head_base.weight"
            ]
        ).write(to: legacyURL)
        defer { try? FileManager.default.removeItem(at: legacyURL) }

        let dsparkURL = temporaryURL()
        try makeGGUF(
            architecture: "deepseek4-dspark",
            tensorNames: [
                "mtp.0.main_proj.weight",
                "mtp.0.block.weight",
                "mtp.1.block.weight",
                "mtp.2.block.weight",
                "mtp.2.markov_head.markov_w1.weight",
                "mtp.2.confidence_head.proj.weight"
            ]
        ).write(to: dsparkURL)
        defer { try? FileManager.default.removeItem(at: dsparkURL) }

        XCTAssertEqual(try GGUFModelInspector.supportProfile(at: legacyURL.path).kind, .legacyMTP)
        XCTAssertEqual(try GGUFModelInspector.supportProfile(at: dsparkURL.path).kind, .dspark)
    }

    func testSupportModesRejectTheOtherSupportGGUFType() throws {
        let legacy = DS4SupportProfile(kind: .legacyMTP, architecture: "deepseek4_mtp_support")
        let dspark = DS4SupportProfile(kind: .dspark, architecture: "deepseek4-dspark")
        let deepSeek = DS4ModelProfile.from(architecture: "deepseek4")

        var config = ServerConfiguration.Config()
        config.mtpMode = .external
        XCTAssertNil(config.validationErrors(modelProfile: deepSeek, supportProfile: legacy)[.mtpPath])
        XCTAssertEqual(
            config.validationErrors(modelProfile: deepSeek, supportProfile: dspark)[.mtpPath],
            "This is a DSpark support GGUF. Select DSpark mode, or choose a legacy MTP support GGUF for Legacy MTP."
        )

        config.mtpMode = .dspark
        XCTAssertNil(config.validationErrors(modelProfile: deepSeek, supportProfile: dspark)[.mtpPath])
        XCTAssertEqual(
            config.validationErrors(modelProfile: deepSeek, supportProfile: legacy)[.mtpPath],
            "This is a legacy MTP support GGUF. Choose a DSpark support GGUF, or select Legacy MTP mode to use this file."
        )
    }

    func testCommandDoesNotEmitFlagsForAMismatchedSupportType() {
        var config = ServerConfiguration.Config()
        config.mtpMode = .dspark
        let args = DS4ServerCommand.arguments(
            configuration: config,
            resolvedModelPath: "/tmp/deepseek.gguf",
            resolvedMTPPath: "/tmp/legacy.gguf",
            modelProfile: .from(architecture: "deepseek4"),
            supportProfile: DS4SupportProfile(kind: .legacyMTP, architecture: "deepseek4_mtp_support")
        )
        XCTAssertFalse(args.contains("--mtp-model"))
        XCTAssertFalse(args.contains("--dspark"))
    }

    func testModelSwitchRestoresIndependentTuningProfiles() {
        let deepSeek = DS4ModelProfile.from(architecture: "deepseek4")
        let glm = DS4ModelProfile(
            family: .glm53Flash,
            architecture: "glm5-next",
            nextnPredictLayers: 1
        )
        var config = ServerConfiguration.Config(modelPath: "/tmp/deepseek.gguf")
        config.mtpMode = .external
        config.mtpDraft = 8
        config.mtpPath = "/tmp/deepseek-mtp.gguf"

        config = config.selectingModel(path: "/tmp/glm.gguf", profile: glm)
        XCTAssertEqual(config.mtpMode, .off)
        config.mtpMode = .embedded
        config.mtpTiming = true

        config = config.selectingModel(path: "/tmp/deepseek.gguf", profile: deepSeek)
        XCTAssertEqual(config.mtpMode, .external)
        XCTAssertEqual(config.mtpDraft, 8)
        XCTAssertEqual(config.mtpPath, "/tmp/deepseek-mtp.gguf")

        config = config.selectingModel(path: "/tmp/glm.gguf", profile: glm)
        XCTAssertEqual(config.mtpMode, .embedded)
        XCTAssertTrue(config.mtpTiming)
    }

    func testSelectingModelRepairsIncompatiblePersistedMTPMode() {
        let deepSeek = DS4ModelProfile.from(architecture: "deepseek4")
        let glm = DS4ModelProfile.from(architecture: "glm5-next")
        var config = ServerConfiguration.Config(modelPath: "/tmp/deepseek.gguf")
        config.mtpMode = .external
        config.modelProfiles[ServerConfiguration.Config.modelKey(
            for: "/tmp/glm.gguf",
            serverPath: config.serverPath
        )] =
            DS4TuningProfile(configuration: config)

        let selectedGLM = config.selectingModel(path: "/tmp/glm.gguf", profile: glm)
        XCTAssertEqual(selectedGLM.mtpMode, .off)

        var glmConfig = selectedGLM
        glmConfig.mtpMode = .embedded
        glmConfig.modelProfiles[ServerConfiguration.Config.modelKey(
            for: "/tmp/deepseek.gguf",
            serverPath: glmConfig.serverPath
        )] =
            DS4TuningProfile(configuration: glmConfig)
        let selectedDeepSeek = glmConfig.selectingModel(path: "/tmp/deepseek.gguf", profile: deepSeek)
        XCTAssertEqual(selectedDeepSeek.mtpMode, .off)
    }

    func testRestoreTuningDefaultsOnlyResetsActiveModelProfile() {
        let deepSeek = DS4ModelProfile.from(architecture: "deepseek4")
        var config = ServerConfiguration.Config(modelPath: "/tmp/deepseek.gguf")
        config.mtpMode = .external
        config.mtpDraft = 8
        config.mtpPath = "/tmp/deepseek-mtp.gguf"
        config = config.selectingModel(path: "/tmp/glm.gguf", profile: DS4ModelProfile.from(architecture: "glm5-next"))
        config.mtpMode = .embedded
        config.mtpTiming = true

        let restored = config.restoringTuningDefaults(for: DS4ModelProfile.from(architecture: "glm5-next"))
        XCTAssertEqual(restored.mtpMode, .off)

        let back = restored.selectingModel(path: "/tmp/deepseek.gguf", profile: deepSeek)
        XCTAssertEqual(back.mtpMode, .external)
        XCTAssertEqual(back.mtpDraft, 8)
    }

    func testRelativeModelKeysUseTheServerDirectory() {
        let first = ServerConfiguration.Config.modelKey(
            for: "gguf/model.gguf",
            serverPath: "/opt/ds4-a/ds4-server"
        )
        let second = ServerConfiguration.Config.modelKey(
            for: "gguf/model.gguf",
            serverPath: "/opt/ds4-b/ds4-server"
        )

        XCTAssertEqual(first, "/opt/ds4-a/gguf/model.gguf")
        XCTAssertEqual(second, "/opt/ds4-b/gguf/model.gguf")
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(
            ServerConfiguration.Config.modelKey(
                for: "/models/model.gguf",
                serverPath: "/opt/ds4-a/ds4-server"
            ),
            "/models/model.gguf"
        )
    }

    func testLegacyRelativeProfileIsCopiedToTheCanonicalKey() {
        let relativePath = "legacy/model.gguf"
        let legacyKey = URL(fileURLWithPath: relativePath).standardizedFileURL.path
        var saved = DS4TuningProfile()
        saved.ctxSize = 222_222
        saved.mtpMode = .external

        var config = ServerConfiguration.Config(
            serverPath: "/opt/ds4/ds4-server",
            modelPath: "current.gguf"
        )
        config.modelProfiles[legacyKey] = saved

        let selected = config.selectingModel(
            path: relativePath,
            profile: .from(architecture: "deepseek4")
        )
        let canonicalKey = ServerConfiguration.Config.modelKey(
            for: relativePath,
            serverPath: config.serverPath
        )

        XCTAssertEqual(selected.ctxSize, saved.ctxSize)
        XCTAssertEqual(selected.mtpMode, .external)
        XCTAssertEqual(selected.modelProfiles[canonicalKey], DS4TuningProfile(configuration: selected))
        XCTAssertEqual(selected.modelProfiles[legacyKey], saved)
    }

    func testExplicitLoadedKeyPreventsRevertFromOverwritingAnotherProfile() {
        let serverPath = "/opt/ds4/ds4-server"
        let keyA = ServerConfiguration.Config.modelKey(
            for: "a.gguf",
            serverPath: serverPath
        )
        let keyB = ServerConfiguration.Config.modelKey(
            for: "b.gguf",
            serverPath: serverPath
        )
        var profileA = DS4TuningProfile()
        profileA.ctxSize = 111_111
        var profileB = DS4TuningProfile()
        profileB.ctxSize = 222_222

        var reverted = ServerConfiguration.Config(
            serverPath: serverPath,
            modelPath: "a.gguf",
            ctxSize: profileA.ctxSize
        )
        reverted.modelProfiles[keyA] = profileA
        reverted.modelProfiles[keyB] = profileB

        let selectedB = reverted.selectingModel(
            path: "b.gguf",
            profile: .from(architecture: "deepseek4"),
            storingCurrentAs: keyA
        )

        XCTAssertEqual(selectedB.ctxSize, profileB.ctxSize)
        XCTAssertEqual(selectedB.modelProfiles[keyA]?.ctxSize, profileA.ctxSize)
        XCTAssertEqual(selectedB.modelProfiles[keyB]?.ctxSize, profileB.ctxSize)
    }

    func testChangingServerDirectorySwitchesRelativeModelProfile() {
        let firstServer = "/opt/ds4-a/ds4-server"
        let secondServer = "/opt/ds4-b/ds4-server"
        let path = "model.gguf"
        let firstKey = ServerConfiguration.Config.modelKey(for: path, serverPath: firstServer)
        let secondKey = ServerConfiguration.Config.modelKey(for: path, serverPath: secondServer)
        var firstProfile = DS4TuningProfile()
        firstProfile.ctxSize = 111_111
        var secondProfile = DS4TuningProfile()
        secondProfile.ctxSize = 222_222

        var config = ServerConfiguration.Config(
            serverPath: firstServer,
            modelPath: path,
            ctxSize: firstProfile.ctxSize
        )
        config.modelProfiles[firstKey] = firstProfile
        config.modelProfiles[secondKey] = secondProfile

        let selected = config.selectingModel(
            path: path,
            serverPath: secondServer,
            profile: .from(architecture: "deepseek4"),
            storingCurrentAs: firstKey
        )

        XCTAssertEqual(selected.serverPath, secondServer)
        XCTAssertEqual(selected.ctxSize, secondProfile.ctxSize)
        XCTAssertEqual(selected.modelProfiles[firstKey]?.ctxSize, firstProfile.ctxSize)
    }

    func testEmbeddedAndUnknownCommandsDoNotUseExternalMTPShape() {
        var config = ServerConfiguration.Config()
        config.mtpMode = .embedded
        config.mtpTiming = true
        config.mtpExactSampling = true
        config.visionPath = "/tmp/vision.gguf"
        config.visionEnabled = true

        let glmArgs = DS4ServerCommand.arguments(
            configuration: config,
            resolvedModelPath: "/tmp/glm.gguf",
            resolvedMTPPath: "/tmp/should-not-appear.gguf",
            resolvedVisionPath: "/tmp/vision.gguf",
            modelProfile: DS4ModelProfile(
                family: .glm53Flash,
                architecture: "glm5-next",
                nextnPredictLayers: 1
            )
        )
        XCTAssertTrue(glmArgs.contains("--mtp"))
        XCTAssertTrue(glmArgs.contains("--mtp-timing"))
        XCTAssertTrue(glmArgs.contains("--mtp-exact-sampling"))
        XCTAssertTrue(glmArgs.contains("--vision"))
        XCTAssertFalse(glmArgs.contains("--mtp-model"))
        XCTAssertFalse(glmArgs.contains("/tmp/should-not-appear.gguf"))

        let unknownArgs = DS4ServerCommand.arguments(
            configuration: config,
            resolvedModelPath: "/tmp/unknown.gguf",
            resolvedMTPPath: "/tmp/should-not-appear.gguf",
            modelProfile: .unknown
        )
        XCTAssertFalse(unknownArgs.contains("--mtp"))
        XCTAssertFalse(unknownArgs.contains("--vision"))
    }

    func testQwenWithEmbeddedWeightsDefaultsToAutomaticMTP() {
        let qwen = DS4ModelProfile(
            family: .qwen38,
            architecture: "qwen4exp",
            contextLength: 262_144,
            nextnPredictLayers: 2
        )

        let selected = ServerConfiguration.Config()
            .selectingModel(path: "/tmp/qwen.gguf", profile: qwen)

        XCTAssertEqual(selected.mtpMode, .embedded)
        XCTAssertEqual(selected.qwenMTPDepth, .automatic)

        var customized = selected
        customized.mtpMode = .off
        customized.qwenMTPDepth = .twoDrafts
        let restored = customized.restoringTuningDefaults(for: qwen)
        XCTAssertEqual(restored.mtpMode, .embedded)
        XCTAssertEqual(restored.qwenMTPDepth, .automatic)

        let withoutEmbeddedWeights = DS4ModelProfile(
            family: .qwen38,
            architecture: "qwen4exp",
            contextLength: 262_144
        )
        let unsupported = ServerConfiguration.Config()
            .selectingModel(path: "/tmp/qwen-without-mtp.gguf", profile: withoutEmbeddedWeights)
        XCTAssertEqual(unsupported.mtpMode, .off)
    }

    func testDSparkCommandUsesOnlyDSparkOptions() {
        var config = ServerConfiguration.Config()
        config.mtpMode = .dspark
        config.mtpDraft = 8
        config.mtpMargin = 4
        config.dsparkConfidence = 0.7
        config.mtpExactSampling = true
        config.dsparkStrict = true

        let args = DS4ServerCommand.arguments(
            configuration: config,
            resolvedModelPath: "/tmp/deepseek.gguf",
            resolvedMTPPath: "/tmp/dspark.gguf",
            modelProfile: .from(architecture: "deepseek4"),
            supportProfile: DS4SupportProfile(kind: .dspark, architecture: "deepseek4-dspark")
        )
        XCTAssertTrue(args.contains("--mtp-model"))
        XCTAssertTrue(args.contains("--dspark"))
        XCTAssertTrue(args.contains("--dspark-confidence"))
        XCTAssertTrue(args.contains("0.7"))
        XCTAssertTrue(args.contains("--mtp-exact-sampling"))
        XCTAssertTrue(args.contains("--dspark-strict"))
        XCTAssertFalse(args.contains("--mtp-draft"))
        XCTAssertFalse(args.contains("--mtp-margin"))
    }

    func testAutomaticDSparkConfidenceOmitsAnOverride() {
        var config = ServerConfiguration.Config()
        config.mtpMode = .dspark
        config.dsparkConfidence = nil

        let args = DS4ServerCommand.arguments(
            configuration: config,
            resolvedModelPath: "/tmp/deepseek.gguf",
            resolvedMTPPath: "/tmp/dspark.gguf",
            modelProfile: .from(architecture: "deepseek4"),
            supportProfile: DS4SupportProfile(
                kind: .dspark,
                architecture: "deepseek4-dspark"
            )
        )

        XCTAssertFalse(args.contains("--dspark-confidence"))
    }

    func testVisionArchitectureIsRecognizedSeparately() throws {
        let url = temporaryURL()
        try makeGGUF(architecture: " GLM5-NEXT-VISION ").write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(GGUFModelInspector.isGLM53VisionEncoder(at: url.path))
    }

    func testVisionPathValidationRejectsNonVisionGGUFs() throws {
        let nonVisionURL = temporaryURL()
        try makeGGUF(architecture: "deepseek4").write(to: nonVisionURL)
        defer { try? FileManager.default.removeItem(at: nonVisionURL) }

        let visionURL = temporaryURL()
        try makeGGUF(architecture: "glm5-next-vision").write(to: visionURL)
        defer { try? FileManager.default.removeItem(at: visionURL) }

        let glm = DS4ModelProfile.from(architecture: "glm5-next")
        var config = ServerConfiguration.Config(visionPath: nonVisionURL.path)
        config.visionEnabled = true
        let invalid = GGUFModelInspector.visionPathIsValid(for: config.visionPath, relativeTo: nil)
        XCTAssertEqual(invalid, false)
        XCTAssertEqual(
            config.validationErrors(modelProfile: glm, visionPathIsValid: invalid)[.visionPath],
            "Choose a compatible GLM 5.3 Flash vision GGUF"
        )

        config.visionPath = visionURL.path
        let valid = GGUFModelInspector.visionPathIsValid(for: config.visionPath, relativeTo: nil)
        XCTAssertEqual(valid, true)
        XCTAssertNil(config.validationErrors(modelProfile: glm, visionPathIsValid: valid)[.visionPath])
    }

    func testEnabledVisionRequiresAPathForSupportedFamilies() {
        var config = ServerConfiguration.Config()
        config.visionEnabled = true

        let glm = DS4ModelProfile.from(architecture: "glm5-next")
        XCTAssertEqual(
            config.validationErrors(modelProfile: glm)[.visionPath],
            "Choose a compatible GLM 5.3 Flash vision GGUF"
        )

        let deepSeek = DS4ModelProfile(
            family: .deepSeek41,
            architecture: "deepseek41",
            hasVisualRouterBiases: true
        )
        XCTAssertEqual(
            config.validationErrors(modelProfile: deepSeek)[.visionPath],
            "Choose a compatible DeepSeek V4.1 Flash vision GGUF"
        )
    }

    func testDisabledVisionRetainsPathWithoutCommandOrValidationError() throws {
        let nonVisionURL = temporaryURL()
        try makeGGUF(architecture: "deepseek4").write(to: nonVisionURL)
        defer { try? FileManager.default.removeItem(at: nonVisionURL) }

        let glm = DS4ModelProfile.from(architecture: "glm5-next")
        let config = ServerConfiguration.Config(visionPath: nonVisionURL.path)
        let errors = config.validationErrors(
            modelProfile: glm,
            visionPathIsValid: false
        )
        XCTAssertNil(errors[.visionPath])

        let args = DS4ServerCommand.arguments(
            configuration: config,
            resolvedModelPath: "/tmp/glm.gguf",
            resolvedMTPPath: "",
            resolvedVisionPath: nonVisionURL.path,
            modelProfile: glm
        )
        XCTAssertFalse(args.contains("--vision"))
        XCTAssertEqual(config.visionPath, nonVisionURL.path)
        XCTAssertFalse(config.visionEnabled)
    }

    /// An unset path must never resolve to the server directory. `isReadableFile`
    /// returns true for a directory, so without an empty check an absent support
    /// model reports as `.unrecognized` — an unusable GGUF — instead of `.unavailable`.
    func testUnsetPathsAreAbsentRatherThanUnrecognized() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsmenubar-unset-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertTrue(FileManager.default.isReadableFile(atPath: directory.path))

        for unset in ["", "   "] {
            XCTAssertEqual(
                GGUFModelInspector.supportProfile(for: unset, relativeTo: directory.path),
                .unavailable
            )
            XCTAssertEqual(
                GGUFModelInspector.profile(for: unset, relativeTo: directory.path),
                .unknown
            )
            XCTAssertNil(
                GGUFModelInspector.visionPathIsValid(for: unset, relativeTo: directory.path)
            )
        }
    }

    /// Inspection must resolve relative paths against the server directory the
    /// same way the launch arguments do, or Settings would validate a different
    /// file than the one ds4-server opens.
    func testRelativePathsAreInspectedAgainstTheServerDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsmenubar-relative-\(UUID().uuidString)")
        let nested = directory.appendingPathComponent("gguf")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try makeGGUF(architecture: "glm5-next")
            .write(to: nested.appendingPathComponent("model.gguf"))
        try makeGGUF(architecture: "glm5-next-vision")
            .write(to: nested.appendingPathComponent("vision.gguf"))

        XCTAssertEqual(
            GGUFModelInspector.profile(for: "gguf/model.gguf", relativeTo: directory.path).family,
            .glm53Flash
        )
        XCTAssertEqual(
            GGUFModelInspector.visionPathIsValid(for: "gguf/vision.gguf", relativeTo: directory.path),
            true
        )
        // Without a directory a relative path stays relative and resolves nowhere.
        XCTAssertEqual(
            GGUFModelInspector.profile(for: "gguf/model.gguf", relativeTo: nil).family,
            .unknown
        )
    }

    func testModelInspectionFollowsFileSymlink() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsmenubar-model-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let model = directory.appendingPathComponent("model.gguf")
        try makeGGUF(architecture: "glm5-next").write(to: model)
        let link = directory.appendingPathComponent("current.gguf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: model)

        XCTAssertEqual(GGUFModelInspector.profile(for: link.path).family, .glm53Flash)
    }

    func testInitialSetupRequiresExecutableAndMainGGUF() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsmenubar-setup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let server = directory.appendingPathComponent("renamed-server")
        try Data(
            "#!/bin/sh\nprintf 'Usage: ds4-server with future syntax\\n'\n".utf8
        ).write(to: server)
        XCTAssertNotNil(DS4SelectionValidation.serverError(for: server.path))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: server.path
        )
        XCTAssertNil(DS4SelectionValidation.serverError(for: server.path))

        let otherExecutable = directory.appendingPathComponent("ds4-bench")
        try Data(
            "#!/bin/sh\nprintf 'ds4-bench\\nUsage: ds4-bench [options]\\n'\n".utf8
        ).write(to: otherExecutable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: otherExecutable.path
        )
        XCTAssertEqual(
            DS4SelectionValidation.serverError(for: otherExecutable.path),
            "Choose ds4-server, not another executable."
        )

        let ggufDirectory = directory.appendingPathComponent("gguf", isDirectory: true)
        try FileManager.default.createDirectory(
            at: ggufDirectory,
            withIntermediateDirectories: false
        )
        XCTAssertEqual(
            DS4SelectionValidation.preferredModelDirectory(forServerPath: server.path),
            ggufDirectory
        )

        let mainModel = directory.appendingPathComponent("future.gguf")
        try makeGGUF(architecture: "future-model").write(to: mainModel)
        XCTAssertNil(DS4SelectionValidation.modelError(for: mainModel.path))

        let oldQwenModel = directory.appendingPathComponent("old-qwen.gguf")
        try makeGGUF(
            architecture: "qwen4exp",
            uint32Metadata: [
                "qwen4exp.ple.row_count": 10_000,
                "qwen4exp.embedding_length_per_layer_input": 256,
            ]
        ).write(to: oldQwenModel)
        XCTAssertNil(DS4SelectionValidation.modelError(for: oldQwenModel.path))

        let currentQwenModel = directory.appendingPathComponent("current-qwen.gguf")
        try makeGGUF(
            architecture: "qwen4exp",
            uint32Metadata: [
                "qwen4exp.ple.row_count": 10_000,
                "qwen4exp.embedding_length_per_layer_input": 256,
            ],
            tensorDimensions: ["per_layer_token_embd.weight": [256, 10_000]],
            tensorTypes: ["per_layer_token_embd.weight": 30]
        ).write(to: currentQwenModel)
        XCTAssertNil(DS4SelectionValidation.modelError(for: currentQwenModel.path))

        let supportModel = directory.appendingPathComponent("support.gguf")
        try makeGGUF(architecture: "deepseek4_mtp_support").write(to: supportModel)
        XCTAssertEqual(
            DS4SelectionValidation.modelError(for: supportModel.path),
            "Choose a main model GGUF, not a support GGUF."
        )

        let invalidModel = directory.appendingPathComponent("invalid.gguf")
        try Data("not a GGUF".utf8).write(to: invalidModel)
        XCTAssertEqual(
            DS4SelectionValidation.modelError(for: invalidModel.path),
            "Choose a valid GGUF model file."
        )
    }

    private func inspect(architecture: String) throws -> DS4ModelProfile {
        let url = temporaryURL()
        try makeGGUF(architecture: architecture).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return GGUFModelInspector.profile(for: url.path)
    }

    private func makeGGUF(
        architecture: String,
        tensorNames: [String] = [],
        stringMetadata: [String: String] = [:],
        uint32Metadata: [String: UInt32] = [:],
        tensorDimensions: [String: [UInt64]] = [:],
        tensorTypes: [String: UInt32] = [:]
    ) -> Data {
        var data = Data([0x47, 0x47, 0x55, 0x46]) // GGUF
        append(UInt32(3), to: &data)
        append(UInt64(tensorNames.count + tensorDimensions.count), to: &data)
        append(UInt64(1 + stringMetadata.count + uint32Metadata.count), to: &data)
        append(utf8: "general.architecture", to: &data)
        append(UInt32(8), to: &data) // GGUF_TYPE_STRING
        append(utf8: architecture, to: &data)
        for (key, value) in stringMetadata {
            append(utf8: key, to: &data)
            append(UInt32(8), to: &data)
            append(utf8: value, to: &data)
        }
        for (key, value) in uint32Metadata {
            append(utf8: key, to: &data)
            append(UInt32(4), to: &data)
            append(value, to: &data)
        }
        for name in tensorNames {
            append(utf8: name, to: &data)
            append(UInt32(0), to: &data) // dimensions
            append(UInt32(0), to: &data) // tensor type
            append(UInt64(0), to: &data) // data offset
        }
        for (name, dimensions) in tensorDimensions {
            append(utf8: name, to: &data)
            append(UInt32(dimensions.count), to: &data)
            for dimension in dimensions { append(dimension, to: &data) }
            append(tensorTypes[name] ?? UInt32(0), to: &data)
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

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("dsmenubar-\(UUID().uuidString).gguf")
    }
}
