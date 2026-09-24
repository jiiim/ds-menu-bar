// SPDX-FileCopyrightText: Copyright James Martin and DS Menu Bar contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import UniformTypeIdentifiers


// MARK: - Settings view

/// Hosted by the app's `Settings` scene. The window toolbar switches panes,
/// and a staged draft stays unapplied until the bottom bar's Apply — closing
/// or reverting restores the active configuration.
struct SettingsView: View {
    @ObservedObject var server: ServerManager
    @State var draft: ServerConfiguration.Config
    @State var modelProfile: DS4ModelProfile
    @State var supportProfile: DS4SupportProfile
    @State var visionProfile: DS4VisionProfile
    @State var loadedModelKey: String
    @State var derivedInputs: SettingsDerivedInputs
    @State var derivedFileIdentities: SettingsDerivedFileIdentities
    @State var derivedRefreshRevision: Int
    @State var completedDerivedRefreshRevision: Int
    /// Cached rather than recomputed per row: every row reads this, and
    /// `validationErrors()` walks the whole configuration, so recomputing it
    /// per row meant dozens of full passes per keystroke.
    @State var validationErrors: [ServerConfiguration.Config.Field: String]
    @State var serverValidationError: String?
    @State var modelValidationError: String?
    @State var validatedServerPath: String
    @State var validatedServerIdentity: SettingsFileIdentity?
    @State var validatedModelPath: String
    @State var applyValidationID: UUID?
    @State var isApplyingSettings = false
    @State var isRefreshingDerivedState = false
    @State var logNameText: String
    @State var traceNameText: String
    @State var statusNotice = ""
    @State var statusNoticeIsFailure = false
    @State var deleteLogsDisabled = false
    @State var deleteTraceDisabled = false
    @State var logDeletionError = ""
    @State var traceDeletionError = ""
    @State var windowFitter = SettingsWindowFitter()
    /// Each pane's last measured content height; see `fitted(_:)`.
    @State var paneContentHeight: [SettingsPane: CGFloat] = [:]
    @State var quantumRowReserve = SettingsReservedRow()
    @State var isSettingsVisible = false
    @SceneStorage("dsmenubar.settingsPane") var selectedPaneRaw = SettingsPane.general.rawValue

    init(server: ServerManager) {
        _server = ObservedObject(wrappedValue: server)
        let snapshot = server.configurationSnapshot()
        _draft = State(initialValue: snapshot)
        let derived = Self.derivedProfiles(for: snapshot)
        _modelProfile = State(initialValue: derived.model)
        _supportProfile = State(initialValue: derived.support)
        _visionProfile = State(initialValue: derived.vision)
        _loadedModelKey = State(initialValue: ServerConfiguration.Config.modelKey(
            for: snapshot.modelPath,
            serverPath: snapshot.serverPath
        ))
        _derivedInputs = State(initialValue: SettingsDerivedInputs(snapshot))
        _derivedFileIdentities = State(initialValue: .unavailable)
        _derivedRefreshRevision = State(initialValue: 0)
        _completedDerivedRefreshRevision = State(initialValue: 0)
        _validationErrors = State(initialValue: snapshot.validationErrors(
            modelProfile: derived.model,
            supportProfile: derived.support,
            visionProfile: derived.vision
        ))
        _serverValidationError = State(initialValue: nil)
        _modelValidationError = State(initialValue: nil)
        _validatedServerPath = State(initialValue: snapshot.serverPath)
        _validatedServerIdentity = State(initialValue: nil)
        _validatedModelPath = State(initialValue: snapshot.modelPath)
        _applyValidationID = State(initialValue: nil)
        _logNameText = State(initialValue: DS4ServerCommand.fileName(of: snapshot.logPath))
        _traceNameText = State(initialValue: DS4ServerCommand.fileName(of: snapshot.tracePath))
    }

    var activePane: SettingsPane {
        SettingsPane(rawValue: selectedPaneRaw) ?? .general
    }

    var hasChanges: Bool {
        draft != server.configurationSnapshot()
    }

    var canApply: Bool {
        hasChanges && !isApplyingSettings &&
            SettingsFileNameField.allCases.allSatisfy { fileNameError(for: $0) == nil }
    }

    var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { draft.launchAtLogin },
            set: { requested in
                let update = server.setLaunchAtLogin(requested)
                draft.launchAtLogin = update.isEnabled
                showNotice(update.warning ?? (
                    update.isEnabled ? "Launch at login enabled." : "Launch at login disabled."
                ), isFailure: update.warning != nil)
            }
        )
    }

    var performanceDisplayBinding: Binding<Bool> {
        Binding(
            get: { server.showsPerformanceInMenuBar },
            set: { server.setShowsPerformanceInMenuBar($0) }
        )
    }

    var keepAwakeBinding: Binding<Bool> {
        Binding(
            get: { server.keepsAwakeWhileRunning },
            set: { server.setKeepsAwakeWhileRunning($0) }
        )
    }

    var quitConfirmationBinding: Binding<Bool> {
        Binding(
            get: { server.confirmQuitWhileServerActive },
            set: { server.setConfirmQuitWhileServerActive($0) }
        )
    }

    var autoRestartBinding: Binding<Bool> {
        Binding(
            get: { server.autoRestartServer },
            set: { server.setAutoRestartServer($0) }
        )
    }

    var applyTitle: String {
        switch server.status {
        case .starting, .running, .restarting:
            return "Apply & Restart"
        case .stopped, .stopping, .error:
            return "Apply"
        }
    }

    /// Says what did not happen, not just what to do about it. A running
    /// server stays green while a refused apply changes nothing, so the notice
    /// has to rule out the reading that it took effect.
    var applyRefusedNotice: String {
        switch server.status {
        case .starting, .running, .restarting:
            return "Settings not applied, server not restarted. "
                + "Fix the highlighted settings, then Apply & Restart."
        case .stopped, .stopping, .error:
            return "Settings not applied. Fix the highlighted settings, then Apply."
        }
    }

    var body: some View {
        activePaneContent
        .formStyle(.grouped)
        .navigationTitle(activePane.title)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 0) {
                    Text("Server status: ")
                    Text(server.status.menuText)
                        .foregroundStyle(server.statusColor)
                }
                .lineLimit(1)
                .truncationMode(.tail)
                .help("Server status: \(server.status.menuText)")
                // The notice line holds its height no matter what it contains.
                // A banner that grows and shrinks moves every control below it,
                // and a row can slide out from under a click already on its
                // way. Reserving lines on the notice itself is not enough: with
                // no notice there is no text to reserve them for. A hidden
                // two-line sizer fixes the height instead, and the notice
                // truncates into it and stays readable in the tooltip.
                ZStack(alignment: .topLeading) {
                    Text("A\nA")
                        .font(.callout)
                        .lineLimit(2, reservesSpace: true)
                        .hidden()
                        .accessibilityHidden(true)
                    HStack(spacing: 6) {
                        if isApplyingSettings {
                            ProgressView()
                                .controlSize(.small)
                        } else if statusNoticeIsFailure {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                        }
                        Text(isApplyingSettings ? "Checking selected files…" : statusNotice)
                            .font(.callout)
                            .fontWeight(statusNoticeIsFailure ? .medium : .regular)
                            .foregroundStyle(statusNoticeIsFailure ? Color.red : Color.secondary)
                            .lineLimit(2)
                            .truncationMode(.tail)
                            .help(statusNotice)
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityHidden(statusNotice.isEmpty && !isApplyingSettings)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(.thinMaterial)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            actionBar
        }
        // Outside the bars: a width on the panes alone leaves the bars, and
        // with them the window, free to widen around a centered Form.
        .frame(width: 640)
        .background(SettingsWindowSizer(fitter: windowFitter))
        .onChange(of: draft) { _, newValue in
            let inputs = SettingsDerivedInputs(newValue)
            let errors = settingsValidationErrors(for: newValue)
            if errors != validationErrors {
                validationErrors = errors
            }
            // A refusal names settings to fix and an Apply to press. Once
            // nothing is highlighted, or the draft matches what is already
            // running, it is telling the user to do something that is no
            // longer there.
            if statusNoticeIsFailure,
               errors.isEmpty || newValue == server.configurationSnapshot() {
                showNotice("")
            }
            isRefreshingDerivedState = inputs != derivedInputs ||
                derivedRefreshRevision != completedDerivedRefreshRevision
        }
        .onChange(of: selectedPaneRaw) { _, _ in
            // A pane whose content is unchanged since it was last shown
            // reports nothing on its return, so fit from what it reported
            // then. A pane that does report has already run by the next
            // runloop turn and left its current height here. This fit also
            // applies to a pane showing a validation message.
            DispatchQueue.main.async {
                fitWindow(to: activePane)
            }
        }
        .onChange(of: quantumRowReserve.height) { _, _ in
            // The room kept for the hidden row was measured after the pane
            // was fitted without it.
            guard activePane == .server, !activePaneShowsValidationMessage else { return }
            fitWindow(to: .server)
        }
        .task(id: SettingsDerivedTaskID(
            inputs: SettingsDerivedInputs(draft),
            refreshRevision: derivedRefreshRevision
        )) {
            await refreshDerivedStateAfterEditing(
                for: draft,
                refreshRevision: derivedRefreshRevision
            )
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            guard isSettingsVisible else { return }
            requestDerivedRefresh()
        }
        .task(id: deleteLogsDisabled) {
            guard deleteLogsDisabled else { return }
            try? await Task.sleep(for: .milliseconds(1_500))
            guard !Task.isCancelled else { return }
            deleteLogsDisabled = false
        }
        .task(id: deleteTraceDisabled) {
            guard deleteTraceDisabled else { return }
            try? await Task.sleep(for: .milliseconds(1_500))
            guard !Task.isCancelled else { return }
            deleteTraceDisabled = false
        }
        .alert("Unable to Delete Logs", isPresented: Binding(
            get: { !logDeletionError.isEmpty },
            set: { if !$0 { logDeletionError = "" } }
        )) {
            Button("OK") { logDeletionError = "" }
        } message: {
            Text(logDeletionError)
        }
        .alert("Unable to Delete Trace", isPresented: Binding(
            get: { !traceDeletionError.isEmpty },
            set: { if !$0 { traceDeletionError = "" } }
        )) {
            Button("OK") { traceDeletionError = "" }
        } message: {
            Text(traceDeletionError)
        }
        .onReceive(NotificationCenter.default.publisher(
            for: SettingsNavigation.destinationNotification
        )) { notification in
            guard let rawValue = notification.object as? String,
                  let destination = ServerSettingsDestination(rawValue: rawValue)
            else { return }
            selectedPaneRaw = destinationPaneRaw(destination)
            UserDefaults.standard.removeObject(forKey: SettingsNavigation.pendingPaneKey)
        }
        // Closing Settings without applying is equivalent to cancelling a draft,
        // so the next opening starts from the active configuration. Both hooks
        // are wired: the view is long-lived, and a Settings window that is closed
        // rather than destroyed does not reliably deliver onDisappear.
        .onAppear {
            isSettingsVisible = true
            resetDraft()
        }
        .onDisappear {
            isSettingsVisible = false
            resetDraft(refreshDerived: false)
        }
    }

    func resetDraft(refreshDerived: Bool = true) {
        restoreActiveDraft(refreshDerived: refreshDerived)
        if let destination = SettingsNavigation.consumePendingPane() {
            selectedPaneRaw = destination.rawValue
        }
    }

    func restoreActiveDraft(refreshDerived: Bool) {
        let snapshot = server.configurationSnapshot()
        draft = snapshot
        syncFileNameText(for: snapshot)
        loadedModelKey = ServerConfiguration.Config.modelKey(
            for: snapshot.modelPath,
            serverPath: snapshot.serverPath
        )
        resetSelectionValidation(for: snapshot)
        // Opening or reverting starts a new session: the first Apply checks the
        // executable again rather than trusting a check from the last one.
        validatedServerIdentity = nil
        validationErrors = settingsValidationErrors(for: snapshot)
        if refreshDerived {
            requestDerivedRefresh()
        } else {
            isRefreshingDerivedState = false
        }
        showNotice("")
    }

    func resetSelectionValidation(for config: ServerConfiguration.Config) {
        serverValidationError = nil
        modelValidationError = nil
        validatedServerPath = config.serverPath
        validatedModelPath = config.modelPath
        applyValidationID = nil
        isApplyingSettings = false
    }

    /// One place sets both halves of the notice, so a failure can never keep
    /// the informational styling of whatever was shown before it.
    func showNotice(_ text: String, isFailure: Bool = false) {
        statusNotice = text
        statusNoticeIsFailure = isFailure && !text.isEmpty
    }

    func requestDerivedRefresh() {
        isRefreshingDerivedState = true
        derivedRefreshRevision &+= 1
    }

    func syncFileNameText(for config: ServerConfiguration.Config) {
        logNameText = DS4ServerCommand.fileName(of: config.logPath)
        traceNameText = DS4ServerCommand.fileName(of: config.tracePath)
    }

    private static func derivedProfiles(for config: ServerConfiguration.Config) -> (
        model: DS4ModelProfile,
        support: DS4SupportProfile,
        vision: DS4VisionProfile
    ) {
        let serverDirectory = DS4ServerCommand.serverDirectory(for: config.serverPath)
        return (
            GGUFModelInspector.profile(for: config.modelPath, relativeTo: serverDirectory),
            GGUFModelInspector.supportProfile(for: config.mtpPath, relativeTo: serverDirectory),
            GGUFModelInspector.visionProfile(for: config.visionPath, relativeTo: serverDirectory)
        )
    }

    func settingsValidationErrors(
        for config: ServerConfiguration.Config,
        model: DS4ModelProfile? = nil,
        support: DS4SupportProfile? = nil,
        vision: DS4VisionProfile? = nil
    ) -> [ServerConfiguration.Config.Field: String] {
        var errors = config.validationErrors(
            modelProfile: model ?? modelProfile,
            supportProfile: support ?? supportProfile,
            visionProfile: vision ?? visionProfile
        )
        if config.serverPath == validatedServerPath, let serverValidationError {
            errors[.serverPath] = serverValidationError
        }
        if config.modelPath == validatedModelPath, let modelValidationError {
            errors[.modelPath] = modelValidationError
        }
        for field in SettingsFileNameField.allCases {
            if let error = fileNameError(for: field) {
                errors[field.errorKey] = error
            }
        }
        return errors
    }

    /// A name the app will turn into a file it creates, so it has to be one
    /// path component. The draft keeps the last usable value while the field
    /// says why the current text is not one. The trace name is only required
    /// when tracing is on, matching `validationErrors` — a disabled row must
    /// not be able to block Apply.
    func fileNameError(for field: SettingsFileNameField) -> String? {
        if field == .trace, !draft.traceEnabled { return nil }
        let text = fileNameText(for: field).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            return "Enter a file name"
        }
        if text.contains("/") {
            return "A file name cannot contain a slash"
        }
        if text == "." || text == ".." {
            return "Enter a file name"
        }
        return nil
    }

    func fileNameText(for field: SettingsFileNameField) -> String {
        switch field {
        case .log: return logNameText
        case .trace: return traceNameText
        }
    }

    func refreshDerivedStateAfterEditing(
        for config: ServerConfiguration.Config,
        refreshRevision: Int
    ) async {
        let inputs = SettingsDerivedInputs(config)
        let forceRefresh = refreshRevision != completedDerivedRefreshRevision
        guard inputs != derivedInputs || forceRefresh else {
            isRefreshingDerivedState = false
            return
        }

        do {
            try await Task.sleep(for: .milliseconds(300))
        } catch {
            return
        }
        guard !Task.isCancelled else { return }
        guard !isApplyingSettings else {
            isRefreshingDerivedState = false
            return
        }

        let previousInputs = derivedInputs
        let previousModel = modelProfile
        let previousSupport = supportProfile
        let previousVision = visionProfile
        let previousModelError = modelValidationError
        let previousIdentities = derivedFileIdentities
        let previous = SettingsDerivedPrevious(
            inputs: previousInputs,
            model: previousModel,
            modelError: previousModelError,
            support: previousSupport,
            vision: previousVision,
            identities: previousIdentities
        )
        let derived = await Task.detached(priority: .userInitiated) {
            SettingsDerivedRefresh.compute(
                config: config,
                inputs: inputs,
                previous: previous,
                forceRefresh: forceRefresh
            )
        }.value

        guard !Task.isCancelled,
              SettingsDerivedInputs(draft) == inputs,
              derivedRefreshRevision == refreshRevision
        else { return }

        // A non-path setting may have changed while inspection was running.
        // Apply model defaults to the latest draft so the background result
        // never restores an older copy of those edits.
        let currentConfig = draft
        var refreshedConfig = currentConfig
        let key = ServerConfiguration.Config.modelKey(
            for: currentConfig.modelPath,
            serverPath: currentConfig.serverPath
        )
        let directory = DS4ServerCommand.serverDirectory(for: currentConfig.serverPath)
        let candidate = DS4ServerCommand.resolving(currentConfig.modelPath, relativeTo: directory)
        if derived.modelError == nil, key != loadedModelKey,
           FileManager.default.isReadableRegularFile(atPath: candidate) {
            refreshedConfig = currentConfig.selectingModel(
                path: currentConfig.modelPath,
                serverPath: currentConfig.serverPath,
                profile: derived.model,
                storingCurrentAs: loadedModelKey
            )
            loadedModelKey = key
        }

        modelProfile = derived.model
        supportProfile = derived.support
        visionProfile = derived.vision
        modelValidationError = derived.modelError
        validatedModelPath = inputs.modelPath
        derivedInputs = inputs
        derivedFileIdentities = derived.identities
        completedDerivedRefreshRevision = refreshRevision
        if refreshedConfig != draft {
            draft = refreshedConfig
        }
        validationErrors = settingsValidationErrors(
            for: refreshedConfig,
            model: derived.model,
            support: derived.support,
            vision: derived.vision
        )
        isRefreshingDerivedState = false
    }

    func destinationPaneRaw(_ destination: ServerSettingsDestination) -> String {
        switch destination {
        case .general: return SettingsPane.general.rawValue
        case .model: return SettingsPane.model.rawValue
        case .mtp: return SettingsPane.mtp.rawValue
        }
    }

    /// Staged edits act from here: one prominent Apply with Revert beside it.
    /// The bar is always present and pinned, so it stays reachable no matter
    /// how long the pane is or how far it has been scrolled; both buttons are
    /// disabled until the draft differs from the running configuration.
    var actionBar: some View {
        HStack(spacing: 12) {
            if hasChanges {
                // Return only reaches Apply while Apply is enabled.
                Text(canApply ? "Return to apply \u{2022} Esc to revert" : "Esc to revert")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Revert") {
                restoreActiveDraft(refreshDerived: true)
            }
            .keyboardShortcut(.cancelAction)
            .disabled(!hasChanges)
            Button(applyTitle, action: applySettings)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canApply)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    /// A `TabView` inside a `Settings` scene is what draws the window's
    /// noncustomizable pane toolbar, with the icon-over-label items and the
    /// selected-pane highlight that Finder and Safari settings use.
    /// Selection goes through `activePane`, so a stored value that names no
    /// pane selects General in the tabs as well as the title.
    var activePaneContent: some View {
        TabView(selection: Binding(
            get: { activePane },
            set: { selectedPaneRaw = $0.rawValue }
        )) {
            fitted(.general) { generalPane }
                .tabItem { paneLabel(.general) }
                .tag(SettingsPane.general)
            fitted(.model) { modelPane }
                .tabItem { paneLabel(.model) }
                .tag(SettingsPane.model)
            fitted(.server) { serverPane }
                .tabItem { paneLabel(.server) }
                .tag(SettingsPane.server)
            fitted(.performance) { performancePane }
                .tabItem { paneLabel(.performance) }
                .tag(SettingsPane.performance)
            fitted(.kvCache) { kvCachePane }
                .tabItem { paneLabel(.kvCache) }
                .tag(SettingsPane.kvCache)
            fitted(.mtp) { mtpPane }
                .tabItem { paneLabel(.mtp) }
                .tag(SettingsPane.mtp)
            fitted(.diagnostics) { diagnosticsPane }
                .tabItem { paneLabel(.diagnostics) }
                .tag(SettingsPane.diagnostics)
        }
    }

    func paneLabel(_ pane: SettingsPane) -> some View {
        Label(pane.title, systemImage: pane.systemImage)
    }

    /// Reports the pane's content height to the window fitter whenever it
    /// changes. While the pane shows a validation message, the
    /// window holds its height and the pane scrolls: a typo should not move
    /// the action bar, and the scroll bar leaves once the field is corrected.
    func fitted<Pane: View>(
        _ pane: SettingsPane,
        @ViewBuilder content: () -> Pane
    ) -> some View {
        content()
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentSize.height
            } action: { _, height in
                paneContentHeight[pane] = height
                guard pane == activePane, !activePaneShowsValidationMessage else { return }
                fitWindow(to: pane)
            }
    }

    func fitWindow(to pane: SettingsPane) {
        guard let height = paneContentHeight[pane] else { return }
        windowFitter.fit(contentHeight: height + reservedHeight(in: pane))
    }

    /// Room kept for a row that typing in another field can reveal. The row
    /// then takes that room instead of resizing the window, and hiding it
    /// again leaves the room empty.
    func reservedHeight(in pane: SettingsPane) -> CGFloat {
        guard pane == .server, draft.batchedSessions == 0 else { return 0 }
        return quantumRowReserve.height ?? 0
    }

    var activePaneShowsValidationMessage: Bool {
        validationErrors.keys.contains { SettingsPane.containing($0) == activePane }
    }


    var embeddedMTPBinding: Binding<Bool> {
        Binding(
            get: { draft.mtpMode == .embedded },
            set: { draft.mtpMode = $0 ? .embedded : .off }
        )
    }

    var dsparkConfidenceBinding: Binding<Double> {
        Binding(
            get: { draft.dsparkConfidence ?? draft.automaticDSparkConfidence },
            set: { draft.dsparkConfidence = $0 }
        )
    }

    var dsparkAutomaticConfidenceBinding: Binding<Bool> {
        Binding(
            get: { draft.dsparkConfidence == nil },
            set: { automatic in
                if automatic {
                    draft.dsparkConfidence = nil
                } else if draft.dsparkConfidence == nil {
                    draft.dsparkConfidence = draft.automaticDSparkConfidence
                }
            }
        )
    }

    var simulateUsedMemoryTextBinding: Binding<String> {
        Binding(
            get: { draft.simulateUsedMemory },
            set: { draft.simulateUsedMemory = $0 }
        )
    }

    func choosePath(field: SettingsPathField) {
        let directory = field.choosesDirectory
        let panel = NSOpenPanel()
        panel.canChooseFiles = !directory
        panel.canChooseDirectories = directory
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = directory
        // The log, trace, and cache directories default inside ~/Library and
        // /tmp, neither of which Finder lists, so the panel has to show them.
        panel.showsHiddenFiles = directory
        if field.choosesGGUF,
           let ggufType = UTType(filenameExtension: "gguf", conformingTo: .data) {
            panel.allowedContentTypes = [ggufType]
        }
        if let startDirectory = panelStartDirectory(for: field) {
            panel.directoryURL = startDirectory
        }

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        applyPickedPath(field, path: url.path)
    }

    /// Open the panel where the current selection lives. A configured folder
    /// that has yet to be created falls back to its nearest existing parent
    /// rather than dropping the user somewhere unrelated.
    func panelStartDirectory(for field: SettingsPathField) -> URL? {
        let current = DS4ServerCommand.expandingTilde(storedPath(for: field))
        guard !current.isEmpty else { return nil }
        var candidate = field.choosesDirectory
            ? current
            : (current as NSString).deletingLastPathComponent
        while !candidate.isEmpty, candidate != "/" {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return URL(fileURLWithPath: candidate)
            }
            candidate = (candidate as NSString).deletingLastPathComponent
        }
        return nil
    }

    func copyCommandPreview() {
        let command = DS4ServerCommand.preview(
            configuration: draft,
            modelProfile: modelProfile,
            supportProfile: supportProfile,
            visionProfile: visionProfile
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    /// Copy what a terminal would accept, not the compact form the row shows.
    func copyPath(for field: SettingsPathField) {
        let stored = storedPath(for: field)
        let resolved = field.choosesDirectory
            ? DS4ServerCommand.expandingTilde(stored)
            : DS4ServerCommand.resolving(
                stored,
                relativeTo: DS4ServerCommand.serverDirectory(for: draft.serverPath)
            )
        guard !resolved.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(resolved, forType: .string)
    }

    func storedPath(for field: SettingsPathField) -> String {
        switch field {
        case .server: return draft.serverPath
        case .model: return draft.modelPath
        case .mtp: return draft.mtpPath
        case .vision: return draft.visionPath
        case .kvDiskDirectory: return draft.kvDiskDir
        case .logDirectory: return DS4ServerCommand.fileDirectory(of: draft.logPath)
        case .traceDirectory: return DS4ServerCommand.fileDirectory(of: draft.tracePath)
        }
    }

    func applyPickedPath(_ field: SettingsPathField, path: String) {
        if isApplyingSettings {
            applyValidationID = nil
            isApplyingSettings = false
        }
        let serverDirectory = DS4ServerCommand.serverDirectory(for: draft.serverPath)
        switch field {
        case .server:
            draft.serverPath = DS4ServerCommand.storingAbsolutePath(path)
            serverValidationError = nil
        case .model:
            draft.modelPath = DS4ServerCommand.storingResourcePath(
                path,
                relativeTo: serverDirectory
            )
            modelValidationError = nil
            requestDerivedRefresh()
        case .mtp:
            draft.mtpPath = DS4ServerCommand.storingResourcePath(
                path,
                relativeTo: serverDirectory
            )
            requestDerivedRefresh()
        case .vision:
            draft.visionPath = DS4ServerCommand.storingResourcePath(
                path,
                relativeTo: serverDirectory
            )
            requestDerivedRefresh()
        case .kvDiskDirectory:
            draft.kvDiskDir = DS4ServerCommand.storingAbsolutePath(path)
        case .logDirectory:
            draft.logPath = DS4ServerCommand.storingFilePath(
                directory: path,
                name: logNameText
            )
        case .traceDirectory:
            draft.tracePath = DS4ServerCommand.storingFilePath(
                directory: path,
                name: traceNameText
            )
        }
    }

    func applySettings() {
        let candidate = draft
        let validationID = UUID()
        applyValidationID = validationID
        isApplyingSettings = true
        showNotice("")

        let previousServerPath = validatedServerPath
        let previousServerError = serverValidationError
        let previousServerIdentity = validatedServerIdentity

        Task {
            var checked = await Task.detached(priority: .userInitiated) {
                SettingsApplyChecks.compute(
                    candidate: candidate,
                    previousServerPath: previousServerPath,
                    previousServerIdentity: previousServerIdentity,
                    previousServerError: previousServerError
                )
            }.value

            guard applyValidationID == validationID, draft == candidate else {
                // Picking a path or editing a file name already cancelled this
                // pass. Anything else means another control moved while the
                // checks ran, and the click needs to say so rather than look
                // like it did nothing.
                if applyValidationID == validationID {
                    applyValidationID = nil
                    isApplyingSettings = false
                    showNotice(
                        "Settings changed while the files were checked. Apply again.",
                        isFailure: true
                    )
                }
                return
            }

            var checkedConfig = candidate
            let key = ServerConfiguration.Config.modelKey(
                for: candidate.modelPath,
                serverPath: candidate.serverPath
            )
            if checked.modelError == nil, key != loadedModelKey {
                checkedConfig = candidate.selectingModel(
                    path: candidate.modelPath,
                    serverPath: candidate.serverPath,
                    profile: checked.model,
                    storingCurrentAs: loadedModelKey
                )
            }

            // selectingModel can restore model-specific file paths. The first
            // pass inspected `candidate`, so do not attach its profiles or
            // identities to a different snapshot.
            let rechecked: SettingsApplyChecks?
            switch SettingsApplyReinspection.plan(
                inspected: candidate,
                restored: checkedConfig
            ) {
            case .none:
                rechecked = nil
            case .auxiliaryFiles(let restoredConfig):
                let initialChecks = checked
                rechecked = await Task.detached(priority: .userInitiated) {
                    initialChecks.reinspectingAuxiliaryFiles(for: restoredConfig)
                }.value
            case .allFiles(let restoredConfig):
                let initialChecks = checked
                rechecked = await Task.detached(priority: .userInitiated) {
                    SettingsApplyChecks.compute(
                        candidate: restoredConfig,
                        previousServerPath: candidate.serverPath,
                        previousServerIdentity: initialChecks.serverIdentity,
                        previousServerError: initialChecks.serverError
                    )
                }.value
            }
            if let rechecked {
                checked = rechecked
                guard applyValidationID == validationID, draft == candidate else {
                    if applyValidationID == validationID {
                        applyValidationID = nil
                        isApplyingSettings = false
                        showNotice(
                            "Settings changed while the files were checked. Apply again.",
                            isFailure: true
                        )
                    }
                    return
                }
            }

            var errors = checkedConfig.validationErrors(
                modelProfile: checked.model,
                supportProfile: checked.support,
                visionProfile: checked.vision
            )
            if let error = checked.serverError {
                errors[.serverPath] = error
            }
            if let error = checked.modelError {
                errors[.modelPath] = error
            }

            let usesExternalSupport =
                (checkedConfig.mtpMode == .external && checked.model.supportsExternalMTP) ||
                (checkedConfig.mtpMode == .dspark && checked.model.supportsDSpark)
            if usesExternalSupport, !checked.mtpIsReadable {
                errors[.mtpPath] = "Choose a readable MTP support GGUF."
            }
            if checked.model.supportsVision && checkedConfig.visionEnabled,
               !checked.visionIsReadable {
                errors[.visionPath] = "Choose a readable compatible vision GGUF."
            }

            serverValidationError = checked.serverError
            modelValidationError = checked.modelError
            // `checkedConfig`, not `candidate`: a reinspection pass above may
            // have re-run these checks against restored paths, and the record
            // has to name the files `checked` actually describes.
            validatedServerPath = checkedConfig.serverPath
            validatedServerIdentity = checked.serverIdentity
            validatedModelPath = checkedConfig.modelPath
            modelProfile = checked.model
            supportProfile = checked.support
            visionProfile = checked.vision
            if checked.modelError == nil {
                // Recomputed from `checkedConfig` for the same reason as the
                // records above: the key must name the pair actually loaded,
                // not the one the first pass happened to inspect.
                loadedModelKey = ServerConfiguration.Config.modelKey(
                    for: checkedConfig.modelPath,
                    serverPath: checkedConfig.serverPath
                )
            }
            draft = checkedConfig
            validationErrors = errors
            applyValidationID = nil
            isApplyingSettings = false

            guard errors.isEmpty else {
                revealFirstValidationError(in: errors)
                showNotice(applyRefusedNotice, isFailure: true)
                return
            }

            finishApplying(
                checkedConfig,
                identities: checked.identities,
                inspected: ServerManager.InspectedProfiles(
                    model: checked.model,
                    support: checked.support,
                    vision: checked.vision
                )
            )
        }
    }

    /// Move to the pane holding the first field that refused the draft. The
    /// order matches `firstValidationError`, so the pane shown is the one
    /// naming the error a launch would report first. Returns false when the
    /// refusal has no field to show.
    @discardableResult
    func revealFirstValidationError(
        in errors: [ServerConfiguration.Config.Field: String]
    ) -> Bool {
        guard let field = ServerConfiguration.Config.Field.allCases.first(where: {
            errors[$0] != nil
        }) else { return false }
        selectedPaneRaw = SettingsPane.containing(field).rawValue
        return true
    }

    func finishApplying(
        _ config: ServerConfiguration.Config,
        identities: SettingsDerivedFileIdentities,
        inspected: ServerManager.InspectedProfiles
    ) {
        // Report what the manager actually did — a .starting status whose
        // process never came up is applied, not restarted.
        //
        // The profiles come from the same off-main pass that produced
        // `identities`, so the manager re-validates without reopening three
        // GGUFs on the main thread.
        let result = server.applyConfiguration(config, inspected: inspected)
        switch result.kind {
        case .invalid:
            // Defensive. The manager re-runs the same pure validation over the
            // profiles passed in above, so it has nothing this view did not
            // already see — a file replaced after that inspection is caught by
            // ProcessManager.launch's preflight, which re-reads every path,
            // rather than here. Should the two ever disagree, show the field
            // rather than leaving Apply looking like it did nothing.
            let errors = settingsValidationErrors(for: config)
            validationErrors = errors
            showNotice(
                revealFirstValidationError(in: errors)
                    ? applyRefusedNotice
                    : "Settings not applied. Re-check the selected files.",
                isFailure: true
            )
            return
        case .applied, .appliedAndRestarting:
            break
        }
        // Without this the launch-at-login read-back below would flip the toggle
        // back with no explanation of why.
        showNotice(result.warning ?? "", isFailure: result.warning != nil)
        let snapshot = server.configurationSnapshot()
        draft = snapshot
        syncFileNameText(for: snapshot)
        loadedModelKey = ServerConfiguration.Config.modelKey(
            for: snapshot.modelPath,
            serverPath: snapshot.serverPath
        )
        resetSelectionValidation(for: snapshot)
        validationErrors = settingsValidationErrors(for: snapshot)
        // Apply just inspected these files, so seed the derived state from that
        // pass instead of scheduling a second one. A snapshot the manager
        // rewrote to different paths still has to be inspected.
        let appliedInputs = SettingsDerivedInputs(snapshot)
        if appliedInputs == SettingsDerivedInputs(config) {
            derivedInputs = appliedInputs
            derivedFileIdentities = identities
            completedDerivedRefreshRevision = derivedRefreshRevision
            isRefreshingDerivedState = false
        } else {
            requestDerivedRefresh()
        }
    }

    func deleteLogs() {
        do {
            try server.clearLog()
            deleteLogsDisabled = true
        } catch {
            logDeletionError = error.localizedDescription
        }
    }

    func deleteTrace() {
        do {
            try server.deleteTrace(at: draft.tracePath)
            deleteTraceDisabled = true
        } catch {
            traceDeletionError = error.localizedDescription
        }
    }
}
