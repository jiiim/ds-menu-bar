// SPDX-FileCopyrightText: Copyright 2026 James Martin
// SPDX-License-Identifier: MIT

import Foundation
import os.log
import ServiceManagement

// MARK: - ServerConfiguration

/// Owns the user-editable configuration and its persistence.
///
/// The configuration intentionally models only the supported local Metal
/// server workflow. Distributed, CUDA, and other multi-node options remain
/// command-line concerns.
final class ServerConfiguration {
    private var values = Config()
    private let defaults: UserDefaults
    private(set) var showsPerformanceInMenuBar: Bool
    private(set) var keepsAwakeWhileRunning: Bool
    private let log = OSLog(subsystem: "com.jiiim.ds-menu-bar", category: "config")

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showsPerformanceInMenuBar = defaults.bool(forKey: Self.performanceDisplayKey)
        keepsAwakeWhileRunning = defaults.bool(forKey: Self.keepAwakeKey)
        loadConfig()
    }

    // MARK: Codable snapshot

    /// One persisted Codable value keeps migration and testing straightforward.
    struct Config: Codable, Equatable {
        // Model and server identity.
        var serverPath = ""
        var modelPath = "ds4flash.gguf"
        var host = "127.0.0.1"
        var port = 8000

        // Runtime and local Metal performance.
        /// Zero means use ds4-server's default.
        var defaultTokens = 0
        var ctxSize = 1_000_000
        /// Zero means use the engine's automatic helper-thread behavior.
        var threads = 0
        var powerPercent = 100
        /// Zero means use the model/backend default.
        var prefillChunk = 0
        var warmWeights = false
        var quality = false

        // HTTP server.
        var corsEnabled = false
        /// Zero disables native session batching. Values greater than zero are
        /// passed as --batched-session.
        var batchedSessions = 0
        var mixedPrefillQuantum = 128

        // Optional SSD-backed model streaming.
        var ssdStreamingEnabled = false
        var ssdStreamingCold = false
        /// Empty means automatic. Otherwise this is a positive expert count or
        /// a positive GiB budget such as "40GB", matching ds4's parser.
        var ssdStreamingCacheExperts = ""
        /// -1 means automatic; zero explicitly disables full-layer residency.
        var ssdStreamingFullLayers = -1
        /// Zero means automatic; otherwise this must be positive.
        var ssdStreamingPreloadExperts = 0

        // Disk KV cache. Off by default: it writes checkpoints under kvDiskDir
        // and only pays off for repeated prefixes, so it is opt-in.
        var kvDiskEnabled = false
        var kvDiskDir = "/tmp/ds4-kv"
        var kvDiskSpaceMB = 131_072
        var kvCacheMinTokens = 512
        var kvCacheColdMaxTokens = 30_000
        // Preserve DS Menu Bar's existing default rather than silently changing
        // the behavior of existing installations.
        var kvCacheContinuedIntervalTokens = 25_000
        var kvCacheBoundaryTrimTokens = 32
        var kvCacheBoundaryAlignTokens = 2_048
        var kvCacheRejectDifferentQuant = false
        var disableExactDSMLToolReplay = false
        var toolMemoryMaxIDs = 100_000

        // Model-specific tuning. The values are the effective profile for
        // modelPath; modelProfiles remembers separate values for other models.
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

        var automaticDSparkConfidence: Double {
            mtpExactSampling ? 0.8 : 0.6
        }

        /// Profiles are keyed by the canonical selected-model path. The map is
        /// persisted with the configuration so switching models restores the
        /// user's previous tuning choices instead of sharing one global set.
        var modelProfiles: [String: DS4TuningProfile] = [:]

        /// Compatibility surface for callers and old tests. New code should
        /// use mtpMode because embedded GLM MTP has no support-model path.
        var mtpEnabled: Bool {
            get { mtpMode != .off }
            set { mtpMode = newValue ? .external : .off }
        }

        // Diagnostics and application behavior.
        var traceEnabled = false
        var tracePath = "~/Library/Logs/dsmenubar/ds4-trace.log"
        var logPath = "~/Library/Logs/dsmenubar/ds4.log"
        var logMaxSizeMB = 10
        var launchAtLogin = false
    }

    // MARK: Configuration access

    /// The only property read individually outside a snapshot: the menu-bar
    /// "Open Log in Console" action and the failure-reason tail both need it
    /// without taking a full copy of the configuration.
    var logPath: String { values.logPath }

    /// Return an immutable value snapshot suitable for a Settings draft or a
    /// process launch. A value snapshot prevents half-edited settings from
    /// reaching a child process.
    func snapshot() -> Config {
        values
    }

    /// Replace the active configuration with a validated Settings snapshot.
    func replace(with config: Config) {
        values = config.normalized().storingCurrentModelProfile()
    }

    // MARK: Persistence

    private static let configKey = "dsmenubar.config"
    private static let performanceDisplayKey = "dsmenubar.showPerformanceInMenuBar"
    private static let keepAwakeKey = "dsmenubar.keepAwakeWhileServerRuns"

    var needsInitialSetup: Bool {
        guard defaults.object(forKey: Self.configKey) != nil else { return true }
        return values.serverPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            values.modelPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func loadConfig() {
        if let data = defaults.data(forKey: Self.configKey),
           let config = try? JSONDecoder().decode(Config.self, from: data) {
            values = config.normalized().storingCurrentModelProfile()
        }
    }

    func completeInitialSetup(
        serverPath: String,
        modelPath: String,
        modelProfile: DS4ModelProfile? = nil
    ) {
        var configured = values
        configured.serverPath = serverPath
        configured.modelPath = modelPath
        configured = configured.normalized()
        let profile = modelProfile ?? GGUFModelInspector.profile(for: configured.modelPath)
        configured = configured.restoringTuningDefaults(for: profile)
        configured = configured.storingCurrentModelProfile()
        values = configured
        persistConfig()
    }

    private func persistConfig() {
        if let data = try? JSONEncoder().encode(values) {
            defaults.set(data, forKey: Self.configKey)
        }
    }

    /// Why a launch-at-login request did not take full effect. Returned by
    /// `save()` so Settings can say so: the read-back below can flip the toggle
    /// back off, and a toggle that silently undoes itself reads as a bug.
    enum LoginItemWarning {
        case enableFailed(String)
        case disableFailed(String)
        case approvalRequired

        var message: String {
            switch self {
            case .enableFailed(let reason):
                return "Launch at login could not be enabled — \(reason)"
            case .disableFailed(let reason):
                return "Launch at login could not be disabled — \(reason)"
            case .approvalRequired:
                return "Launch at login needs approval in System Settings › General › Login Items."
            }
        }
    }

    struct LoginItemUpdate {
        let isEnabled: Bool
        let warning: String?
    }

    /// Apply this app-only setting immediately without sending the server
    /// configuration through its staged Apply & Restart path.
    func setLaunchAtLogin(_ requested: Bool) -> LoginItemUpdate {
        values.launchAtLogin = requested
        let warning = applyLoginItem()?.message
        persistConfig()
        return LoginItemUpdate(isEnabled: values.launchAtLogin, warning: warning)
    }

    /// Persist this app-only display preference immediately. It does not alter
    /// ds4-server's command line and must not enter the Apply & Restart path.
    func setShowsPerformanceInMenuBar(_ requested: Bool) {
        showsPerformanceInMenuBar = requested
        defaults.set(requested, forKey: Self.performanceDisplayKey)
    }

    /// Persist the keep-awake preference immediately, on the same terms: it is
    /// an app behavior, not part of ds4-server's command line.
    func setKeepsAwakeWhileRunning(_ requested: Bool) {
        keepsAwakeWhileRunning = requested
        defaults.set(requested, forKey: Self.keepAwakeKey)
    }

    /// Persist the current configuration and apply launch-at-login. Login-item
    /// state is read back because unsigned/debug builds can reject registration.
    @discardableResult
    func save() -> LoginItemWarning? {
        let warning = applyLoginItem()
        persistConfig()
        return warning
    }

    /// Whether the app is currently registered as a login item — including the
    /// registered-but-awaiting-approval state, since re-registering does not
    /// advance it.
    private static var isLoginItemActive: Bool {
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }

    /// Register or unregister only when the live login-item state differs from
    /// the requested one. The calls are idempotent, but every Apply persists the
    /// whole configuration, and an Apply that never touched the toggle has no
    /// reason to make an SMAppService call at all.
    private func applyLoginItem() -> LoginItemWarning? {
        let requested = values.launchAtLogin
        var failure: String?
        if requested != Self.isLoginItemActive {
            do {
                if requested {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                failure = error.localizedDescription
                os_log(.error, log: log, "login item %{public}s failed: %{public}@",
                       requested ? "enable" : "disable", error.localizedDescription)
            }
        }

        let status = SMAppService.mainApp.status
        values.launchAtLogin = (status == .enabled || status == .requiresApproval)

        // Report only on an end state that differs from what was asked for; a
        // call that threw but landed in the requested state needs no message.
        if values.launchAtLogin != requested {
            let reason = failure ?? "the system reports it as \(Self.describe(status))"
            return requested ? .enableFailed(reason) : .disableFailed(reason)
        }
        if requested && status == .requiresApproval { return .approvalRequired }
        return nil
    }

    private static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: return "not registered"
        case .enabled: return "enabled"
        case .requiresApproval: return "awaiting approval"
        case .notFound: return "not found"
        @unknown default: return "in an unknown state"
        }
    }
}

// MARK: - Server limits and validation

enum DS4ConfigurationLimits {
    static let maxParserInteger = Int(Int32.max)
    static let maxParserUnsignedInteger = UInt64(UInt32.max)
    static let maxGiB = UInt64.max / (1_024 * 1_024 * 1_024)
    static let minPort = 1
    static let maxPort = 65_535
    static let minPowerPercent = 1
    static let maxPowerPercent = 100
    static let minMTPDraft = 1
    static let maxMTPDraft = 16
    static let minMTPMargin = 0.0
    static let maxMTPMargin = 1_000.0
    static let minQwenImageTokens = 64
    static let maxQwenImageTokens = 16_383
}

struct DS4IntegerConstraint: Equatable {
    let minimum: Int
    let maximum: Int
    let sentinelDescription: String?
    let defaultValue: Int?
    let recommendedValue: Int?
    let step: Int
    let units: String?
    let source: String

    init(
        minimum: Int,
        maximum: Int,
        sentinelDescription: String?,
        defaultValue: Int? = nil,
        recommendedValue: Int? = nil,
        step: Int = 1,
        units: String? = nil,
        source: String = "ds4-server option parser"
    ) {
        self.minimum = minimum
        self.maximum = maximum
        self.sentinelDescription = sentinelDescription
        self.defaultValue = defaultValue
        self.recommendedValue = recommendedValue
        self.step = step
        self.units = units
        self.source = source
    }

    func contains(_ value: Int) -> Bool { (minimum...maximum).contains(value) }
}

struct DS4DecimalConstraint: Equatable {
    let minimum: Double
    let maximum: Double
    let defaultValue: Double?
    let recommendedValue: Double?
    let step: Double
    let source: String

    func contains(_ value: Double) -> Bool {
        value.isFinite && (minimum...maximum).contains(value)
    }
}

struct DS4NumericTextConstraint: Equatable {
    enum Syntax: Equatable {
        case gib
        case expertCountOrGiB
        case unsignedInteger
    }

    let syntax: Syntax
    let countMaximum: UInt64?
    let gibMaximum: UInt64
    let sentinelDescription: String
    let source: String

    func contains(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lower = trimmed.lowercased()
        let hasGiBSuffix = lower.hasSuffix("gb")
        let digits = hasGiBSuffix ? String(lower.dropLast(2)) : lower
        guard !digits.isEmpty,
              digits.unicodeScalars.allSatisfy({ (48...57).contains($0.value) }),
              let number = UInt64(digits) else { return false }

        if syntax == .unsignedInteger {
            return !hasGiBSuffix && number <= (countMaximum ?? UInt64.max)
        }
        guard number > 0 else { return false }

        if syntax == .expertCountOrGiB && !hasGiBSuffix {
            return number <= (countMaximum ?? DS4ConfigurationLimits.maxParserUnsignedInteger)
        }
        return number <= gibMaximum
    }

    var rangeDescription: String {
        switch syntax {
        case .gib:
            return "Valid range: 1–\(gibMaximum.formatted()) GiB"
        case .expertCountOrGiB:
            let count = countMaximum ?? DS4ConfigurationLimits.maxParserUnsignedInteger
            return "Valid range: 1–\(count.formatted()) experts, or 1–\(gibMaximum.formatted())GB"
        case .unsignedInteger:
            return "Valid range: 0–\((countMaximum ?? UInt64.max).formatted())"
        }
    }
}

extension ServerConfiguration.Config {
    /// Identifies the field an error belongs to, so Settings can place a message
    /// next to the control that produced it. A typed enum rather than bare
    /// strings: a mismatch between the validator's key and the row's key would
    /// otherwise just silently hide the error.
    enum Field: String, CaseIterable {
        case serverPath, modelPath, host, port
        case defaultTokens, ctxSize, threads, powerPercent, prefillChunk
        case ssdStreamingEnabled
        case kvDiskDir, kvDiskSpaceMB, kvCacheMinTokens, kvCacheColdMaxTokens
        case kvCacheContinuedIntervalTokens, kvCacheBoundaryTrimTokens
        case kvCacheBoundaryAlignTokens, toolMemoryMaxIDs
        case batchedSessions, mixedPrefillQuantum
        case mtpMode, mtpPath, mtpDraft, mtpMargin, visionPath, dsparkConfidence
        case qwenImageMaxTokens
        case simulateUsedMemory
        case tracePath, logPath, logMaxSizeMB
        case ssdStreamingCacheExperts, ssdStreamingFullLayers, ssdStreamingPreloadExperts
    }

    func integerConstraint(
        for field: Field,
        modelProfile: DS4ModelProfile = .unknown
    ) -> DS4IntegerConstraint? {
        let parserMax = DS4ConfigurationLimits.maxParserInteger
        switch field {
        case .port:
            return .init(minimum: DS4ConfigurationLimits.minPort,
                         maximum: DS4ConfigurationLimits.maxPort,
                         sentinelDescription: nil, defaultValue: 8_000)
        case .defaultTokens:
            return .init(minimum: 0, maximum: parserMax, sentinelDescription: "0 = Server default", defaultValue: 0)
        case .threads:
            return .init(minimum: 0, maximum: parserMax, sentinelDescription: "0 = Automatic", defaultValue: 0)
        case .batchedSessions:
            return .init(minimum: 0, maximum: parserMax, sentinelDescription: "0 = Off", defaultValue: 0)
        case .ctxSize:
            let nativeMaximum = max(1, min(modelProfile.contextLength ?? parserMax, parserMax))
            let multiplier = modelProfile.family == .qwen38 ? qwenYarnFactor.multiplier : 1
            let maximum = nativeMaximum > parserMax / multiplier
                ? parserMax
                : nativeMaximum * multiplier
            let familyDefault = DS4TuningProfile.defaults(for: modelProfile.family).ctxSize
            let recommended = min(familyDefault, maximum)
            return .init(minimum: 1, maximum: maximum,
                         sentinelDescription: nil, recommendedValue: recommended, units: "tokens",
                         source: modelProfile.family == .qwen38 && qwenYarnFactor != .off
                            ? "selected GGUF context_length × Qwen YaRN factor and ds4-server parser"
                            : "selected GGUF context_length and ds4-server parser")
        case .powerPercent:
            let minimum = modelProfile.requiresFullPower
                ? DS4ConfigurationLimits.maxPowerPercent
                : DS4ConfigurationLimits.minPowerPercent
            return .init(minimum: minimum, maximum: DS4ConfigurationLimits.maxPowerPercent, sentinelDescription: nil,
                         defaultValue: 100, recommendedValue: 100, units: "%",
                         source: "selected model Metal backend and ds4-server --power parser")
        case .prefillChunk:
            guard modelProfile.supportsManualPrefill else { return nil }
            let familyMaximum = modelProfile.family == .qwen38 ? 65_536 : parserMax
            let maximum = max(1, min(ctxSize, familyMaximum))
            let familyDefault = DS4TuningProfile.defaults(for: modelProfile.family).prefillChunk
            let recommended = min(familyDefault, maximum)
            return .init(
                minimum: 0,
                maximum: maximum,
                sentinelDescription: "0 = Automatic",
                recommendedValue: recommended,
                units: "tokens",
                source: modelProfile.family == .qwen38
                    ? "Qwen Metal prefill graph and selected context"
                    : "ds4-server parser and selected context"
            )
        case .mixedPrefillQuantum:
            let glm53 = modelProfile.family == .glm53Full || modelProfile.family == .glm53Flash ||
                modelProfile.family == .glm5Full
            return .init(minimum: glm53 ? 1_024 : 1, maximum: parserMax,
                         sentinelDescription: nil, defaultValue: glm53 ? 1_024 : 128,
                         units: "tokens", source: "ds4-server mixed-prefill scheduler")
        case .ssdStreamingFullLayers:
            guard modelProfile.isFullGLM else { return nil }
            return .init(
                minimum: -1,
                maximum: modelProfile.eligibleStreamingLayerCount ?? parserMax,
                sentinelDescription: "-1 = Automatic; 0 = Disabled",
                defaultValue: -1,
                source: "selected GGUF routed-layer metadata"
            )
        case .ssdStreamingPreloadExperts:
            return .init(
                minimum: 0,
                maximum: modelProfile.cacheableExpertCount ?? parserMax,
                sentinelDescription: "0 = Automatic",
                defaultValue: 0,
                source: "selected GGUF routed-layer and expert metadata"
            )
        case .kvDiskSpaceMB, .kvCacheMinTokens, .toolMemoryMaxIDs:
            return .init(minimum: 1, maximum: parserMax, sentinelDescription: nil)
        case .logMaxSizeMB:
            return .init(
                minimum: 1,
                maximum: 10_240,
                sentinelDescription: nil,
                defaultValue: 10,
                units: "MB",
                source: "DS Menu Bar log rotation"
            )
        case .kvCacheColdMaxTokens, .kvCacheContinuedIntervalTokens,
             .kvCacheBoundaryTrimTokens, .kvCacheBoundaryAlignTokens:
            return .init(minimum: 0, maximum: parserMax, sentinelDescription: "0 = Disabled")
        case .mtpDraft:
            guard modelProfile.supportsExternalMTP else { return nil }
            return .init(minimum: DS4ConfigurationLimits.minMTPDraft,
                         maximum: DS4ConfigurationLimits.maxMTPDraft,
                         sentinelDescription: nil,
                         defaultValue: 1,
                         recommendedValue: 1,
                         units: "tokens",
                         source: "ds4-server legacy autoregressive MTP")
        case .qwenImageMaxTokens:
            guard modelProfile.family == .qwen38 else { return nil }
            return .init(
                minimum: DS4ConfigurationLimits.minQwenImageTokens,
                maximum: DS4ConfigurationLimits.maxQwenImageTokens,
                sentinelDescription: nil,
                defaultValue: 1_024,
                recommendedValue: 1_024,
                units: "tokens",
                source: "DS4_QWEN4_IMAGE_MAX_TOKENS parser"
            )
        default:
            return nil
        }
    }

    func decimalConstraint(for field: Field) -> DS4DecimalConstraint? {
        switch field {
        case .mtpMargin:
            return .init(minimum: DS4ConfigurationLimits.minMTPMargin,
                         maximum: DS4ConfigurationLimits.maxMTPMargin,
                         defaultValue: 3, recommendedValue: 3, step: 0.1,
                         source: "ds4-server --mtp-margin parser")
        case .dsparkConfidence:
            return .init(minimum: 0, maximum: 1, defaultValue: nil,
                         recommendedValue: automaticDSparkConfidence, step: 0.01,
                         source: "ds4-server --dspark-confidence parser")
        default:
            return nil
        }
    }

    func numericTextConstraint(
        for field: Field,
        modelProfile: DS4ModelProfile = .unknown
    ) -> DS4NumericTextConstraint? {
        switch field {
        case .ssdStreamingCacheExperts:
            let maximum = modelProfile.cacheableExpertCount.map(UInt64.init)
                ?? DS4ConfigurationLimits.maxParserUnsignedInteger
            return .init(syntax: .expertCountOrGiB,
                         countMaximum: min(maximum, DS4ConfigurationLimits.maxParserUnsignedInteger),
                         gibMaximum: DS4ConfigurationLimits.maxGiB,
                         sentinelDescription: "Blank = Automatic",
                         source: "ds4 SSD parser and selected GGUF expert metadata")
        case .simulateUsedMemory:
            return .init(syntax: .gib, countMaximum: nil,
                         gibMaximum: DS4ConfigurationLimits.maxGiB,
                         sentinelDescription: "Blank = Off",
                         source: "ds4 GiB parser")
        default:
            return nil
        }
    }

    /// True when the selected model decodes batched sessions and MTP together.
    /// ds4-server takes this path only for Qwen embedded MTP on Metal; see
    /// `qwen4_batch_mtp` in ds4_server.c.
    func usesBatchedEmbeddedMTP(modelProfile: DS4ModelProfile) -> Bool {
        batchedSessions > 0 && mtpMode == .embedded &&
            modelProfile.supportsBatchedEmbeddedMTP
    }

    /// True when batching and MTP are both requested but the model cannot run
    /// them together. ds4-server does not refuse this combination — it starts
    /// and silently drops MTP — so the conflict is surfaced here instead.
    ///
    /// The Settings panes render their own wording for this, so the rule lives
    /// here rather than in the view: one model gaining batched MTP upstream
    /// must not need matching edits in three places.
    func hasBatchedSessionMTPConflict(modelProfile: DS4ModelProfile) -> Bool {
        batchedSessions > 0 && mtpMode != .off && modelProfile.isKnown &&
            !usesBatchedEmbeddedMTP(modelProfile: modelProfile)
    }

    /// The widest decode batch ds4-server speculates over in one pass, counted
    /// in sessions ready to decode in that cycle rather than resident slots;
    /// see `ds4_sessions_eval_batch_speculative_argmax`. A wider cycle keeps
    /// MTP and takes the sequential fallback: one speculative cycle per
    /// session. More resident slots than this are fine — only the sessions
    /// decoding at the same moment count against it.
    static let maxBatchedEmbeddedMTPDecodeWidth = 16

    /// Validate the constraints enforced by ds4-server's option parser plus
    /// cross-option constraints that would otherwise produce a misleading run.
    func validationErrors(
        modelProfile: DS4ModelProfile = .unknown,
        supportProfile: DS4SupportProfile = .unavailable,
        visionPathIsValid: Bool? = nil,
        visionProfile: DS4VisionProfile? = nil
    ) -> [Field: String] {
        var errors: [Field: String] = [:]
        func nonEmpty(_ value: String, field: Field, message: String) {
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors[field] = message
            }
        }
        func bounded(_ value: Int, field: Field, label: String) {
            guard let constraint = integerConstraint(for: field, modelProfile: modelProfile),
                  !constraint.contains(value) else { return }
            if constraint.minimum == constraint.maximum {
                errors[field] = "\(label) must be \(constraint.minimum)"
            } else {
                errors[field] = "\(label) must be between \(constraint.minimum) and \(constraint.maximum)"
            }
        }

        nonEmpty(serverPath, field: .serverPath, message: "Choose a ds4-server executable")
        nonEmpty(modelPath, field: .modelPath, message: "Choose a model file")
        if modelProfile.isSupportArtifact {
            errors[.modelPath] = "This is a \(modelProfile.displayName), not a main model. Choose a main model GGUF instead."
        }
        nonEmpty(host, field: .host, message: "Host cannot be empty")
        // No hostname or address literal contains whitespace, so a space is
        // always a typo — and an expensive one. ds4-server's bind fails on it,
        // and the app builds its health-check URL from the same string, which
        // URLComponents rejects. Naming the field beats spending a launch to
        // report a URL error about a value the user can see is wrong.
        if errors[.host] == nil,
           host.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
            errors[.host] = "Host cannot contain whitespace"
        }
        nonEmpty(logPath, field: .logPath, message: "Choose a server log file")
        bounded(logMaxSizeMB, field: .logMaxSizeMB, label: "Maximum size per log")

        bounded(port, field: .port, label: "Port")
        bounded(ctxSize, field: .ctxSize, label: "Context size")
        bounded(defaultTokens, field: .defaultTokens, label: "Default output tokens")
        bounded(threads, field: .threads, label: "Threads")
        if modelProfile.supportsManualPrefill {
            bounded(prefillChunk, field: .prefillChunk, label: "Prefill chunk")
        }
        bounded(powerPercent, field: .powerPercent, label: "Power limit")

        bounded(batchedSessions, field: .batchedSessions, label: "Resident sessions")
        if batchedSessions > 0 { bounded(mixedPrefillQuantum, field: .mixedPrefillQuantum, label: "Mixed prefill quantum") }
        if hasBatchedSessionMTPConflict(modelProfile: modelProfile) {
            errors[.batchedSessions] =
                "\(modelProfile.displayName) cannot run session batching and MTP together; turn off one of these features"
        }

        if ssdStreamingEnabled {
            if modelProfile.isKnown && !modelProfile.supportsSSDStreaming {
                errors[.ssdStreamingEnabled] = "SSD streaming is not supported for \(modelProfile.displayName)"
            }
            if !ssdStreamingCacheExperts.isEmpty,
               let constraint = numericTextConstraint(for: .ssdStreamingCacheExperts, modelProfile: modelProfile),
               !constraint.contains(ssdStreamingCacheExperts) {
                errors[.ssdStreamingCacheExperts] = "Use \(constraint.rangeDescription.lowercased()), or leave blank for Automatic"
            }
            if modelProfile.isFullGLM {
                bounded(ssdStreamingFullLayers, field: .ssdStreamingFullLayers, label: "Full resident layers")
            }
            bounded(ssdStreamingPreloadExperts, field: .ssdStreamingPreloadExperts, label: "Preloaded experts")
        }

        let usesExternalSupport =
            (mtpMode == .external && modelProfile.supportsExternalMTP) ||
            (mtpMode == .dspark && modelProfile.supportsDSpark)
        if ssdStreamingEnabled && usesExternalSupport {
            let message = "SSD streaming cannot be used with Legacy MTP or DSpark; turn off one of these features"
            errors[.ssdStreamingEnabled] = message
            errors[.mtpMode] = message
        }

        if kvDiskEnabled {
            nonEmpty(kvDiskDir, field: .kvDiskDir, message: "Choose a KV cache directory")
            bounded(kvDiskSpaceMB, field: .kvDiskSpaceMB, label: "KV disk budget")
            bounded(kvCacheMinTokens, field: .kvCacheMinTokens, label: "Minimum cache tokens")
            if kvCacheColdMaxTokens < 0 {
                errors[.kvCacheColdMaxTokens] = "Cold-cache maximum must be 0 or greater"
            } else if kvCacheColdMaxTokens > 0 && kvCacheColdMaxTokens < kvCacheMinTokens {
                errors[.kvCacheColdMaxTokens] = "Cold-cache maximum must be 0 or at least the minimum cache size"
            }
            if kvCacheContinuedIntervalTokens < 0 {
                errors[.kvCacheContinuedIntervalTokens] = "Continued interval must be 0 or greater"
            }
            if kvCacheBoundaryTrimTokens < 0 {
                errors[.kvCacheBoundaryTrimTokens] = "Boundary trim must be 0 or greater"
            }
            if kvCacheBoundaryAlignTokens < 0 {
                errors[.kvCacheBoundaryAlignTokens] = "Boundary alignment must be 0 or greater"
            }
            bounded(kvCacheContinuedIntervalTokens, field: .kvCacheContinuedIntervalTokens, label: "Continued interval")
            bounded(kvCacheBoundaryTrimTokens, field: .kvCacheBoundaryTrimTokens, label: "Boundary trim")
            bounded(kvCacheBoundaryAlignTokens, field: .kvCacheBoundaryAlignTokens, label: "Boundary alignment")
            bounded(toolMemoryMaxIDs, field: .toolMemoryMaxIDs, label: "Tool-memory limit")
        }

        if modelProfile.isKnown {
            switch mtpMode {
            case .off:
                break
            case .embedded:
                if !modelProfile.supportsEmbeddedMTP {
                    errors[.mtpMode] = "The selected model does not contain embedded MTP weights"
                }
            case .external:
                if !modelProfile.supportsExternalMTP {
                    errors[.mtpMode] = "Legacy MTP is available only for DeepSeek models"
                } else {
                    nonEmpty(mtpPath, field: .mtpPath, message: "Choose an MTP model file")
                    if !mtpPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        switch supportProfile.kind {
                        case .dspark:
                            errors[.mtpPath] = "This is a DSpark support GGUF. Select DSpark mode, or choose a legacy MTP support GGUF for Legacy MTP."
                        case .notSupportModel, .unrecognized:
                            errors[.mtpPath] = "Choose a legacy MTP support GGUF"
                        case .legacyMTP, .unavailable:
                            break
                        }
                    }
                    bounded(mtpDraft, field: .mtpDraft, label: "MTP draft tokens")
                    if let constraint = decimalConstraint(for: .mtpMargin), !constraint.contains(mtpMargin) {
                        errors[.mtpMargin] = "MTP margin must be between \(constraint.minimum.formatted()) and \(constraint.maximum.formatted())"
                    }
                }
            case .dspark:
                if !modelProfile.supportsDSpark {
                    errors[.mtpMode] = "DSpark is available only for DeepSeek models"
                } else {
                    nonEmpty(mtpPath, field: .mtpPath, message: "Choose a DSpark support model")
                    if !mtpPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        switch supportProfile.kind {
                        case .legacyMTP:
                            errors[.mtpPath] = "This is a legacy MTP support GGUF. Choose a DSpark support GGUF, or select Legacy MTP mode to use this file."
                        case .notSupportModel, .unrecognized:
                            errors[.mtpPath] = "Choose a DSpark support GGUF"
                        case .dspark, .unavailable:
                            break
                        }
                    }
                    if let confidence = dsparkConfidence,
                       let constraint = decimalConstraint(for: .dsparkConfidence),
                       !constraint.contains(confidence) {
                        errors[.dsparkConfidence] = "DSpark confidence must be between \(constraint.minimum.formatted()) and \(constraint.maximum.formatted())"
                    }
                }
            }

            // A saved vision path is retained when another model is
            // selected, but it must not make that model invalid.
            if modelProfile.supportsVision && visionEnabled {
                let expected = "Choose a compatible \(modelProfile.displayName) vision GGUF"
                nonEmpty(visionPath, field: .visionPath, message: expected)
                if !visionPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let compatible = visionProfile.map { $0.isCompatible(with: modelProfile) }
                        ?? visionPathIsValid
                    if compatible == false { errors[.visionPath] = expected }
                }
                if modelProfile.family == .deepSeek41 && !modelProfile.hasVisualRouterBiases {
                    errors[.visionPath] = "This DeepSeek V4.1 GGUF lacks the visual router biases required for vision"
                }
                if modelProfile.family == .qwen38 {
                    bounded(qwenImageMaxTokens, field: .qwenImageMaxTokens, label: "Qwen image-token limit")
                }
            }
        }

        if !simulateUsedMemory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let constraint = numericTextConstraint(for: .simulateUsedMemory, modelProfile: modelProfile),
           !constraint.contains(simulateUsedMemory) {
            errors[.simulateUsedMemory] = "Use \(constraint.rangeDescription.lowercased()), such as 8 or 40GB"
        }

        if traceEnabled {
            nonEmpty(tracePath, field: .tracePath, message: "Choose a request trace file")
            let resolvedTrace = URL(fileURLWithPath: DS4ServerCommand.expandingTilde(tracePath))
                .standardizedFileURL.path
            let resolvedLog = URL(fileURLWithPath: DS4ServerCommand.expandingTilde(logPath))
                .standardizedFileURL.path
            if !tracePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                resolvedTrace == resolvedLog {
                errors[.tracePath] = "Trace and server log must use different files"
            }
        }

        return errors
    }

    var isValid: Bool { validationErrors().isEmpty }

    /// The first error in `Field` declaration order, which follows the pane
    /// order the user sees. A caller reporting a single message — the launch
    /// path — needs a stable choice; `Dictionary.values.first` would hand back
    /// a different error run to run for the same configuration.
    func firstValidationError(
        modelProfile: DS4ModelProfile = .unknown,
        supportProfile: DS4SupportProfile = .unavailable,
        visionPathIsValid: Bool? = nil,
        visionProfile: DS4VisionProfile? = nil
    ) -> String? {
        let errors = validationErrors(
            modelProfile: modelProfile,
            supportProfile: supportProfile,
            visionPathIsValid: visionPathIsValid,
            visionProfile: visionProfile
        )
        guard !errors.isEmpty else { return nil }
        return Field.allCases.lazy.compactMap { errors[$0] }.first
    }

    static func isValidSSDCacheExperts(_ value: String) -> Bool {
        DS4NumericTextConstraint(
            syntax: .expertCountOrGiB,
            countMaximum: DS4ConfigurationLimits.maxParserUnsignedInteger,
            gibMaximum: DS4ConfigurationLimits.maxGiB,
            sentinelDescription: "Blank = Automatic",
            source: "ds4 SSD parser"
        ).contains(value)
    }

    static func isValidMemoryBudget(_ value: String) -> Bool {
        DS4NumericTextConstraint(
            syntax: .gib,
            countMaximum: nil,
            gibMaximum: DS4ConfigurationLimits.maxGiB,
            sentinelDescription: "Blank = Off",
            source: "ds4 GiB parser"
        ).contains(value)
    }

    /// Give persisted file selections stable absolute identities and keep
    /// values inside engine ranges when loading an older or manually edited
    /// preference blob. Normal validation still reports other invalid values
    /// so the UI can explain them instead of hiding them.
    func normalized() -> Self {
        var config = self
        config.mtpDraft = min(DS4ConfigurationLimits.maxMTPDraft,
                              max(DS4ConfigurationLimits.minMTPDraft, config.mtpDraft))
        if !config.serverPath.isEmpty {
            config.serverPath = DS4ServerCommand.storingAbsolutePath(config.serverPath)
            let directory = DS4ServerCommand.serverDirectory(for: config.serverPath)
            config.modelPath = DS4ServerCommand.storingResourcePath(
                config.modelPath,
                relativeTo: directory
            )
            config.mtpPath = DS4ServerCommand.storingResourcePath(
                config.mtpPath,
                relativeTo: directory
            )
            config.visionPath = DS4ServerCommand.storingResourcePath(
                config.visionPath,
                relativeTo: directory
            )
        }
        return config
    }

    /// Store the current effective values in the profile for the selected
    /// model. This also migrates a pre-profile configuration on first load.
    func storingCurrentModelProfile(as explicitKey: String? = nil) -> Self {
        var config = self
        let key = explicitKey ?? Self.modelKey(for: modelPath, serverPath: serverPath)
        if !key.isEmpty {
            config.modelProfiles[key] = DS4TuningProfile(configuration: config)
        }
        return config
    }

    /// Return a draft for a newly selected model. Existing settings for that
    /// model are restored; a new model receives that family's defaults.
    func selectingModel(
        path: String,
        serverPath selectedServerPath: String? = nil,
        profile: DS4ModelProfile,
        storingCurrentAs currentKey: String? = nil
    ) -> Self {
        var config = storingCurrentModelProfile(as: currentKey)
        if let selectedServerPath {
            config.serverPath = selectedServerPath
        }
        config.modelPath = path
        let key = Self.modelKey(for: path, serverPath: config.serverPath)
        if let saved = config.modelProfiles[key] {
            saved.applying(to: &config)
        } else if let legacy = Self.legacyModelKey(for: path),
                  legacy != key,
                  let saved = config.modelProfiles[legacy] {
            // Older builds resolved relative profile keys against the app's
            // working directory instead of ds4-server's directory. Copy a
            // matching legacy entry forward, but retain it: it may also be a
            // legitimate absolute-path profile and cannot be removed safely.
            saved.applying(to: &config)
        } else {
            DS4TuningProfile.defaults(for: profile).applying(to: &config)
        }
        config.repairMTPMode(for: profile)
        if !key.isEmpty {
            config.modelProfiles[key] = DS4TuningProfile(configuration: config)
        }
        return config
    }

    /// Discard only a model-specific mode that cannot apply to the newly
    /// selected main model. This repairs profiles written by older builds
    /// without disturbing valid tuning values or the separately remembered
    /// profile for any other model.
    private mutating func repairMTPMode(for profile: DS4ModelProfile) {
        switch profile.family {
        case .deepSeek:
            if mtpMode == .embedded { mtpMode = .off }
        case .qwen38, .glm52, .glm53Full, .glm53Flash, .glm5Full:
            if mtpMode == .external || mtpMode == .dspark ||
                (mtpMode == .embedded && !profile.supportsEmbeddedMTP) {
                mtpMode = .off
            }
        case .deepSeek41:
            mtpMode = .off
        case .supportModel, .unknown:
            if mtpMode != .off { mtpMode = .off }
        }
    }

    /// Canonical identity for a configured model. Relative model paths are
    /// resolved against ds4-server's working directory, matching inspection
    /// and launch rather than the menu app's unrelated working directory.
    static func modelKey(for path: String, serverPath: String) -> String {
        let directory = DS4ServerCommand.serverDirectory(for: serverPath)
        let resolved = DS4ServerCommand.resolving(path, relativeTo: directory)
        guard !resolved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ""
        }
        return URL(fileURLWithPath: resolved).standardizedFileURL.path
    }

    /// Key shape used before server-relative resolution was introduced. This
    /// exists only as a read fallback for persisted profiles.
    private static func legacyModelKey(for path: String) -> String? {
        let expanded = (path as NSString).expandingTildeInPath
        guard !expanded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }
}

// MARK: - Tuning defaults

extension ServerConfiguration.Config {
    /// Return this configuration with ds4-server tuning and feature settings
    /// restored to their built-in defaults. User-selected application, model,
    /// endpoint, resource-path, and diagnostic settings are preserved.
    func restoringTuningDefaults(for profile: DS4ModelProfile = .unknown) -> Self {
        var defaults = Self()
        defaults.serverPath = serverPath
        defaults.modelPath = modelPath
        defaults.host = host
        defaults.port = port
        defaults.corsEnabled = corsEnabled
        defaults.kvDiskDir = kvDiskDir
        defaults.traceEnabled = traceEnabled
        defaults.tracePath = tracePath
        defaults.logPath = logPath
        defaults.logMaxSizeMB = logMaxSizeMB
        defaults.launchAtLogin = launchAtLogin
        defaults.modelProfiles = modelProfiles
        DS4TuningProfile.defaults(for: profile).applying(to: &defaults)
        // Resource paths are user-selected model settings, not tuning values.
        defaults.mtpPath = mtpPath
        defaults.visionPath = visionPath
        let key = Self.modelKey(for: modelPath, serverPath: serverPath)
        if !key.isEmpty {
            defaults.modelProfiles[key] = DS4TuningProfile(configuration: defaults)
        }
        return defaults
    }
}

// MARK: - Lenient Config decoding

extension ServerConfiguration.Config {
    /// Missing keys from older builds fall back to the current defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var cfg = Self()
        cfg.serverPath = try c.decodeIfPresent(String.self, forKey: .serverPath) ?? cfg.serverPath
        cfg.modelPath = try c.decodeIfPresent(String.self, forKey: .modelPath) ?? cfg.modelPath
        cfg.host = try c.decodeIfPresent(String.self, forKey: .host) ?? cfg.host
        cfg.port = try c.decodeIfPresent(Int.self, forKey: .port) ?? cfg.port
        cfg.defaultTokens = try c.decodeIfPresent(Int.self, forKey: .defaultTokens) ?? cfg.defaultTokens
        cfg.ctxSize = try c.decodeIfPresent(Int.self, forKey: .ctxSize) ?? cfg.ctxSize
        cfg.threads = try c.decodeIfPresent(Int.self, forKey: .threads) ?? cfg.threads
        cfg.powerPercent = try c.decodeIfPresent(Int.self, forKey: .powerPercent) ?? cfg.powerPercent
        cfg.prefillChunk = try c.decodeIfPresent(Int.self, forKey: .prefillChunk) ?? cfg.prefillChunk
        cfg.warmWeights = try c.decodeIfPresent(Bool.self, forKey: .warmWeights) ?? cfg.warmWeights
        cfg.quality = try c.decodeIfPresent(Bool.self, forKey: .quality) ?? cfg.quality
        cfg.corsEnabled = try c.decodeIfPresent(Bool.self, forKey: .corsEnabled) ?? cfg.corsEnabled
        cfg.batchedSessions = try c.decodeIfPresent(Int.self, forKey: .batchedSessions) ?? cfg.batchedSessions
        cfg.mixedPrefillQuantum = try c.decodeIfPresent(Int.self, forKey: .mixedPrefillQuantum) ?? cfg.mixedPrefillQuantum
        cfg.ssdStreamingEnabled = try c.decodeIfPresent(Bool.self, forKey: .ssdStreamingEnabled) ?? cfg.ssdStreamingEnabled
        cfg.ssdStreamingCold = try c.decodeIfPresent(Bool.self, forKey: .ssdStreamingCold) ?? cfg.ssdStreamingCold
        cfg.ssdStreamingCacheExperts = try c.decodeIfPresent(String.self, forKey: .ssdStreamingCacheExperts) ?? cfg.ssdStreamingCacheExperts
        cfg.ssdStreamingFullLayers = try c.decodeIfPresent(Int.self, forKey: .ssdStreamingFullLayers) ?? cfg.ssdStreamingFullLayers
        cfg.ssdStreamingPreloadExperts = try c.decodeIfPresent(Int.self, forKey: .ssdStreamingPreloadExperts) ?? cfg.ssdStreamingPreloadExperts
        cfg.kvDiskEnabled = try c.decodeIfPresent(Bool.self, forKey: .kvDiskEnabled) ?? cfg.kvDiskEnabled
        cfg.kvDiskDir = try c.decodeIfPresent(String.self, forKey: .kvDiskDir) ?? cfg.kvDiskDir
        cfg.kvDiskSpaceMB = try c.decodeIfPresent(Int.self, forKey: .kvDiskSpaceMB) ?? cfg.kvDiskSpaceMB
        cfg.kvCacheMinTokens = try c.decodeIfPresent(Int.self, forKey: .kvCacheMinTokens) ?? cfg.kvCacheMinTokens
        cfg.kvCacheColdMaxTokens = try c.decodeIfPresent(Int.self, forKey: .kvCacheColdMaxTokens) ?? cfg.kvCacheColdMaxTokens
        cfg.kvCacheContinuedIntervalTokens = try c.decodeIfPresent(Int.self, forKey: .kvCacheContinuedIntervalTokens) ?? cfg.kvCacheContinuedIntervalTokens
        cfg.kvCacheBoundaryTrimTokens = try c.decodeIfPresent(Int.self, forKey: .kvCacheBoundaryTrimTokens) ?? cfg.kvCacheBoundaryTrimTokens
        cfg.kvCacheBoundaryAlignTokens = try c.decodeIfPresent(Int.self, forKey: .kvCacheBoundaryAlignTokens) ?? cfg.kvCacheBoundaryAlignTokens
        cfg.kvCacheRejectDifferentQuant = try c.decodeIfPresent(Bool.self, forKey: .kvCacheRejectDifferentQuant) ?? cfg.kvCacheRejectDifferentQuant
        cfg.disableExactDSMLToolReplay = try c.decodeIfPresent(Bool.self, forKey: .disableExactDSMLToolReplay) ?? cfg.disableExactDSMLToolReplay
        cfg.toolMemoryMaxIDs = try c.decodeIfPresent(Int.self, forKey: .toolMemoryMaxIDs) ?? cfg.toolMemoryMaxIDs
        cfg.mtpPath = try c.decodeIfPresent(String.self, forKey: .mtpPath) ?? cfg.mtpPath
        cfg.qwenMTPDepth = try c.decodeIfPresent(QwenMTPDepth.self, forKey: .qwenMTPDepth) ?? cfg.qwenMTPDepth
        cfg.qwenYarnFactor = try c.decodeIfPresent(QwenYarnFactor.self, forKey: .qwenYarnFactor) ?? cfg.qwenYarnFactor
        cfg.qwenImageMaxTokens = try c.decodeIfPresent(Int.self, forKey: .qwenImageMaxTokens) ?? cfg.qwenImageMaxTokens
        cfg.mtpDraft = try c.decodeIfPresent(Int.self, forKey: .mtpDraft) ?? cfg.mtpDraft
        cfg.mtpMargin = try c.decodeIfPresent(Double.self, forKey: .mtpMargin) ?? cfg.mtpMargin
        if let mode = try c.decodeIfPresent(MTPMode.self, forKey: .mtpMode) {
            cfg.mtpMode = mode
        } else if let oldEnabled = try decoder.container(keyedBy: LegacyCodingKey.self)
            .decodeIfPresent(Bool.self, forKey: .mtpEnabled) {
            // Before model-aware profiles, true meant an external support
            // model. Preserve that meaning while correcting the command shape.
            cfg.mtpMode = oldEnabled ? .external : .off
        }
        cfg.visionPath = try c.decodeIfPresent(String.self, forKey: .visionPath) ?? cfg.visionPath
        cfg.visionEnabled = try c.decodeIfPresent(Bool.self, forKey: .visionEnabled)
            ?? !cfg.visionPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        cfg.mtpTiming = try c.decodeIfPresent(Bool.self, forKey: .mtpTiming) ?? cfg.mtpTiming
        cfg.mtpExactSampling = try c.decodeIfPresent(Bool.self, forKey: .mtpExactSampling) ?? cfg.mtpExactSampling
        if c.contains(.dsparkConfidence) {
            cfg.dsparkConfidence = try c.decode(Double?.self, forKey: .dsparkConfidence)
        }
        cfg.dsparkStrict = try c.decodeIfPresent(Bool.self, forKey: .dsparkStrict) ?? cfg.dsparkStrict
        cfg.simulateUsedMemory = try c.decodeIfPresent(String.self, forKey: .simulateUsedMemory) ?? cfg.simulateUsedMemory
        cfg.modelProfiles = try c.decodeIfPresent([String: DS4TuningProfile].self, forKey: .modelProfiles) ?? cfg.modelProfiles
        if let savedTracePath = try c.decodeIfPresent(String.self, forKey: .tracePath) {
            let wasEnabled = !savedTracePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            cfg.tracePath = wasEnabled ? savedTracePath : cfg.tracePath
            cfg.traceEnabled = try c.decodeIfPresent(Bool.self, forKey: .traceEnabled) ?? wasEnabled
        } else {
            cfg.traceEnabled = try c.decodeIfPresent(Bool.self, forKey: .traceEnabled)
                ?? cfg.traceEnabled
        }
        cfg.logPath = try c.decodeIfPresent(String.self, forKey: .logPath) ?? cfg.logPath
        cfg.logMaxSizeMB = try c.decodeIfPresent(Int.self, forKey: .logMaxSizeMB) ?? cfg.logMaxSizeMB
        cfg.launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? cfg.launchAtLogin
        self = cfg
    }

    private enum LegacyCodingKey: String, CodingKey {
        case mtpEnabled
    }
}
