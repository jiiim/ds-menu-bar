// SPDX-FileCopyrightText: Copyright James Martin and DS Menu Bar contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Builds the supported local Metal `ds4-server` invocation.
///
/// Keeping this separate from `ProcessManager` makes the exact argument set
/// visible to Settings and unit-testable without launching a model process.
enum DS4ServerCommand {
    static let managedQwenEnvironmentKeys = [
        "DS4_QWEN4_MTP_DEPTH",
        "DS4_QWEN4_YARN_FACTOR",
        "DS4_QWEN4_IMAGE_MAX_TOKENS"
    ]

    static func environmentOverrides(
        configuration: ServerConfiguration.Config,
        modelProfile: DS4ModelProfile = .unknown
    ) -> [String: String] {
        guard modelProfile.family == .qwen38 else { return [:] }
        var environment: [String: String] = [:]
        if configuration.mtpMode == .embedded && modelProfile.supportsEmbeddedMTP {
            environment["DS4_QWEN4_MTP_DEPTH"] = configuration.qwenMTPDepth.environmentValue
        }
        if let value = configuration.qwenYarnFactor.environmentValue {
            environment["DS4_QWEN4_YARN_FACTOR"] = value
        }
        if configuration.visionEnabled && modelProfile.supportsVision {
            environment["DS4_QWEN4_IMAGE_MAX_TOKENS"] = "\(configuration.qwenImageMaxTokens)"
        }
        return environment
    }

    static func launchEnvironment(
        configuration: ServerConfiguration.Config,
        modelProfile: DS4ModelProfile = .unknown,
        inheriting base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = base
        for key in managedQwenEnvironmentKeys {
            environment.removeValue(forKey: key)
        }
        environment.merge(environmentOverrides(
            configuration: configuration,
            modelProfile: modelProfile
        )) { _, configured in configured }
        return environment
    }

    static func arguments(
        configuration: ServerConfiguration.Config,
        resolvedModelPath: String,
        resolvedMTPPath: String,
        resolvedVisionPath: String = "",
        modelProfile: DS4ModelProfile = .unknown,
        supportProfile: DS4SupportProfile = .unavailable,
        visionProfile: DS4VisionProfile? = nil
    ) -> [String] {
        var args: [String] = [
            "--metal",
            "--model", resolvedModelPath
        ]
        args += [
            "--ctx", "\(configuration.ctxSize)",
            "--host", normalizedHost(configuration.host),
            "--port", "\(configuration.port)",
            "--power", "\(configuration.powerPercent)"
        ]

        if configuration.defaultTokens > 0 {
            args += ["--tokens", "\(configuration.defaultTokens)"]
        }
        if configuration.threads > 0 {
            args += ["--threads", "\(configuration.threads)"]
        }
        if modelProfile.supportsManualPrefill && configuration.prefillChunk > 0 {
            args += ["--prefill-chunk", "\(configuration.prefillChunk)"]
        }
        if configuration.warmWeights {
            args.append("--warm-weights")
        }
        if configuration.quality {
            args.append("--quality")
        }

        if configuration.corsEnabled {
            args.append("--cors")
        }
        if configuration.traceEnabled,
           configuration.tracePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            args += ["--trace", expandingTilde(configuration.tracePath)]
        }
        if configuration.batchedSessions > 0 {
            args += ["--batched-session", "\(configuration.batchedSessions)"]
            if configuration.mixedPrefillQuantum > 0 {
                args += ["--mixed-prefill-quantum", "\(configuration.mixedPrefillQuantum)"]
            }
        }

        if configuration.ssdStreamingEnabled && modelProfile.supportsSSDStreaming {
            args.append("--ssd-streaming")
            if configuration.ssdStreamingCold {
                args.append("--ssd-streaming-cold")
            }
            let cacheExperts = configuration.ssdStreamingCacheExperts
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !cacheExperts.isEmpty {
                args += ["--ssd-streaming-cache-experts", cacheExperts]
            }
            if modelProfile.isFullGLM && configuration.ssdStreamingFullLayers >= 0 {
                args += ["--ssd-streaming-full-layers", "\(configuration.ssdStreamingFullLayers)"]
            }
            if configuration.ssdStreamingPreloadExperts > 0 {
                args += ["--ssd-streaming-preload-experts", "\(configuration.ssdStreamingPreloadExperts)"]
            }
        }

        if configuration.kvDiskEnabled {
            args += [
                "--kv-disk-dir", expandingTilde(configuration.kvDiskDir),
                "--kv-disk-space-mb", "\(configuration.kvDiskSpaceMB)",
                "--kv-cache-min-tokens", "\(configuration.kvCacheMinTokens)",
                "--kv-cache-cold-max-tokens", "\(configuration.kvCacheColdMaxTokens)",
                "--kv-cache-continued-interval-tokens", "\(configuration.kvCacheContinuedIntervalTokens)",
                "--kv-cache-boundary-trim-tokens", "\(configuration.kvCacheBoundaryTrimTokens)",
                "--kv-cache-boundary-align-tokens", "\(configuration.kvCacheBoundaryAlignTokens)",
                "--tool-memory-max-ids", "\(configuration.toolMemoryMaxIDs)"
            ]
            if configuration.kvCacheRejectDifferentQuant {
                args.append("--kv-cache-reject-different-quant")
            }
            if configuration.disableExactDSMLToolReplay {
                args.append("--disable-exact-dsml-tool-replay")
            }
        }

        if configuration.simulateUsedMemory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            args += ["--simulate-used-memory", configuration.simulateUsedMemory.trimmingCharacters(in: .whitespacesAndNewlines)]
        }

        if modelProfile.supportsVision && configuration.visionEnabled && !resolvedVisionPath.isEmpty &&
            (visionProfile?.isCompatible(with: modelProfile) ?? true) {
            args += ["--vision", resolvedVisionPath]
        }

        switch configuration.mtpMode {
        case .off:
            break
        case .embedded where modelProfile.supportsEmbeddedMTP:
            args.append("--mtp")
            if configuration.mtpTiming { args.append("--mtp-timing") }
            if configuration.mtpExactSampling { args.append("--mtp-exact-sampling") }
        case .external where modelProfile.supportsExternalMTP && supportProfile.kind == .legacyMTP:
            args += [
                "--mtp-model", resolvedMTPPath,
                "--mtp-draft", "\(configuration.mtpDraft)",
                "--mtp-margin", format(configuration.mtpMargin)
            ]
        case .dspark where modelProfile.supportsDSpark && supportProfile.kind == .dspark:
            args += ["--mtp-model", resolvedMTPPath, "--dspark"]
            if let confidence = configuration.dsparkConfidence {
                args += ["--dspark-confidence", format(confidence)]
            }
            if configuration.mtpExactSampling { args.append("--mtp-exact-sampling") }
            if configuration.dsparkStrict { args.append("--dspark-strict") }
        default:
            // An unknown or incompatible profile must never receive flags for
            // another model family. ds4-server remains free to decide whether
            // the base model itself is supported.
            break
        }

        return args
    }

    /// Human-readable shell-style preview used by Settings. This is a display
    /// string, not a shell command executed by the app.
    static func preview(
        configuration: ServerConfiguration.Config,
        modelProfile: DS4ModelProfile = .unknown,
        supportProfile: DS4SupportProfile = .unavailable,
        visionProfile: DS4VisionProfile? = nil
    ) -> String {
        let serverPath = expandingTilde(configuration.serverPath)
        let directory = serverDirectory(for: configuration.serverPath)
        let args = arguments(
            configuration: configuration,
            resolvedModelPath: resolving(configuration.modelPath, relativeTo: directory),
            resolvedMTPPath: resolving(configuration.mtpPath, relativeTo: directory),
            resolvedVisionPath: resolving(configuration.visionPath, relativeTo: directory),
            modelProfile: modelProfile,
            supportProfile: supportProfile,
            visionProfile: visionProfile
        )
        let environment = environmentOverrides(
            configuration: configuration,
            modelProfile: modelProfile
        )
        let assignments = managedQwenEnvironmentKeys.compactMap { key -> String? in
            guard let value = environment[key] else { return nil }
            return "\(key)=\(shellQuote(value))"
        }
        // Keep the shell preview's environment aligned with Process.environment:
        // managed Qwen variables are removed even when the selected model is not
        // Qwen, and only Qwen models receive configured assignments.
        var environmentPrefix = ["/usr/bin/env"]
        for key in managedQwenEnvironmentKeys where environment[key] == nil {
            environmentPrefix += ["-u", key]
        }
        environmentPrefix += assignments
        let command = (environmentPrefix + ([serverPath] + args).map(shellQuote)).joined(separator: " ")
        let log = shellQuote(expandingTilde(configuration.logPath))
        return "\(command) > \(log) 2>&1"
    }

    static func expandingTilde(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    /// Normalize redundant separators and dot components without turning a
    /// relative path into an absolute one. Storage and presentation policies
    /// are applied separately by the helpers below.
    static func normalizingPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        if trimmed.hasPrefix("/") {
            return (trimmed as NSString).standardizingPath
        }
        if trimmed == "~" || trimmed.hasPrefix("~/") {
            let standardized = (trimmed as NSString).standardizingPath
            return (standardized as NSString).abbreviatingWithTildeInPath
        }

        var components: [Substring] = []
        for component in trimmed.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case ".." where components.last.map({ $0 != ".." }) == true:
                components.removeLast()
            default:
                components.append(component)
            }
        }
        return components.isEmpty ? "." : components.joined(separator: "/")
    }

    /// Store an executable path independently of the app's current directory.
    static func storingAbsolutePath(_ path: String) -> String {
        let normalized = normalizingPath(path)
        guard !normalized.isEmpty else { return normalized }
        let expanded = expandingTilde(normalized)
        if expanded.hasPrefix("/") {
            return normalizingPath(expanded)
        }
        return normalizingPath(
            (FileManager.default.currentDirectoryPath as NSString)
                .appendingPathComponent(expanded)
        )
    }

    /// Store a GGUF independently of later changes to ds4-server's directory.
    static func storingResourcePath(
        _ path: String,
        relativeTo directory: String
    ) -> String {
        let normalized = normalizingPath(path)
        guard !normalized.isEmpty else { return normalized }
        return normalizingPath(resolving(normalized, relativeTo: directory))
    }

    /// Recombine a chosen folder with a file name. The folder comes from a
    /// panel and the name from a text field, because a file the app has yet to
    /// create cannot be selected.
    static func storingFilePath(directory: String, name: String) -> String {
        let folder = normalizingPath(directory)
        let file = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !file.isEmpty else { return folder }
        guard !folder.isEmpty else { return normalizingPath(file) }
        return normalizingPath((folder as NSString).appendingPathComponent(file))
    }

    /// The folder a stored file path lives in, for the row that picks it.
    static func fileDirectory(of path: String) -> String {
        (normalizingPath(path) as NSString).deletingLastPathComponent
    }

    /// The name a stored file path ends with, for the row that edits it.
    static func fileName(of path: String) -> String {
        (normalizingPath(path) as NSString).lastPathComponent
    }

    /// Present a stored path compactly without changing its identity.
    static func presentingPath(_ path: String) -> String {
        let normalized = normalizingPath(path)
        guard normalized.hasPrefix("/") else { return normalized }
        return (normalized as NSString).abbreviatingWithTildeInPath
    }

    /// Present a GGUF relative to ds4-server when it is inside the server's
    /// working directory. Resources elsewhere use an absolute or `~/` form.
    static func presentingResourcePath(
        _ path: String,
        relativeTo directory: String
    ) -> String {
        let normalized = normalizingPath(path)
        guard !normalized.isEmpty,
              normalized.hasPrefix("/") || normalized == "~" || normalized.hasPrefix("~/"),
              !directory.isEmpty
        else { return normalized }

        let absolute = (expandingTilde(normalized) as NSString).standardizingPath
        let base = (expandingTilde(directory) as NSString).standardizingPath
        let absoluteComponents = (absolute as NSString).pathComponents
        let baseComponents = (base as NSString).pathComponents
        guard absoluteComponents.count > baseComponents.count,
              Array(absoluteComponents.prefix(baseComponents.count)) == baseComponents
        else { return presentingPath(normalized) }

        return absoluteComponents.dropFirst(baseComponents.count).joined(separator: "/")
    }

    /// The working directory a launched ds4-server inherits: the folder holding
    /// the executable.
    static func serverDirectory(for serverPath: String) -> String {
        (expandingTilde(serverPath) as NSString).deletingLastPathComponent
    }

    /// Resolve a configured resource path the way the launched server sees it.
    /// ds4-server runs with `serverDirectory` as its working directory, so a
    /// relative configuration path means "relative to that directory" — the
    /// shipped default `mtpPath` relies on this. Launch and the Settings
    /// preview both resolve here so the previewed command is the command that
    /// runs. An empty path stays empty; callers treat that as "not configured".
    static func resolving(_ path: String, relativeTo directory: String) -> String {
        let expanded = expandingTilde(path)
        guard !expanded.isEmpty, !expanded.hasPrefix("/"), !directory.isEmpty else {
            return expanded
        }
        return (directory as NSString).appendingPathComponent(expanded)
    }

    /// Render a Double for the command line. `arguments` is also called on
    /// unvalidated Settings drafts (the live command preview), so this has to
    /// survive non-finite and out-of-Int-range values rather than trapping in
    /// `Int(_:)`. Such a value is shown as-is rather than substituted: the
    /// preview's job is to reflect what the draft says, and a rejected margin
    /// rendered as a plausible "0" would read as if it were fine. Validation
    /// stops it from reaching an actual launch.
    static func format(_ value: Double) -> String {
        guard value.isFinite, value.magnitude < 1e15, value.rounded() == value else {
            return String(value)
        }
        return String(Int(value))
    }

    /// The configured host reduced to the bare form a socket expects.
    ///
    /// The Settings host field is free text, so an IPv6 address can arrive in
    /// its URL spelling, `[::]`. Brackets are URL syntax for separating the
    /// address from the port — they are not part of the address, and
    /// `getaddrinfo` rejects them with `EAI_NONAME`. Left in place they make
    /// the pre-relaunch port wait skip silently (an unresolvable host reads as
    /// "port free"), and they reach `--host` as a spelling ds4-server has no
    /// reason to accept. Strip them once, here, so everything downstream of
    /// the configuration sees a single spelling.
    static func normalizedHost(_ configuredHost: String) -> String {
        guard configuredHost.count > 2,
              configuredHost.hasPrefix("["), configuredHost.hasSuffix("]") else {
            return configuredHost
        }
        return String(configuredHost.dropFirst().dropLast())
    }

    /// The URL host component to probe for readiness, given the configured
    /// bind host.
    ///
    /// A wildcard bind address tells ds4-server to listen on every interface,
    /// but it is not a connectable destination: CFNetwork rejects `0.0.0.0`
    /// before the request leaves the process (`NSURLErrorBadURL`), and the
    /// IPv6 wildcard builds a valid URL that never connects. Either way the
    /// probe fails for as long as the server runs, and because a failing probe
    /// during startup means "still loading", the menu stays on "Starting…"
    /// against a server that is healthy and serving. A wildcard listener
    /// accepts loopback too, so probe that instead.
    ///
    /// The wildcard is recognised by parsing the address rather than matching
    /// text. `::`, `[::]`, `[::0]`, and `[0:0:0:0:0:0:0:0]` are one address
    /// written four ways, and a list of literals only ever covers the
    /// spellings someone thought to write down.
    ///
    /// The result is a URL host component, so IPv6 comes back bracketed —
    /// `URLComponents.host` yields a nil URL for a bare `::1`. Never hand it
    /// to `getaddrinfo`; `normalizedHost(_:)` is the bare form.
    static func healthProbeURLHost(for configuredHost: String) -> String {
        let bare = normalizedHost(configuredHost)

        var v4 = in_addr()
        if inet_pton(AF_INET, bare, &v4) == 1 {
            return v4.s_addr == 0 ? "127.0.0.1" : bare
        }

        var v6 = in6_addr()
        if inet_pton(AF_INET6, bare, &v6) == 1 {
            let octets = withUnsafeBytes(of: v6) { Array($0) }
            if octets.allSatisfy({ $0 == 0 }) {
                return "[::1]"
            }
            // ::ffff:0.0.0.0 is the same wildcard wearing an IPv4-mapped
            // prefix, and CFNetwork rejects it exactly as it rejects a bare
            // 0.0.0.0 (`NSURLErrorBadURL`). Such a listener answers on the
            // IPv4 loopback, so that is the address to probe.
            let isIPv4Mapped = octets[0..<10].allSatisfy { $0 == 0 }
                && octets[10] == 0xff && octets[11] == 0xff
            if isIPv4Mapped && octets[12...].allSatisfy({ $0 == 0 }) {
                return "127.0.0.1"
            }
            return "[\(bare)]"
        }

        // A name, not an address. Resolution decides where it points, and a
        // name never denotes the unspecified address — but it still comes back
        // in the one spelling `normalizedHost(_:)` promises.
        return bare
    }

    private static func shellQuote(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        if value.rangeOfCharacter(from: CharacterSet(charactersIn: " \t\n'\"\\$`|;&<>*?!()[]{}")) == nil {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
