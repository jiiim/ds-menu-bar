// SPDX-FileCopyrightText: Copyright James Martin and DS Menu Bar contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Settings pane bodies
//
// The per-pane Forms and the row builders they share. Split from the view's
// state machine so each file has one job: this one renders, SettingsWindow.swift
// decides.

extension SettingsView {
    // MARK: Panes

    var generalPane: some View {
        Form {
            paneIntro(
                "DS Menu Bar",
                "Configure the local Apple silicon Metal server managed by this app."
            )

            Section("Application") {
                Toggle("Launch at login", isOn: launchAtLoginBinding)
                    .help("Changes take effect immediately.")
                Toggle(
                    "Show Prefill and Generation speeds in menu bar",
                    isOn: performanceDisplayBinding
                )
                .help("Displays P for Prefill and G for Generation token rates.")
                Toggle(
                    "Keep Mac awake while the server is running",
                    isOn: keepAwakeBinding
                )
                .help(
                    "Only when connected to a power adapter. The display still "
                    + "sleeps, and closing the lid or sleeping from the Apple "
                    + "menu still sleeps the Mac."
                )
                LabeledContent("Platform") {
                    Text("macOS • Apple silicon • Metal")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Command preview") {
                Text(DS4ServerCommand.preview(
                    configuration: draft,
                    modelProfile: modelProfile,
                    supportProfile: supportProfile,
                    visionProfile: visionProfile
                ))
                    .font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    // Selectable text here goes blank after the selection
                    // loses focus, so the command is copied whole instead.
                    .contextMenu {
                        Button("Copy Command") { copyCommandPreview() }
                    }
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Button("Restore All Tuning Defaults", role: .destructive) {
                        draft = draft.restoringTuningDefaults(for: modelProfile)
                        showNotice("Tuning defaults restored for \(modelProfile.displayName) in this draft. Apply to use them.")
                    }
                    Text("Restores tuning and feature settings for the selected model while preserving its model paths and the app's General, Server, and Diagnostics settings. Changes take effect only after Apply.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    var modelPane: some View {
        Form {
            paneIntro(
                "Model",
                "Choose the executable and main GGUF for one local Metal ds4-server on this Mac."
            )

            Section("Files") {
                pathRow(
                    "ds4-server",
                    field: .server,
                    errorKey: .serverPath,
                    help: "The ds4-server executable"
                )
                pathRow("Model", field: .model, errorKey: .modelPath, help: "The main GGUF model")
            }

            Section("Detected model") {
                LabeledContent("Type") {
                    Text(modelProfile.displayName)
                        .foregroundStyle(modelProfile.isKnown ? Color.secondary : Color.orange)
                }
                if let architecture = modelProfile.architecture {
                    LabeledContent("GGUF architecture") {
                        Text(architecture).font(.system(.body, design: .monospaced))
                    }
                }
                if modelProfile.isSupportArtifact {
                    Label("\(modelProfile.displayName) is not a main model. Choose the main model GGUF here and use this file in its appropriate settings pane.", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                } else if !modelProfile.isKnown {
                    Label("Model-specific options are unavailable until the GGUF architecture is recognized. Common server options remain usable.", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                if modelProfile.supportsVision {
                    Toggle("Use vision encoder", isOn: $draft.visionEnabled)
                    pathRow("Vision encoder", field: .vision, errorKey: .visionPath, help: visionHelp)
                    if modelProfile.family == .qwen38 && draft.visionEnabled {
                        integerRow(
                            "Maximum image tokens",
                            value: $draft.qwenImageMaxTokens,
                            errorKey: .qwenImageMaxTokens,
                            note: "DS4_QWEN4_IMAGE_MAX_TOKENS controls the Qwen vision resize budget."
                        )
                    }
                }
                if modelProfile.family == .qwen38 {
                    LabeledContent("Original BF16 n-grams") {
                        Text(modelProfile.hasNativeQwenNGrams == true ? "Included in model" : "Not detected")
                            .foregroundStyle(modelProfile.hasNativeQwenNGrams == true ? Color.secondary : Color.orange)
                    }
                    Text(modelProfile.hasNativeQwenNGrams == true
                         ? "Current ds4 reads the n-gram table directly from the self-contained GGUF. Keep the model on a fast local SSD."
                         : "ds4-server will validate the selected Qwen GGUF when it starts.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if modelProfile.family == .deepSeek41 {
                    Text("Engram is included in the main GGUF and remains disk backed. Keep the model on a fast local SSD.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Working directory") {
                Text("The server runs with the executable's directory as its working directory. Relative vision and MTP paths resolve from there.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    var serverPane: some View {
        Form {
            paneIntro(
                "Server",
                "Configure the local HTTP endpoint and how many independent clients can be resident."
            )

            Section("HTTP endpoint") {
                textRow("Host", text: $draft.host, errorKey: .host)
                integerRow("Port", value: $draft.port, errorKey: .port, grouped: false)
                Toggle("Allow browser clients (CORS)", isOn: $draft.corsEnabled)
            }

            Section("Requests") {
                integerRow(
                    "Default output tokens",
                    value: $draft.defaultTokens,
                    errorKey: .defaultTokens,
                    note: "0 uses ds4-server's default."
                )
                integerRow(
                    "Resident sessions",
                    value: $draft.batchedSessions,
                    errorKey: .batchedSessions,
                    note: "0 disables session batching. Each session keeps its own caches, so more sessions multiply context memory; supported models share one prefill workspace."
                )
                if draft.batchedSessions > 0 {
                    integerRow(
                        "Mixed prefill quantum",
                        value: $draft.mixedPrefillQuantum,
                        errorKey: .mixedPrefillQuantum,
                        note: "The amount of prompt work allowed between active generations."
                    )
                    if mayExceedBatchedMTPDecodeWidth {
                        Text("ds4-server speculates across at most \(ServerConfiguration.Config.maxBatchedEmbeddedMTPDecodeWidth) sessions decoding at once. MTP still applies beyond that, one session at a time.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    var performancePane: some View {
        Form {
            paneIntro(
                "Performance",
                "Tune the unified memory, local SSD use, throughput, and sustained power of this Mac."
            )

            Section("Context") {
                if modelProfile.family == .qwen38 {
                    Picker("Qwen YaRN extension", selection: $draft.qwenYarnFactor) {
                        ForEach(QwenYarnFactor.allCases, id: \.self) { factor in
                            Text(factor.title).tag(factor)
                        }
                    }
                    Text("DS4_QWEN4_YARN_FACTOR extends the native 262,144-token context. It can reduce quality on shorter prompts.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                integerRow(
                    "Context size",
                    value: $draft.ctxSize,
                    errorKey: .ctxSize,
                    note: "Larger contexts require more memory. Think Max requires at least 393,216 tokens."
                )
                if modelProfile.supportsManualPrefill {
                    integerRow(
                        "Prefill chunk",
                        value: $draft.prefillChunk,
                        errorKey: .prefillChunk,
                        note: "0 uses the model/backend default."
                    )
                } else {
                    LabeledContent("Prefill chunk") { Text("Automatic").foregroundStyle(.secondary) }
                    Text("The selected model's Metal graph chooses its prefill capacity.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Metal") {
                LabeledContent("GPU power limit") {
                    if modelProfile.requiresFullPower {
                        HStack(spacing: 10) {
                            Text("100% required").foregroundStyle(.secondary)
                            if draft.powerPercent != 100 {
                                Button("Set to 100%") { draft.powerPercent = 100 }
                            }
                        }
                    } else {
                        let constraint = draft.integerConstraint(for: .powerPercent, modelProfile: modelProfile)
                        HStack(spacing: 10) {
                            Slider(
                                value: powerBinding,
                                in: Double(constraint?.minimum ?? 1)...Double(constraint?.maximum ?? 100),
                                step: Double(constraint?.step ?? 1)
                            )
                                .frame(minWidth: 180)
                            Text("\(draft.powerPercent)%")
                                .monospacedDigit()
                                .frame(width: 42, alignment: .trailing)
                        }
                    }
                }
                if let error = validationErrors[.powerPercent] {
                    validationLabel(error)
                }
                integerRow(
                    "CPU helper threads",
                    value: $draft.threads,
                    errorKey: .threads,
                    note: "0 uses automatic behavior. This affects host-side/reference work, not Metal shader parallelism."
                )
                Toggle("Warm model weights at startup", isOn: $draft.warmWeights)
                Toggle("Prefer exact kernels", isOn: $draft.quality)
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    if modelProfile.supportsSSDStreaming {
                        Toggle("Use SSD-backed model streaming", isOn: $draft.ssdStreamingEnabled)
                    } else {
                        LabeledContent("SSD-backed model streaming") {
                            Text("Unavailable for \(modelProfile.displayName)").foregroundStyle(.secondary)
                        }
                    }
                    Text(modelProfile.isFullGLM
                         ? "Automatic SSD streaming is the recommended starting point for full GLM on a 128 GB Mac. Context and expert caches share unified memory with macOS and other processes."
                         : "SSD streaming uses this Mac's local storage for models that do not fit comfortably in available unified memory.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let error = validationErrors[.ssdStreamingEnabled] {
                        validationLabel(error)
                    }
                }
                if !modelProfile.supportsSSDStreaming && draft.ssdStreamingEnabled {
                    Button("Turn Off SSD Streaming") { draft.ssdStreamingEnabled = false }
                }
                if draft.ssdStreamingEnabled {
                    Toggle("Skip the default expert-cache preload", isOn: $draft.ssdStreamingCold)
                    textRow(
                        "Expert cache override",
                        text: $draft.ssdStreamingCacheExperts,
                        errorKey: .ssdStreamingCacheExperts,
                        note: ssdCacheHelp
                    )
                    if modelProfile.isFullGLM {
                        integerRow(
                            "Full resident layers",
                            value: $draft.ssdStreamingFullLayers,
                            errorKey: .ssdStreamingFullLayers,
                            note: "-1 uses Automatic; 0 disables full-layer residency."
                        )
                    }
                    integerRow(
                        "Preloaded experts",
                        value: $draft.ssdStreamingPreloadExperts,
                        errorKey: .ssdStreamingPreloadExperts,
                        note: "0 uses Automatic."
                    )
                }
            } header: {
                Text("SSD streaming")
            }
        }
    }

    var kvCachePane: some View {
        Form {
            paneIntro(
                "KV Cache",
                "Disk KV checkpoints let later prompts and restarted sessions reuse compatible prefixes."
            )

            Section("Disk cache") {
                Toggle("Enable disk KV cache", isOn: $draft.kvDiskEnabled)
                if draft.kvDiskEnabled {
                    pathRow("Cache directory", field: .kvDiskDirectory, errorKey: .kvDiskDir, help: "DS Menu Bar creates this private directory if needed")
                    integerRow("Disk budget (MB)", value: $draft.kvDiskSpaceMB, errorKey: .kvDiskSpaceMB)
                }
            }

            if draft.kvDiskEnabled {
                Section("Checkpoint policy") {
                    integerRow(
                        "Minimum cache tokens",
                        value: $draft.kvCacheMinTokens,
                        errorKey: .kvCacheMinTokens,
                        note: "Checkpoints shorter than this are not saved or loaded."
                    )
                    integerRow(
                        "Cold-cache maximum tokens",
                        value: $draft.kvCacheColdMaxTokens,
                        errorKey: .kvCacheColdMaxTokens,
                        note: "0 disables cold first-prompt saves; otherwise it must be at least the minimum."
                    )
                    integerRow(
                        "Continued interval tokens",
                        value: $draft.kvCacheContinuedIntervalTokens,
                        errorKey: .kvCacheContinuedIntervalTokens,
                        note: "0 disables aligned continued-frontier saves."
                    )
                    integerRow(
                        "Boundary trim tokens",
                        value: $draft.kvCacheBoundaryTrimTokens,
                        errorKey: .kvCacheBoundaryTrimTokens
                    )
                    integerRow(
                        "Boundary alignment tokens",
                        value: $draft.kvCacheBoundaryAlignTokens,
                        errorKey: .kvCacheBoundaryAlignTokens,
                        note: "0 disables boundary alignment."
                    )
                }

                Section("Compatibility") {
                    Toggle("Reject checkpoints from a different quantization", isOn: $draft.kvCacheRejectDifferentQuant)
                    Toggle("Disable exact DSML tool replay", isOn: $draft.disableExactDSMLToolReplay)
                    integerRow(
                        "Tool-memory limit",
                        value: $draft.toolMemoryMaxIDs,
                        errorKey: .toolMemoryMaxIDs,
                        note: "Maximum exact tool-call IDs retained in memory."
                    )
                }
            }
        }
    }

    var mtpPane: some View {
        Form {
            paneIntro(
                "MTP",
                "MTP is optional speculative decoding. The available controls follow the selected GGUF's capabilities."
            )

            if modelProfile.supportsEmbeddedMTP {
                Section("Embedded MTP") {
                    Toggle("Enable embedded MTP", isOn: embeddedMTPBinding)
                    if draft.mtpMode == .embedded {
                        Text(embeddedMTPDraftDescription)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if modelProfile.family == .qwen38 {
                            Picker("Draft depth", selection: $draft.qwenMTPDepth) {
                                ForEach(QwenMTPDepth.allCases, id: \.self) { depth in
                                    Text(depth.title).tag(depth)
                                }
                            }
                            Text("Sets DS4_QWEN4_MTP_DEPTH to 0, 2, or 3. Automatic selects one or two draft tokens from recent acceptance.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Toggle("Record MTP timing", isOn: $draft.mtpTiming)
                        Toggle("Use exact sampling", isOn: $draft.mtpExactSampling)
                    }
                }
            } else if modelProfile.supportsExternalMTP {
                Section("Speculative decoding") {
                    Picker("Mode", selection: $draft.mtpMode) {
                        Text(MTPMode.off.title).tag(MTPMode.off)
                        Text(MTPMode.dspark.title).tag(MTPMode.dspark)
                        Text(MTPMode.external.title).tag(MTPMode.external)
                    }
                    if draft.mtpMode == .external {
                        pathRow("Legacy MTP model", field: .mtp, errorKey: .mtpPath, help: "A legacy DeepSeek MTP support GGUF")
                        supportModelStatus(expected: .legacyMTP)
                        mtpDraftRows
                    } else if draft.mtpMode == .dspark {
                        pathRow("DSpark model", field: .mtp, errorKey: .mtpPath, help: "The DSpark support GGUF")
                        supportModelStatus(expected: .dspark)
                        Toggle("Automatic confidence threshold", isOn: dsparkAutomaticConfidenceBinding)
                        if draft.dsparkConfidence == nil {
                            Text("ds4-server selects 0.6 for greedy decoding and 0.8 for stochastic exact sampling.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            decimalRow(
                                "Confidence threshold",
                                value: dsparkConfidenceBinding,
                                errorKey: .dsparkConfidence,
                                note: "An explicit override from 0 through 1."
                            )
                        }
                        Toggle("Use exact sampling", isOn: $draft.mtpExactSampling)
                        Toggle("Strict DSpark mode", isOn: $draft.dsparkStrict)
                    }
                    if let error = validationErrors[.mtpMode] {
                        validationLabel(error)
                    }
                }
            } else {
                Section("Speculative decoding") {
                    Label(modelProfile.isSupportArtifact
                          ? "This is a support GGUF and cannot be used as the main model."
                          : modelProfile.isKnown
                            ? "MTP is unavailable for \(modelProfile.displayName)."
                            : "MTP controls are unavailable because this GGUF model type is not recognized by DS Menu Bar.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(modelProfile.isSupportArtifact ? Color.red : Color.orange)
                }
            }

            if hasBatchedMTPConflict {
                Section {
                    Label("Set Resident sessions to 0 in the Server pane, or turn MTP off — this model cannot use both.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    var embeddedMTPDraftDescription: String {
        if modelProfile.family == .qwen38 {
            return "Qwen supports one or two embedded draft tokens. --mtp-draft controls legacy external MTP."
        }
        return "GLM uses its fixed built-in MTP cycle. --mtp-draft controls legacy external MTP."
    }

    var hasBatchedMTPConflict: Bool {
        draft.hasBatchedSessionMTPConflict(modelProfile: modelProfile)
    }

    /// Enough resident slots that a decode cycle can outgrow the batched
    /// speculative path. Whether it actually does depends on how many sessions
    /// are live at once, so the note describes the cap rather than predicting it.
    var mayExceedBatchedMTPDecodeWidth: Bool {
        draft.usesBatchedEmbeddedMTP(modelProfile: modelProfile) &&
            draft.batchedSessions > ServerConfiguration.Config.maxBatchedEmbeddedMTPDecodeWidth
    }

    @ViewBuilder
    var mtpDraftRows: some View {
        let constraint = draft.integerConstraint(for: .mtpDraft, modelProfile: modelProfile)
        let values = (constraint?.minimum ?? DS4ConfigurationLimits.minMTPDraft)...(constraint?.maximum ?? DS4ConfigurationLimits.maxMTPDraft)
        LabeledContent("Draft tokens") {
            Picker("Draft tokens", selection: $draft.mtpDraft) {
                ForEach(values, id: \.self) { value in
                    Text("\(value)").tag(value)
                }
            }
            .labelsHidden()
            .frame(width: 100)
        }
        if let constraint {
            Text("Valid range: \(constraint.minimum.formatted())–\(constraint.maximum.formatted())")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        decimalRow(
            "Confidence margin",
            value: $draft.mtpMargin,
            errorKey: .mtpMargin,
            note: "0 disables the confidence margin; the server accepts 0 through 1,000."
        )
    }

    var diagnosticsPane: some View {
        Form {
            paneIntro(
                "Diagnostics",
                "Server output is captured in the log. Optional tracing records prompts, cache decisions, output, and tool calls."
            )

            Section("Server log") {
                pathRow(
                    "Log folder",
                    field: .logDirectory,
                    help: "Where DS Menu Bar keeps the captured server output"
                )
                fileNameRow(
                    "Log file name",
                    field: .log,
                    help: "stdout and stderr captured by DS Menu Bar"
                )
                integerRow(
                    "Maximum size per log (MB)",
                    value: $draft.logMaxSizeMB,
                    errorKey: .logMaxSizeMB,
                    note: "One rotated backup is retained; total log storage may reach twice this size."
                )
                LabeledContent("Log files") {
                    HStack {
                        Button("Open Log in Console") {
                            ServerLogActions.openInConsole(logPath: server.logPath)
                        }
                        Button("Delete Logs", role: .destructive, action: deleteLogs)
                            .disabled(deleteLogsDisabled)
                    }
                }
            }

            Section("Request trace") {
                Toggle("Record request trace", isOn: $draft.traceEnabled)
                // Where the trace goes only means something while it is being
                // recorded, so those rows follow the toggle the way the disk
                // cache rows follow theirs. Deleting acts on a file that is
                // already on disk, so it stays: a trace holds prompt text, and
                // turning recording off must not be the thing that strands it.
                if draft.traceEnabled {
                    pathRow(
                        "Trace folder",
                        field: .traceDirectory,
                        help: "Where ds4-server writes the request trace"
                    )
                    fileNameRow(
                        "Trace file name",
                        field: .trace,
                        help: "The ds4-server request trace"
                    )
                }
                LabeledContent("Trace data") {
                    Button("Delete Trace", role: .destructive, action: deleteTrace)
                        .disabled(
                            deleteTraceDisabled ||
                            draft.tracePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                            server.isWritingTrace(at: draft.tracePath)
                        )
                        .help(
                            server.isWritingTrace(at: draft.tracePath)
                                ? "Stop the server or apply tracing off before deleting the active trace."
                                : "Delete the request trace at \(DS4ServerCommand.presentingPath(draft.tracePath))"
                        )
                }
            }

            Section("Server diagnostics") {
                textRow(
                    "Simulate used memory",
                    text: simulateUsedMemoryTextBinding,
                    errorKey: .simulateUsedMemory,
                    note: numericTextHelp(
                        for: .simulateUsedMemory,
                        prefix: "Optional GiB value, such as 8 or 40GB, for testing memory-pressure behavior."
                    )
                )
            }

        }
    }

    // MARK: Shared rows and helpers

    @ViewBuilder
    func paneIntro(_ title: String, _ description: String) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    func textRow(
        _ title: String,
        text: Binding<String>,
        errorKey: ServerConfiguration.Config.Field? = nil,
        note: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title) {
                TextField("", text: text)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 180, maxWidth: 260)
                    .accessibilityLabel(title)
            }
            if let note {
                Text(note).font(.footnote).foregroundStyle(.secondary)
            }
            if let errorKey, let error = validationErrors[errorKey] {
                validationLabel(error)
            }
        }
    }

    @ViewBuilder
    func integerRow(
        _ title: String,
        value: Binding<Int>,
        errorKey: ServerConfiguration.Config.Field,
        note: String? = nil,
        // Token counts read better grouped; identifiers like a port number do
        // not — "8,000" is not how anyone writes a port.
        grouped: Bool = true
    ) -> some View {
        let constraint = draft.integerConstraint(for: errorKey, modelProfile: modelProfile)
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title) {
                TextField("", value: value,
                          format: .number.grouping(grouped ? .automatic : .never))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 150)
                    .accessibilityLabel(title)
            }
            if let note {
                Text(note).font(.footnote).foregroundStyle(.secondary)
            }
            if let constraint {
                let range = constraint.minimum == constraint.maximum
                    ? "Required value: \(constraint.minimum.formatted())"
                    : "Valid range: \(constraint.minimum.formatted())–\(constraint.maximum.formatted())"
                let recommended = constraint.recommendedValue.map { "New-profile value: \($0.formatted())" }
                Text([range, constraint.sentinelDescription, recommended].compactMap { $0 }.joined(separator: ". "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let error = validationErrors[errorKey] {
                validationLabel(error)
            }
        }
    }

    @ViewBuilder
    func decimalRow(
        _ title: String,
        value: Binding<Double>,
        errorKey: ServerConfiguration.Config.Field,
        note: String? = nil
    ) -> some View {
        let constraint = draft.decimalConstraint(for: errorKey)
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title) {
                TextField("", value: value, format: .number.precision(.fractionLength(0...3)))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 150)
                    .accessibilityLabel(title)
            }
            if let note {
                Text(note).font(.footnote).foregroundStyle(.secondary)
            }
            if let constraint {
                Text("Valid range: \(constraint.minimum.formatted())–\(constraint.maximum.formatted())")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let error = validationErrors[errorKey] {
                validationLabel(error)
            }
        }
    }

    /// Paths are chosen, never typed: a panel returns something that exists,
    /// which removes a whole class of unusable values before they reach the
    /// draft. The path is plain text rather than selectable text, which does
    /// not survive a truncating fixed-width frame in a form row; Copy Path and
    /// the tooltip carry the full value instead.
    @ViewBuilder
    func pathRow(
        _ title: String,
        field: SettingsPathField,
        errorKey: ServerConfiguration.Config.Field? = nil,
        help: String
    ) -> some View {
        let path = presentedPath(for: field)
        let directory = field.choosesDirectory
        VStack(alignment: .leading, spacing: 4) {
            // The path sits on its own line rather than in the value slot: a
            // row that has to divide its width between a label, a path, and a
            // button gives the path whatever is left, which for the first row
            // of a section is nothing at all. On its own line it gets the full
            // width, which these paths need anyway.
            LabeledContent(title) {
                Button(directory ? "Choose Folder…" : "Choose…") {
                    choosePath(field: field)
                }
                .accessibilityLabel(
                    directory ? "Choose folder for \(title)" : "Choose file for \(title)"
                )
            }
            // A filled monospaced field, like the command preview in General:
            // plain text on the card reads as more label, and a path has to be
            // scannable as the row's value. The leading glyph separates a row
            // that picks a folder from one that picks a file.
            HStack(spacing: 6) {
                Image(systemName: directory ? "folder" : "doc")
                    .foregroundStyle(.secondary)
                    .imageScale(.small)
                Text(path.isEmpty ? "None selected" : path)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(path.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                .help(path)
                .accessibilityLabel("\(title) path")
                .accessibilityValue(path.isEmpty ? "None selected" : path)
                .contextMenu {
                    if !path.isEmpty {
                        Button("Copy Path") { copyPath(for: field) }
                    }
                }
            Text(help).font(.footnote).foregroundStyle(.secondary)
            if let errorKey, let error = validationErrors[errorKey] {
                validationLabel(error)
            }
        }
    }

    /// The name half of a file the app creates. Paired with the folder row
    /// above it, which is a panel like every other path.
    @ViewBuilder
    func fileNameRow(
        _ title: String,
        field: SettingsFileNameField,
        help: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title) {
                TextField("", text: fileNameBinding(for: field))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(minWidth: 260, maxWidth: 420)
                    .accessibilityLabel(title)
            }
            Text(help).font(.footnote).foregroundStyle(.secondary)
            if let error = validationErrors[field.errorKey] {
                validationLabel(error)
            }
        }
    }

    @ViewBuilder
    func validationLabel(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(.red)
    }

    var powerBinding: Binding<Double> {
        Binding(
            get: { Double(draft.powerPercent) },
            set: { draft.powerPercent = Int($0.rounded()) }
        )
    }

    var visionHelp: String {
        switch modelProfile.family {
        case .glm53Flash: return "Optional GLM 5.3 Flash vision encoder GGUF; required when enabled"
        case .deepSeek41: return "Matching DeepSeek V4.1 Flash vision encoder GGUF; required when enabled"
        case .qwen38: return "Qwen3-VL mmproj GGUF (clip / qwen3vl_merger); required when enabled"
        default: return "Compatible vision GGUF; required when enabled"
        }
    }

    var ssdCacheHelp: String {
        numericTextHelp(
            for: .ssdStreamingCacheExperts,
            prefix: "A GiB budget such as 40GB is also accepted."
        )
    }

    func numericTextHelp(
        for field: ServerConfiguration.Config.Field,
        prefix: String
    ) -> String {
        guard let constraint = draft.numericTextConstraint(for: field, modelProfile: modelProfile) else {
            return prefix
        }
        return "\(prefix) \(constraint.rangeDescription). \(constraint.sentinelDescription)."
    }

    func fileNameBinding(for field: SettingsFileNameField) -> Binding<String> {
        Binding(
            get: { fileNameText(for: field) },
            set: { newValue in
                switch field {
                case .log: logNameText = newValue
                case .trace: traceNameText = newValue
                }
                fileNameDidChange(field)
            }
        )
    }

    func fileNameDidChange(_ field: SettingsFileNameField) {
        if isApplyingSettings {
            applyValidationID = nil
            isApplyingSettings = false
        }
        // Hold the draft at its last usable value while the text is not a
        // name, so Apply can never write a path built from a rejected one.
        if fileNameError(for: field) == nil {
            let name = fileNameText(for: field).trimmingCharacters(in: .whitespacesAndNewlines)
            switch field {
            case .log:
                draft.logPath = DS4ServerCommand.storingFilePath(
                    directory: DS4ServerCommand.fileDirectory(of: draft.logPath),
                    name: name
                )
            case .trace:
                draft.tracePath = DS4ServerCommand.storingFilePath(
                    directory: DS4ServerCommand.fileDirectory(of: draft.tracePath),
                    name: name
                )
            }
        }
        validationErrors = settingsValidationErrors(for: draft)
    }

    /// What a row shows for its selection: `~` for the home directory, and a
    /// GGUF inside ds4-server's folder relative to it.
    func presentedPath(for field: SettingsPathField) -> String {
        let directory = DS4ServerCommand.serverDirectory(for: draft.serverPath)
        switch field {
        case .server:
            return DS4ServerCommand.presentingPath(draft.serverPath)
        case .model:
            return DS4ServerCommand.presentingResourcePath(draft.modelPath, relativeTo: directory)
        case .mtp:
            return DS4ServerCommand.presentingResourcePath(draft.mtpPath, relativeTo: directory)
        case .vision:
            return DS4ServerCommand.presentingResourcePath(draft.visionPath, relativeTo: directory)
        case .kvDiskDirectory:
            return DS4ServerCommand.presentingPath(draft.kvDiskDir)
        case .logDirectory:
            return DS4ServerCommand.presentingPath(DS4ServerCommand.fileDirectory(of: draft.logPath))
        case .traceDirectory:
            return DS4ServerCommand.presentingPath(
                DS4ServerCommand.fileDirectory(of: draft.tracePath)
            )
        }
    }

    @ViewBuilder
    func supportModelStatus(expected: DS4SupportKind) -> some View {
        if !draft.mtpPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            LabeledContent("Detected support type") {
                Text(supportProfile.kind.title)
                    .foregroundStyle(supportProfile.kind == expected ? Color.secondary : Color.red)
            }
        }
    }
}
