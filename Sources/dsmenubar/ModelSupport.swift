// SPDX-FileCopyrightText: Copyright James Martin and DS Menu Bar contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - Model profiles

/// Model families understood by the current ds4-server branch. This is kept
/// separate from the UI so adding another architecture does not require
/// changing persistence or command construction.
enum DS4ModelFamily: String, Codable, Equatable {
    case deepSeek
    case deepSeek41
    case qwen38
    case glm52
    case glm53Full
    case glm53Flash
    case glm5Full
    case supportModel
    case unknown
}

struct DS4ModelProfile: Equatable {
    let family: DS4ModelFamily
    let architecture: String?
    var contextLength: Int?
    var blockCount: Int?
    var expertCount: Int?
    var leadingDenseBlockCount: Int?
    var nextnPredictLayers: Int?
    var embeddingLength: Int?
    var qwenNGramRowCount: Int?
    var qwenNGramRowDimension: Int?
    /// Nil when a profile was created without inspecting a GGUF. Inspected
    /// Qwen files are true only when they contain ds4's required BF16 table.
    var hasNativeQwenNGrams: Bool?
    var hasVisualRouterBiases: Bool

    init(
        family: DS4ModelFamily,
        architecture: String?,
        contextLength: Int? = nil,
        blockCount: Int? = nil,
        expertCount: Int? = nil,
        leadingDenseBlockCount: Int? = nil,
        nextnPredictLayers: Int? = nil,
        embeddingLength: Int? = nil,
        qwenNGramRowCount: Int? = nil,
        qwenNGramRowDimension: Int? = nil,
        hasNativeQwenNGrams: Bool? = nil,
        hasVisualRouterBiases: Bool = false
    ) {
        self.family = family
        self.architecture = architecture
        self.contextLength = contextLength
        self.blockCount = blockCount
        self.expertCount = expertCount
        self.leadingDenseBlockCount = leadingDenseBlockCount
        self.nextnPredictLayers = nextnPredictLayers
        self.embeddingLength = embeddingLength
        self.qwenNGramRowCount = qwenNGramRowCount
        self.qwenNGramRowDimension = qwenNGramRowDimension
        self.hasNativeQwenNGrams = hasNativeQwenNGrams
        self.hasVisualRouterBiases = hasVisualRouterBiases
    }

    var displayName: String {
        switch family {
        case .deepSeek: return "DeepSeek V4"
        case .deepSeek41: return "DeepSeek V4.1 Flash"
        case .qwen38: return "Qwen3.8 Flash Next"
        case .glm52: return "GLM 5.2 (full)"
        case .glm53Full: return "GLM 5.3 (full)"
        case .glm53Flash: return "GLM 5.3 Flash"
        case .glm5Full: return "GLM 5.x (full)"
        case .supportModel:
            switch architecture {
            case "deepseek4_mtp_support": return "DeepSeek legacy MTP support GGUF"
            case "deepseek4-dspark": return "DeepSeek DSpark support GGUF"
            case "glm5-next-vision": return "GLM 5.3 Flash vision encoder GGUF"
            case "deepseek4-vision": return "DeepSeek vision encoder GGUF"
            case "qwen4-exp-ple": return "Legacy Qwen PLE sidecar GGUF"
            case "clip": return "Vision projector GGUF"
            default: return "Support GGUF (not a main model)"
            }
        case .unknown: return "Unknown model"
        }
    }

    var supportsEmbeddedMTP: Bool {
        switch family {
        case .qwen38:
            return (nextnPredictLayers ?? 0) > 0
        case .glm52, .glm53Full, .glm53Flash, .glm5Full:
            return (nextnPredictLayers ?? 0) > 0
        default:
            return false
        }
    }
    var supportsExternalMTP: Bool { family == .deepSeek }
    var supportsDSpark: Bool { family == .deepSeek }
    var supportsBatchedEmbeddedMTP: Bool {
        family == .qwen38 && supportsEmbeddedMTP
    }
    var supportsVision: Bool { family == .glm53Flash || family == .deepSeek41 || family == .qwen38 }
    var supportsSSDStreaming: Bool { family != .qwen38 }
    var supportsManualPrefill: Bool { family == .deepSeek || family == .qwen38 || family == .unknown }
    var requiresFullPower: Bool {
        switch family {
        case .deepSeek41, .qwen38, .glm52, .glm53Full, .glm53Flash, .glm5Full: return true
        default: return false
        }
    }
    var isGLM: Bool {
        switch family {
        case .glm52, .glm53Full, .glm53Flash, .glm5Full: return true
        default: return false
        }
    }
    var isFullGLM: Bool { family == .glm52 || family == .glm53Full || family == .glm5Full }
    private var routedLayerCount: Int? {
        guard let blocks = blockCount, blocks > 0 else { return nil }
        let nextn = min(blocks, max(0, nextnPredictLayers ?? 0))
        let normalLayers = blocks - nextn
        let dense = min(normalLayers, max(0, leadingDenseBlockCount ?? 0))
        return normalLayers - dense
    }
    var eligibleStreamingLayerCount: Int? {
        guard isFullGLM else { return nil }
        return routedLayerCount
    }
    var cacheableExpertCount: Int? {
        guard let layers = routedLayerCount, let experts = expertCount else { return nil }
        guard layers > 0, experts > 0, layers <= Int.max / experts else { return nil }
        return layers * experts
    }
    var isKnown: Bool { family != .unknown && family != .supportModel }
    var isSupportArtifact: Bool { family == .supportModel }

    static let unknown = Self(family: .unknown, architecture: nil)

    static func from(architecture: String) -> Self {
        let normalized = architecture.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "glm5-next":
            return Self(family: .glm53Flash, architecture: normalized)
        case "glm-dsa":
            return Self(family: .glm5Full, architecture: normalized)
        case "deepseek4":
            return Self(family: .deepSeek, architecture: normalized)
        case "deepseek41":
            return Self(family: .deepSeek41, architecture: normalized, contextLength: 1_048_576)
        case "qwen4exp":
            return Self(family: .qwen38, architecture: normalized, contextLength: 262_144)
        case "deepseek4_mtp_support":
            return Self(family: .supportModel, architecture: normalized)
        case "deepseek4-dspark", "glm5-next-vision", "deepseek4-vision", "qwen4-exp-ple", "clip":
            return Self(family: .supportModel, architecture: normalized)
        default:
            return Self(family: .unknown, architecture: normalized)
        }
    }
}

enum QwenMTPDepth: String, Codable, CaseIterable, Equatable {
    case automatic
    case oneDraft
    case twoDrafts

    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .oneDraft: return "One draft token"
        case .twoDrafts: return "Two draft tokens"
        }
    }

    var environmentValue: String {
        switch self {
        case .automatic: return "0"
        case .oneDraft: return "2"
        case .twoDrafts: return "3"
        }
    }
}

enum QwenYarnFactor: String, Codable, CaseIterable, Equatable {
    case off
    case two
    case four

    var title: String {
        switch self {
        case .off: return "Off"
        case .two: return "2×"
        case .four: return "4×"
        }
    }

    var multiplier: Int {
        switch self {
        case .off: return 1
        case .two: return 2
        case .four: return 4
        }
    }

    var environmentValue: String? {
        self == .off ? nil : String(multiplier)
    }
}

/// The model-specific part of ServerConfiguration.Config. The selected main
/// model remains in Config; these values are remembered independently for
/// every model path.
struct DS4TuningProfile: Codable, Equatable {
    var defaultTokens = 0
    var ctxSize = 1_000_000
    var threads = 0
    var powerPercent = 100
    var prefillChunk = 0
    var warmWeights = false
    var quality = false
    var batchedSessions = 0
    var mixedPrefillQuantum = 128
    var ssdStreamingEnabled = false
    var ssdStreamingCold = false
    var ssdStreamingCacheExperts = ""
    var ssdStreamingFullLayers = -1
    var ssdStreamingPreloadExperts = 0
    var kvDiskEnabled = false
    var kvDiskSpaceMB = 131_072
    var kvCacheMinTokens = 512
    var kvCacheColdMaxTokens = 30_000
    var kvCacheContinuedIntervalTokens = 25_000
    var kvCacheBoundaryTrimTokens = 32
    var kvCacheBoundaryAlignTokens = 2_048
    var kvCacheRejectDifferentQuant = false
    var disableExactDSMLToolReplay = false
    var toolMemoryMaxIDs = 100_000

    var mtpPath = "gguf/DeepSeek-V4-Flash-DSpark-support-0731.gguf"
    var qwenMTPDepth = QwenMTPDepth.automatic
    var qwenYarnFactor = QwenYarnFactor.off
    var qwenImageMaxTokens = 1_024
    var mtpDraft = 1
    var mtpMargin = 3.0
    var mtpMode: MTPMode = .off
    var visionPath = ""
    var visionEnabled = false
    var mtpTiming = false
    var mtpExactSampling = false
    var dsparkConfidence: Double?
    var dsparkStrict = false
    var simulateUsedMemory = ""

    static func defaults(
        for family: DS4ModelFamily,
        physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> Self {
        let gibibyte = UInt64(1_024 * 1_024 * 1_024)
        let memoryGiB = physicalMemoryBytes / gibibyte
        var profile = Self()
        profile.ctxSize = memoryGiB >= 128 ? 262_144 : 131_072
        switch family {
        case .deepSeek:
            profile.ctxSize = max(profile.ctxSize, 393_216)
        case .qwen38:
            if memoryGiB >= 128 {
                profile.prefillChunk = 0
            } else if memoryGiB >= 96 {
                profile.prefillChunk = 4_096
            } else {
                profile.prefillChunk = 2_048
            }
        case .glm52, .glm53Full, .glm5Full:
            profile.ssdStreamingEnabled = true
            if family != .glm52 { profile.mixedPrefillQuantum = 1_024 }
        case .glm53Flash:
            profile.mixedPrefillQuantum = 1_024
        default:
            break
        }
        return profile
    }

    static func defaults(
        for modelProfile: DS4ModelProfile,
        physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> Self {
        var profile = defaults(
            for: modelProfile.family,
            physicalMemoryBytes: physicalMemoryBytes
        )
        if let contextLength = modelProfile.contextLength, contextLength > 0 {
            profile.ctxSize = min(profile.ctxSize, contextLength)
        }
        if profile.prefillChunk > 0 {
            profile.prefillChunk = min(profile.prefillChunk, profile.ctxSize)
        }
        if modelProfile.family == .qwen38 && modelProfile.supportsEmbeddedMTP {
            profile.mtpMode = .embedded
            profile.qwenMTPDepth = .automatic
        }
        return profile
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        defaultTokens = try c.decodeIfPresent(Int.self, forKey: .defaultTokens) ?? defaultTokens
        ctxSize = try c.decodeIfPresent(Int.self, forKey: .ctxSize) ?? ctxSize
        threads = try c.decodeIfPresent(Int.self, forKey: .threads) ?? threads
        powerPercent = try c.decodeIfPresent(Int.self, forKey: .powerPercent) ?? powerPercent
        prefillChunk = try c.decodeIfPresent(Int.self, forKey: .prefillChunk) ?? prefillChunk
        warmWeights = try c.decodeIfPresent(Bool.self, forKey: .warmWeights) ?? warmWeights
        quality = try c.decodeIfPresent(Bool.self, forKey: .quality) ?? quality
        batchedSessions = try c.decodeIfPresent(Int.self, forKey: .batchedSessions) ?? batchedSessions
        mixedPrefillQuantum = try c.decodeIfPresent(Int.self, forKey: .mixedPrefillQuantum) ?? mixedPrefillQuantum
        ssdStreamingEnabled = try c.decodeIfPresent(Bool.self, forKey: .ssdStreamingEnabled) ?? ssdStreamingEnabled
        ssdStreamingCold = try c.decodeIfPresent(Bool.self, forKey: .ssdStreamingCold) ?? ssdStreamingCold
        ssdStreamingCacheExperts = try c.decodeIfPresent(String.self, forKey: .ssdStreamingCacheExperts) ?? ssdStreamingCacheExperts
        ssdStreamingFullLayers = try c.decodeIfPresent(Int.self, forKey: .ssdStreamingFullLayers) ?? ssdStreamingFullLayers
        ssdStreamingPreloadExperts = try c.decodeIfPresent(Int.self, forKey: .ssdStreamingPreloadExperts) ?? ssdStreamingPreloadExperts
        kvDiskEnabled = try c.decodeIfPresent(Bool.self, forKey: .kvDiskEnabled) ?? kvDiskEnabled
        kvDiskSpaceMB = try c.decodeIfPresent(Int.self, forKey: .kvDiskSpaceMB) ?? kvDiskSpaceMB
        kvCacheMinTokens = try c.decodeIfPresent(Int.self, forKey: .kvCacheMinTokens) ?? kvCacheMinTokens
        kvCacheColdMaxTokens = try c.decodeIfPresent(Int.self, forKey: .kvCacheColdMaxTokens) ?? kvCacheColdMaxTokens
        kvCacheContinuedIntervalTokens = try c.decodeIfPresent(Int.self, forKey: .kvCacheContinuedIntervalTokens) ?? kvCacheContinuedIntervalTokens
        kvCacheBoundaryTrimTokens = try c.decodeIfPresent(Int.self, forKey: .kvCacheBoundaryTrimTokens) ?? kvCacheBoundaryTrimTokens
        kvCacheBoundaryAlignTokens = try c.decodeIfPresent(Int.self, forKey: .kvCacheBoundaryAlignTokens) ?? kvCacheBoundaryAlignTokens
        kvCacheRejectDifferentQuant = try c.decodeIfPresent(Bool.self, forKey: .kvCacheRejectDifferentQuant) ?? kvCacheRejectDifferentQuant
        disableExactDSMLToolReplay = try c.decodeIfPresent(Bool.self, forKey: .disableExactDSMLToolReplay) ?? disableExactDSMLToolReplay
        toolMemoryMaxIDs = try c.decodeIfPresent(Int.self, forKey: .toolMemoryMaxIDs) ?? toolMemoryMaxIDs
        mtpPath = try c.decodeIfPresent(String.self, forKey: .mtpPath) ?? mtpPath
        qwenMTPDepth = try c.decodeIfPresent(QwenMTPDepth.self, forKey: .qwenMTPDepth) ?? qwenMTPDepth
        qwenYarnFactor = try c.decodeIfPresent(QwenYarnFactor.self, forKey: .qwenYarnFactor) ?? qwenYarnFactor
        qwenImageMaxTokens = try c.decodeIfPresent(Int.self, forKey: .qwenImageMaxTokens) ?? qwenImageMaxTokens
        mtpDraft = try c.decodeIfPresent(Int.self, forKey: .mtpDraft) ?? mtpDraft
        mtpMargin = try c.decodeIfPresent(Double.self, forKey: .mtpMargin) ?? mtpMargin
        mtpMode = try c.decodeIfPresent(MTPMode.self, forKey: .mtpMode) ?? mtpMode
        visionPath = try c.decodeIfPresent(String.self, forKey: .visionPath) ?? visionPath
        visionEnabled = try c.decodeIfPresent(Bool.self, forKey: .visionEnabled)
            ?? !visionPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        mtpTiming = try c.decodeIfPresent(Bool.self, forKey: .mtpTiming) ?? mtpTiming
        mtpExactSampling = try c.decodeIfPresent(Bool.self, forKey: .mtpExactSampling) ?? mtpExactSampling
        if c.contains(.dsparkConfidence) {
            dsparkConfidence = try c.decode(Double?.self, forKey: .dsparkConfidence)
        }
        dsparkStrict = try c.decodeIfPresent(Bool.self, forKey: .dsparkStrict) ?? dsparkStrict
        simulateUsedMemory = try c.decodeIfPresent(String.self, forKey: .simulateUsedMemory) ?? simulateUsedMemory
    }

    init(configuration: ServerConfiguration.Config) {
        defaultTokens = configuration.defaultTokens
        ctxSize = configuration.ctxSize
        threads = configuration.threads
        powerPercent = configuration.powerPercent
        prefillChunk = configuration.prefillChunk
        warmWeights = configuration.warmWeights
        quality = configuration.quality
        batchedSessions = configuration.batchedSessions
        mixedPrefillQuantum = configuration.mixedPrefillQuantum
        ssdStreamingEnabled = configuration.ssdStreamingEnabled
        ssdStreamingCold = configuration.ssdStreamingCold
        ssdStreamingCacheExperts = configuration.ssdStreamingCacheExperts
        ssdStreamingFullLayers = configuration.ssdStreamingFullLayers
        ssdStreamingPreloadExperts = configuration.ssdStreamingPreloadExperts
        kvDiskEnabled = configuration.kvDiskEnabled
        kvDiskSpaceMB = configuration.kvDiskSpaceMB
        kvCacheMinTokens = configuration.kvCacheMinTokens
        kvCacheColdMaxTokens = configuration.kvCacheColdMaxTokens
        kvCacheContinuedIntervalTokens = configuration.kvCacheContinuedIntervalTokens
        kvCacheBoundaryTrimTokens = configuration.kvCacheBoundaryTrimTokens
        kvCacheBoundaryAlignTokens = configuration.kvCacheBoundaryAlignTokens
        kvCacheRejectDifferentQuant = configuration.kvCacheRejectDifferentQuant
        disableExactDSMLToolReplay = configuration.disableExactDSMLToolReplay
        toolMemoryMaxIDs = configuration.toolMemoryMaxIDs
        mtpPath = configuration.mtpPath
        qwenMTPDepth = configuration.qwenMTPDepth
        qwenYarnFactor = configuration.qwenYarnFactor
        qwenImageMaxTokens = configuration.qwenImageMaxTokens
        mtpDraft = configuration.mtpDraft
        mtpMargin = configuration.mtpMargin
        mtpMode = configuration.mtpMode
        visionPath = configuration.visionPath
        visionEnabled = configuration.visionEnabled
        mtpTiming = configuration.mtpTiming
        mtpExactSampling = configuration.mtpExactSampling
        dsparkConfidence = configuration.dsparkConfidence
        dsparkStrict = configuration.dsparkStrict
        simulateUsedMemory = configuration.simulateUsedMemory
    }

    func applying(to configuration: inout ServerConfiguration.Config) {
        configuration.defaultTokens = defaultTokens
        configuration.ctxSize = ctxSize
        configuration.threads = threads
        configuration.powerPercent = powerPercent
        configuration.prefillChunk = prefillChunk
        configuration.warmWeights = warmWeights
        configuration.quality = quality
        configuration.batchedSessions = batchedSessions
        configuration.mixedPrefillQuantum = mixedPrefillQuantum
        configuration.ssdStreamingEnabled = ssdStreamingEnabled
        configuration.ssdStreamingCold = ssdStreamingCold
        configuration.ssdStreamingCacheExperts = ssdStreamingCacheExperts
        configuration.ssdStreamingFullLayers = ssdStreamingFullLayers
        configuration.ssdStreamingPreloadExperts = ssdStreamingPreloadExperts
        configuration.kvDiskEnabled = kvDiskEnabled
        configuration.kvDiskSpaceMB = kvDiskSpaceMB
        configuration.kvCacheMinTokens = kvCacheMinTokens
        configuration.kvCacheColdMaxTokens = kvCacheColdMaxTokens
        configuration.kvCacheContinuedIntervalTokens = kvCacheContinuedIntervalTokens
        configuration.kvCacheBoundaryTrimTokens = kvCacheBoundaryTrimTokens
        configuration.kvCacheBoundaryAlignTokens = kvCacheBoundaryAlignTokens
        configuration.kvCacheRejectDifferentQuant = kvCacheRejectDifferentQuant
        configuration.disableExactDSMLToolReplay = disableExactDSMLToolReplay
        configuration.toolMemoryMaxIDs = toolMemoryMaxIDs
        configuration.mtpPath = mtpPath
        configuration.qwenMTPDepth = qwenMTPDepth
        configuration.qwenYarnFactor = qwenYarnFactor
        configuration.qwenImageMaxTokens = qwenImageMaxTokens
        configuration.mtpDraft = mtpDraft
        configuration.mtpMargin = mtpMargin
        configuration.mtpMode = mtpMode
        configuration.visionPath = visionPath
        configuration.visionEnabled = visionEnabled
        configuration.mtpTiming = mtpTiming
        configuration.mtpExactSampling = mtpExactSampling
        configuration.dsparkConfidence = dsparkConfidence
        configuration.dsparkStrict = dsparkStrict
        configuration.simulateUsedMemory = simulateUsedMemory
    }
}

enum MTPMode: String, Codable, CaseIterable, Equatable {
    case off
    case embedded
    case external
    case dspark

    var title: String {
        switch self {
        case .off: return "Off"
        case .embedded: return "Embedded MTP"
        case .external: return "Legacy MTP"
        case .dspark: return "DSpark"
        }
    }
}

/// The two kinds of external DeepSeek support GGUF understood by ds4-server.
/// The remaining cases distinguish a path that cannot be inspected from a
/// readable GGUF that is not a support model, so the UI can avoid treating
/// those situations as interchangeable.
enum DS4SupportKind: Equatable {
    case legacyMTP
    case dspark
    case notSupportModel
    case unrecognized
    case unavailable

    var title: String {
        switch self {
        case .legacyMTP: return "Legacy MTP"
        case .dspark: return "DSpark"
        case .notSupportModel: return "Not a support GGUF"
        case .unrecognized: return "Unrecognized GGUF"
        case .unavailable: return "Unavailable"
        }
    }
}

struct DS4SupportProfile: Equatable {
    let kind: DS4SupportKind
    let architecture: String?

    static let unavailable = Self(kind: .unavailable, architecture: nil)
    static let unrecognized = Self(kind: .unrecognized, architecture: nil)

    var isUsable: Bool {
        kind == .legacyMTP || kind == .dspark
    }
}

enum DS4VisionKind: Equatable {
    case glm53Flash
    case deepSeek41
    case qwen38
    case incompatible
    case unavailable
}

struct DS4VisionProfile: Equatable {
    let kind: DS4VisionKind
    let architecture: String?
    let projectionDimension: Int?

    static let unavailable = Self(kind: .unavailable, architecture: nil, projectionDimension: nil)

    func isCompatible(with model: DS4ModelProfile) -> Bool {
        switch (kind, model.family) {
        case (.glm53Flash, .glm53Flash), (.deepSeek41, .deepSeek41):
            return true
        case (.qwen38, .qwen38):
            guard let projectionDimension, let embedding = model.embeddingLength else { return true }
            return projectionDimension == embedding
        default:
            return false
        }
    }
}

// MARK: - Minimal GGUF metadata reader

/// Reads only the GGUF header and metadata needed for capability detection. It
/// seeks past tensor data and tokenizer arrays, so selecting a 100 GB model
/// never loads the model into memory.
enum GGUFModelInspector {
    static func hasGGUFMagic(at path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4)) == Data([0x47, 0x47, 0x55, 0x46])
    }

    static func profile(for path: String) -> DS4ModelProfile {
        return profile(for: path, relativeTo: nil)
    }

    static func profile(for path: String, relativeTo directory: String?) -> DS4ModelProfile {
        guard let candidate = readableCandidate(for: path, relativeTo: directory) else {
            return .unknown
        }
        do {
            return try profile(at: candidate)
        } catch {
            return .unknown
        }
    }

    static func profile(at path: String) throws -> DS4ModelProfile {
        let reader = try GGUFReader(path: path)
        return try reader.architectureProfile()
    }

    static func supportProfile(for path: String) -> DS4SupportProfile {
        supportProfile(for: path, relativeTo: nil)
    }

    static func supportProfile(for path: String, relativeTo directory: String?) -> DS4SupportProfile {
        guard let candidate = readableCandidate(for: path, relativeTo: directory) else {
            return .unavailable
        }
        do {
            return try supportProfile(at: candidate)
        } catch {
            return .unrecognized
        }
    }

    static func supportProfile(at path: String) throws -> DS4SupportProfile {
        let reader = try GGUFReader(path: path)
        return try reader.supportProfile()
    }

    static func visionProfile(for path: String, relativeTo directory: String?) -> DS4VisionProfile {
        guard let candidate = readableCandidate(for: path, relativeTo: directory) else {
            return .unavailable
        }
        return (try? GGUFReader(path: candidate).visionProfile())
            ?? DS4VisionProfile(kind: .incompatible, architecture: nil, projectionDimension: nil)
    }

    static func isGLM53VisionEncoder(at path: String) -> Bool {
        (try? GGUFReader(path: path).visionProfile().kind) == .glm53Flash
    }

    /// Returns nil when the path is empty or unavailable, and false when a
    /// readable file is not the required GLM 5.3 vision encoder.
    static func visionPathIsValid(for path: String, relativeTo directory: String?) -> Bool? {
        guard let candidate = readableCandidate(for: path, relativeTo: directory) else {
            return nil
        }
        return isGLM53VisionEncoder(at: candidate)
    }

    /// Resolve a configured path for inspection, or nil when it is unset or
    /// unreadable. Resolution goes through DS4ServerCommand.resolving so the
    /// file inspected here is the file the launched server will open.
    ///
    /// The empty check is load-bearing, not defensive: an unset path must not
    /// fall through to the server directory.
    private static func readableCandidate(for path: String, relativeTo directory: String?) -> String? {
        let candidate = DS4ServerCommand.resolving(path, relativeTo: directory ?? "")
        guard !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              FileManager.default.isReadableRegularFile(atPath: candidate)
        else { return nil }
        return candidate
    }
}

private final class GGUFReader {
    private let handle: FileHandle
    private let fileSize: UInt64
    private var offset: UInt64 = 0

    init(path: String) throws {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        handle = try FileHandle(forReadingFrom: url)
        fileSize = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
    }

    deinit { try? handle.close() }

    func architectureProfile() throws -> DS4ModelProfile {
        let snapshot = try inspect()
        guard let architecture = snapshot.string("general.architecture") else {
            throw ReaderError.invalidFile
        }
        var profile = DS4ModelProfile.from(architecture: architecture)
        let prefix = profile.architecture ?? ""
        if profile.family == .glm5Full {
            let identity = [
                snapshot.string("general.version"),
                snapshot.string("general.name"),
                snapshot.string("general.basename")
            ].compactMap { $0 }.joined(separator: " ").lowercased()
            if identity.contains("5.3") {
                profile = DS4ModelProfile(family: .glm53Full, architecture: prefix)
            } else if identity.contains("5.2") {
                profile = DS4ModelProfile(family: .glm52, architecture: prefix)
            }
        }
        profile.contextLength = snapshot.positiveInteger("\(prefix).context_length")
            ?? profile.contextLength
        profile.blockCount = snapshot.positiveInteger("\(prefix).block_count")
        profile.expertCount = snapshot.positiveInteger("\(prefix).expert_count")
        profile.leadingDenseBlockCount = snapshot.nonnegativeInteger("\(prefix).leading_dense_block_count")
        profile.nextnPredictLayers = snapshot.nonnegativeInteger("\(prefix).nextn_predict_layers")
        profile.embeddingLength = snapshot.positiveInteger("\(prefix).embedding_length")
        profile.qwenNGramRowCount = snapshot.positiveInteger("qwen4exp.ple.row_count")
        profile.qwenNGramRowDimension = snapshot.positiveInteger("qwen4exp.embedding_length_per_layer_input")
        if profile.family == .qwen38 {
            if let dimensions = snapshot.qwenNGramDimensions,
               let rowCount = profile.qwenNGramRowCount,
               let rowDimension = profile.qwenNGramRowDimension {
                profile.hasNativeQwenNGrams = snapshot.qwenNGramType == 30 &&
                    dimensions.count == 2 &&
                    dimensions[0] == UInt64(rowDimension) &&
                    dimensions[1] >= UInt64(rowCount)
            } else {
                profile.hasNativeQwenNGrams = false
            }
        }
        profile.hasVisualRouterBiases = profile.family == .deepSeek41 &&
            profile.blockCount.map { snapshot.visualRouterLayers.isSuperset(of: 0..<$0) } == true
        return profile
    }

    func visionProfile() throws -> DS4VisionProfile {
        let snapshot = try inspect()
        let architecture = snapshot.string("general.architecture")?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch architecture {
        case "glm5-next-vision":
            return DS4VisionProfile(kind: .glm53Flash, architecture: architecture, projectionDimension: nil)
        case "deepseek4-vision":
            let variant = snapshot.string("deepseek4-vision.checkpoint_variant")?.lowercased()
            let revision = snapshot.string("general.source.revision")?.lowercased()
            guard variant == "v4.1-flash",
                  revision == "df42c109f1defefcbfcedbe7d905718a12266e40" else {
                return DS4VisionProfile(kind: .incompatible, architecture: architecture, projectionDimension: nil)
            }
            return DS4VisionProfile(kind: .deepSeek41, architecture: architecture, projectionDimension: 5_120)
        case "clip":
            guard snapshot.string("clip.projector_type")?.lowercased() == "qwen3vl_merger" else {
                return DS4VisionProfile(kind: .incompatible, architecture: architecture, projectionDimension: nil)
            }
            return DS4VisionProfile(
                kind: .qwen38,
                architecture: architecture,
                projectionDimension: snapshot.integer("clip.vision.projection_dim")
            )
        default:
            return DS4VisionProfile(kind: .incompatible, architecture: architecture, projectionDimension: nil)
        }
    }

    private struct Snapshot {
        var strings: [String: String] = [:]
        var integers: [String: Int] = [:]
        var qwenNGramDimensions: [UInt64]?
        var qwenNGramType: UInt32?
        var visualRouterLayers: Set<Int> = []

        func string(_ key: String) -> String? {
            strings[key] ?? integers[key].map(String.init)
        }

        func integer(_ key: String) -> Int? { integers[key] }
        func positiveInteger(_ key: String) -> Int? {
            guard let value = integers[key], value > 0 else { return nil }
            return value
        }
        func nonnegativeInteger(_ key: String) -> Int? {
            guard let value = integers[key], value >= 0 else { return nil }
            return value
        }
    }

    private func inspect() throws -> Snapshot {
        guard try readUInt32() == 0x46554747 else { throw ReaderError.invalidFile }
        let version = try readUInt32()
        guard (2...3).contains(version) else { throw ReaderError.unsupportedVersion }
        let tensorCount = try readUInt64()
        guard tensorCount <= 10_000_000 else { throw ReaderError.valueTooLarge }
        let metadataCount = try readUInt64()
        guard metadataCount <= 1_000_000 else { throw ReaderError.invalidFile }
        var snapshot = Snapshot()

        for _ in 0..<metadataCount {
            let key = try readString()
            let type = try readUInt32()
            if Self.profileMetadataKey(key) {
                switch GGUFValueType(rawValue: type) {
                case .string:
                    snapshot.strings[key] = try readString()
                case .uint8:
                    snapshot.integers[key] = Int(try readData(length: 1)[0])
                case .uint16:
                    snapshot.integers[key] = Int(try readUInt16())
                case .uint32:
                    snapshot.integers[key] = Int(try readUInt32())
                case .uint64:
                    let value = try readUInt64()
                    if value <= UInt64(Int.max) { snapshot.integers[key] = Int(value) }
                case .int8:
                    snapshot.integers[key] = Int(Int8(bitPattern: try readData(length: 1)[0]))
                case .int16:
                    snapshot.integers[key] = Int(Int16(bitPattern: try readUInt16()))
                case .int32:
                    snapshot.integers[key] = Int(Int32(bitPattern: try readUInt32()))
                case .int64:
                    let value = Int64(bitPattern: try readUInt64())
                    if value >= 0 { snapshot.integers[key] = Int(value) }
                default:
                    try skipValue(type: type, depth: 0)
                }
            } else {
                try skipValue(type: type, depth: 0)
            }
        }

        for _ in 0..<tensorCount {
            let name = try readString()
            let dimensionCount = try readUInt32()
            guard dimensionCount <= 16 else { throw ReaderError.valueTooLarge }
            var dimensions: [UInt64] = []
            dimensions.reserveCapacity(Int(dimensionCount))
            for _ in 0..<dimensionCount { dimensions.append(try readUInt64()) }
            let tensorType = try readUInt32()
            _ = try readUInt64()
            if name == "per_layer_token_embd.weight" {
                snapshot.qwenNGramDimensions = dimensions
                snapshot.qwenNGramType = tensorType
            }
            if name.hasPrefix("blk."), name.hasSuffix(".exp_probs_b_vl.bias") {
                let start = name.index(name.startIndex, offsetBy: 4)
                let end = name.index(name.endIndex, offsetBy: -".exp_probs_b_vl.bias".count)
                if let layer = Int(name[start..<end]) { snapshot.visualRouterLayers.insert(layer) }
            }
        }
        return snapshot
    }

    private static func profileMetadataKey(_ key: String) -> Bool {
        let exact: Set<String> = [
            "general.architecture", "general.version", "general.name", "general.basename",
            "general.source.revision", "deepseek4-vision.checkpoint_variant",
            "clip.projector_type", "clip.vision.projection_dim",
            "qwen4exp.ple.row_count", "qwen4exp.embedding_length_per_layer_input"
        ]
        if exact.contains(key) { return true }
        return [
            ".context_length", ".block_count", ".expert_count",
            ".leading_dense_block_count", ".nextn_predict_layers", ".embedding_length"
        ].contains { key.hasSuffix($0) }
    }

    func architecture() throws -> String {
        guard try readUInt32() == 0x46554747 else { throw ReaderError.invalidFile }
        let version = try readUInt32()
        guard (2...3).contains(version) else { throw ReaderError.unsupportedVersion }
        _ = try readUInt64() // tensor count
        let metadataCount = try readUInt64()
        guard metadataCount <= 1_000_000 else { throw ReaderError.invalidFile }

        for _ in 0..<metadataCount {
            let key = try readString()
            let type = try readUInt32()
            if key == "general.architecture" && type == GGUFValueType.string.rawValue {
                return try readString()
            }
            try skipValue(type: type, depth: 0)
        }
        throw ReaderError.invalidFile
    }

    /// Mirrors ds4-server's support_model_detect without reading tensor data.
    /// GGUF tensor names and metadata are stored in the header, so this scans
    /// only the small index even when the selected main model is tens of GiB.
    func supportProfile() throws -> DS4SupportProfile {
        guard try readUInt32() == 0x46554747 else { throw ReaderError.invalidFile }
        let version = try readUInt32()
        guard (2...3).contains(version) else { throw ReaderError.unsupportedVersion }
        let tensorCount = try readUInt64()
        guard tensorCount <= 10_000_000 else { throw ReaderError.valueTooLarge }
        let metadataCount = try readUInt64()
        guard metadataCount <= 1_000_000 else { throw ReaderError.invalidFile }

        var architecture: String?
        for _ in 0..<metadataCount {
            let key = try readString()
            let type = try readUInt32()
            if key == "general.architecture" && type == GGUFValueType.string.rawValue {
                architecture = try readString()
            } else {
                try skipValue(type: type, depth: 0)
            }
        }

        var tensorNames = Set<String>()
        var dsparkStages = Set<Int>()
        var hasMainProjection = false
        var hasMarkovHead = false
        var hasConfidenceHead = false

        for _ in 0..<tensorCount {
            let name = try readString()
            tensorNames.insert(name)
            if let stage = Self.mtpStage(in: name) {
                dsparkStages.insert(stage)
                hasMainProjection = hasMainProjection || name.contains(".main_proj.")
                hasMarkovHead = hasMarkovHead || name.contains(".markov_head.")
                hasConfidenceHead = hasConfidenceHead || name.contains(".confidence_head.")
            }

            let dimensionCount = try readUInt32()
            let dimensionBytes = UInt64(dimensionCount).multipliedReportingOverflow(by: 8)
            guard !dimensionBytes.overflow else { throw ReaderError.valueTooLarge }
            try skip(length: dimensionBytes.partialValue)
            _ = try readUInt32() // tensor type
            _ = try readUInt64() // data offset
        }

        if dsparkStages.count >= 3 && hasMainProjection && hasMarkovHead && hasConfidenceHead {
            return DS4SupportProfile(kind: .dspark, architecture: architecture)
        }

        let legacySignature: Set<String> = [
            "mtp.0.e_proj.weight",
            "mtp.0.h_proj.weight",
            "mtp.0.hc_head_base.weight"
        ]
        if legacySignature.isSubset(of: tensorNames) {
            return DS4SupportProfile(kind: .legacyMTP, architecture: architecture)
        }

        return DS4SupportProfile(kind: .notSupportModel, architecture: architecture)
    }

    private static func mtpStage(in name: String) -> Int? {
        guard name.hasPrefix("mtp.") else { return nil }
        let remainder = name.dropFirst(4)
        guard let separator = remainder.firstIndex(of: ".") else { return nil }
        return Int(remainder[..<separator])
    }

    private func readString() throws -> String {
        let length = try readUInt64()
        guard length <= 1_048_576 else { throw ReaderError.valueTooLarge }
        let data = try readData(length: length)
        guard let string = String(data: data, encoding: .utf8) else {
            throw ReaderError.invalidString
        }
        return string
    }

    private func skipString() throws {
        let length = try readUInt64()
        try skip(length: length)
    }

    private func skipValue(type: UInt32, depth: Int) throws {
        guard depth < 32 else { throw ReaderError.invalidFile }
        guard let valueType = GGUFValueType(rawValue: type) else {
            throw ReaderError.unsupportedValue
        }
        switch valueType {
        case .uint8, .int8, .bool: try skip(length: 1)
        case .uint16, .int16: try skip(length: 2)
        case .uint32, .int32, .float32: try skip(length: 4)
        case .uint64, .int64, .float64: try skip(length: 8)
        case .string: try skipString()
        case .array:
            let elementType = try readUInt32()
            let count = try readUInt64()
            guard count <= 100_000_000 else { throw ReaderError.valueTooLarge }
            if let elementSize = fixedWidth(for: elementType) {
                let bytes = count.multipliedReportingOverflow(by: elementSize)
                guard !bytes.overflow else { throw ReaderError.valueTooLarge }
                try skip(length: bytes.partialValue)
            } else {
                for _ in 0..<count {
                    try skipValue(type: elementType, depth: depth + 1)
                }
            }
        }
    }

    private func fixedWidth(for type: UInt32) -> UInt64? {
        switch GGUFValueType(rawValue: type) {
        case .uint8, .int8, .bool: return 1
        case .uint16, .int16: return 2
        case .uint32, .int32, .float32: return 4
        case .uint64, .int64, .float64: return 8
        default: return nil
        }
    }

    private func readUInt32() throws -> UInt32 {
        let bytes = try readData(length: 4)
        return UInt32(bytes[0]) |
            (UInt32(bytes[1]) << 8) |
            (UInt32(bytes[2]) << 16) |
            (UInt32(bytes[3]) << 24)
    }

    private func readUInt16() throws -> UInt16 {
        let bytes = try readData(length: 2)
        return UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
    }

    private func readUInt64() throws -> UInt64 {
        let bytes = try readData(length: 8)
        return bytes.enumerated().reduce(UInt64(0)) { value, item in
            value | (UInt64(item.element) << UInt64(item.offset * 8))
        }
    }

    private func readData(length: UInt64) throws -> Data {
        guard length <= fileSize - min(offset, fileSize), length <= UInt64(Int.max) else {
            throw ReaderError.truncated
        }
        let data = try handle.read(upToCount: Int(length)) ?? Data()
        guard data.count == Int(length) else { throw ReaderError.truncated }
        offset += length
        return data
    }

    private func skip(length: UInt64) throws {
        guard length <= fileSize - min(offset, fileSize) else { throw ReaderError.truncated }
        try handle.seek(toOffset: offset + length)
        offset += length
    }

    private enum ReaderError: Error {
        case invalidFile
        case unsupportedVersion
        case unsupportedValue
        case invalidString
        case valueTooLarge
        case truncated
    }

    private enum GGUFValueType: UInt32 {
        case uint8 = 0
        case int8 = 1
        case uint16 = 2
        case int16 = 3
        case uint32 = 4
        case int32 = 5
        case float32 = 6
        case bool = 7
        case string = 8
        case array = 9
        case uint64 = 10
        case int64 = 11
        case float64 = 12
    }
}
