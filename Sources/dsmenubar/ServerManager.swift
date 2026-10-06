// SPDX-FileCopyrightText: Copyright James Martin and DS Menu Bar contributors
// SPDX-License-Identifier: MIT

import Combine
import Foundation
import os.log
import UserNotifications

// MARK: - ServerStatus

/// Represents the observable lifecycle state of the ds4-server process.
enum ServerStatus: Equatable {
    case stopped
    case starting
    case restarting
    case running(pid: Int32)
    case stopping
    case error(String)
}

extension ServerStatus {
    /// True while a server process is being brought up — either an initial
    /// start or a restart's relaunch — and we're awaiting its first health check.
    var isStartingUp: Bool {
        switch self {
        case .starting, .restarting: return true
        default: return false
        }
    }

    /// States in which a ds4-server process is live or on its way to being so.
    /// Model load and Metal residency happen during .starting, which is the
    /// longest unattended stretch of a run and precisely what keep-awake is for.
    var holdsServerProcess: Bool {
        switch self {
        case .starting, .restarting, .running, .stopping: return true
        case .stopped, .error: return false
        }
    }

    /// States where a quit interrupts work the user is waiting on: a model load
    /// in progress or a live server with connected clients. `.stopping` is the
    /// deliberate difference from `holdsServerProcess` — a shutdown is already
    /// under way, so a prompt would ask about work that is already ending.
    var requiresQuitConfirmation: Bool {
        switch self {
        case .starting, .restarting, .running: return true
        case .stopped, .stopping, .error: return false
        }
    }
}

// MARK: - ServerManager (thin orchestrator)
//
/// Owns the three components extracted from the original monolithic class:
///   • ServerConfiguration  – config persistence & login-item management
///   • ProcessManager       – child-process lifecycle
///   • HealthChecker        – readiness and ongoing health polling
///
/// ServerManager wires their callbacks together, publishes a single
/// @Published `status` that the UI observes, and exposes config properties
/// for SettingsView to bind to.

@MainActor
final class ServerManager: ObservableObject {
    // MARK: - Components

    let config: ServerConfiguration
    private let processManager: ProcessManager
    private let healthChecker: HealthChecker
    private let stabilityWindow: TimeInterval
    private let log = OSLog(subsystem: "com.jiiim.ds-menu-bar", category: "orchestrator")

    /// Injected by tests to count notifications instead of observing banners.
    typealias NotificationSink = (_ title: String, _ body: String) -> Void
    private let notificationSink: NotificationSink?

    @Published private(set) var status: ServerStatus = .stopped {
        didSet { statusDidChange(from: oldValue) }
    }
    @Published private(set) var performance: ServerPerformance = .idle
    @Published private(set) var showsPerformanceInMenuBar: Bool
    @Published private(set) var keepsAwakeWhileRunning: Bool
    @Published private(set) var confirmQuitWhileServerActive: Bool
    @Published private(set) var autoRestartServer: Bool
    @Published private(set) var recentSelections: RecentSelections
    @Published private(set) var keepAwakeState: KeepAwakeState = .off

    // ASCII only: pmset mangles non-ASCII in assertion names, and the name
    // exists to be read there.
    private let idleSleepAssertion = IdleSleepAssertion(
        name: "DS Menu Bar: ds4-server is running"
    )
    private let externalPower = ExternalPowerMonitor()

    private var performancePolicy = PerformanceDisplayPolicy()
    private var performancePublishWorkItem: DispatchWorkItem?
    private var performanceIdleWorkItem: DispatchWorkItem?

    /// Receives one event for each failed launch attempt. The app layer uses
    /// manual events for a foreground alert; non-manual failures are notified
    /// by this manager because it already owns the notification path.
    var onLaunchFailure: ((ServerLaunchFailure) -> Void)?

    private var activeLaunchSource: ServerLaunchSource?
    private var activeLaunchAttemptID: UUID?
    private var reportedLaunchAttemptID: UUID?
    /// The status menu reads this instead of the file, so opening the menu
    /// never waits on a GGUF header. `refreshActiveModelInfo` keeps it current.
    @Published private(set) var activeModelInfo = ActiveModelInfo.empty
    private let activeModelCache = ActiveModelCache()
    private let inspectModelProfile: @Sendable (String) -> DS4ModelProfile
    private var activeModelRefreshTask: Task<Void, Never>?
    private var activeModelRefreshLocation: ActiveModelDescription.Location?
    /// Bumped per refresh so a late inspection cannot overwrite a newer one.
    private var activeModelRefreshGeneration = 0
    /// The applied model's profile, when an Apply or a status-menu read has
    /// inspected it. The next Apply files the vision and support paths that
    /// model used under its family.
    private var appliedModelProfile: (
        location: ActiveModelDescription.Location,
        profile: DS4ModelProfile
    )?

    /// One automatic restart per incident. Set when an automatic restart is
    /// started, cleared only after a run has been healthy for
    /// `stabilityWindow`. A manual start does not clear it.
    private var autoRestartAttempted = false
    /// Armed when an automatic restart begins, posted when the replacement
    /// reaches `.running`, and dropped if the restart is cancelled or fails:
    /// the user should read about a restart that happened, not one that is
    /// still loading.
    private var pendingRestartNotice: (title: String, body: String)?
    /// Bumped whenever a run becomes healthy. The stability work item captures
    /// it, so a stale item cannot clear a newer run's episode.
    private var healthGeneration = 0
    private var stabilityWorkItem: DispatchWorkItem?

    // MARK: - Init

    init(
        config: ServerConfiguration = ServerConfiguration(),
        processManager: ProcessManager = ProcessManager(),
        healthChecker: HealthChecker = HealthChecker(),
        stabilityWindow: TimeInterval = AutoRestartPolicy.stabilityWindow,
        notificationSink: NotificationSink? = nil,
        inspectModelProfile: @escaping @Sendable (String) -> DS4ModelProfile = {
            GGUFModelInspector.profile(for: $0)
        }
    ) {
        self.config = config
        self.processManager = processManager
        self.healthChecker = healthChecker
        self.stabilityWindow = stabilityWindow
        self.notificationSink = notificationSink
        self.inspectModelProfile = inspectModelProfile
        showsPerformanceInMenuBar = config.showsPerformanceInMenuBar
        keepsAwakeWhileRunning = config.keepsAwakeWhileRunning
        confirmQuitWhileServerActive = config.confirmQuitWhileServerActive
        autoRestartServer = config.autoRestartServer
        recentSelections = config.recentSelections
        wireCallbacks()
        processManager.setPerformanceMonitoring(showsPerformanceInMenuBar)
        externalPower.onChange = { [weak self] in
            self?.refreshKeepAwake()
        }
        externalPower.start()
        refreshKeepAwake()
    }

    /// Isolated because `ExternalPowerMonitor.stop()` removes a source from the
    /// main run loop; doing that from whichever thread drops the last reference
    /// is not safe, and a nonisolated deinit cannot touch either property.
    isolated deinit {
        externalPower.stop()
        idleSleepAssertion.release()
    }

    /// Establish the callback graph so each component reports back to us.
    private func wireCallbacks() {
        // ── ProcessManager → ServerManager ──

        processManager.onStatusChange = { [weak self] newStatus in
            DispatchQueue.main.async {
                self?.status = newStatus
            }
        }

        processManager.onLaunchFailure = { [weak self] message in
            self?.reportLaunchFailure(message)
        }

        processManager.onPerformanceChange = { [weak self] performance in
            self?.receivePerformance(performance)
        }

        processManager.onPortAvailable = { [weak self] in
            guard let self = self else { return }
            // Only proceed if we're still in restarting state; a stop() would
            // have changed the status to .stopped or .stopping.
            guard case .restarting = self.status else { return }
            // Port is free — now launch the fresh server and begin health polling.
            self.start(source: .restart)
        }

        processManager.onTerminated = { [weak self] info in
            guard let self = self else { return }
            // All timers are stopped by the termination handler already.
            self.healthChecker.stop()

            let wasStarting = self.status.isStartingUp

            if info.pendingRestart {
                // This was the stop half of a restart: stay in .restarting and
                // relaunch once the port it held is free again. Status is left
                // untouched so the menu keeps showing "Restarting…".
                self.startWhenPortAvailable()
            } else if let reason = info.failureReason {
                // A detected failure outranks how the child ultimately exits.
                // terminate(withFailureReason:) deliberately sends SIGTERM, so
                // that stop is "intentional" at the process layer and the server
                // may even handle it as a clean exit. Neither outcome turns the
                // health failure into a user-requested stop.
                if self.autoRestartIfAllowed(
                    title: "ds4-server was unresponsive",
                    completionBody: "It stopped answering health checks and has been restarted."
                ) {
                    return
                }
                self.reportStopped(title: "ds4-server stopped", reason: reason)
            } else if info.intentional {
                self.activeLaunchSource = nil
                self.activeLaunchAttemptID = nil
                self.status = .stopped
            } else if wasStarting, self.activeLaunchSource != nil {
                let detail = info.failureReason ?? self.processManager.launchFailureReason(
                    logPath: self.config.logPath
                )
                let reason = detail.isEmpty ? "ds4-server exited during startup" : detail
                self.status = .error(reason)
                self.reportLaunchFailure(reason)
            } else {
                // Spontaneous exit while the run was healthy. A clean status is
                // not evidence of intent: the app marks its own stops with
                // `intentionalStop`, and ds4-server exits 0 when something else
                // sends it SIGTERM (`pkill`, say). Treat every unrequested exit
                // as unexpected, clean or not.
                let how = "exited unexpectedly"
                let detail = self.lastLogReason()
                let fullDetail = detail.isEmpty ? "" : " — \(detail)"
                let msg = "ds4-server \(how)\(fullDetail)"
                let title = info.clean ? "ds4-server stopped unexpectedly" : "ds4-server crashed"
                let completion = info.clean
                    ? "It was terminated from outside the app and has been restarted."
                    : "It exited unexpectedly and has been restarted."
                if self.autoRestartIfAllowed(title: title, completionBody: completion) { return }
                self.reportStopped(title: title, reason: msg)
            }
        }

        // ── HealthChecker → ServerManager ──

        healthChecker.onHealthSuccess = { [weak self] in
            guard let self = self else { return }
            let pid = self.processManager.currentPID ?? 0
            self.activeLaunchSource = nil
            self.activeLaunchAttemptID = nil
            self.status = .running(pid: pid)
        }

        healthChecker.onUnreachable = { [weak self] reason in
            guard let self = self else { return }
            // No further polls: this run is being stopped. The reaper reports
            // and decides about a restart once the child is actually gone.
            self.healthChecker.stop()
            self.status = .stopping
            self.processManager.terminate(withFailureReason: reason)
        }

        // A long startup is legitimate — ds4-server can spend a long time on
        // model load and Metal residency — so this only informs the user, and
        // includes the last log line so a stuck startup is diagnosable without
        // opening Console. Nothing is terminated; polling continues.
        healthChecker.onStartupStalled = { [weak self] in
            guard let self = self else { return }
            let minutes = Int(self.healthChecker.stallAdvisoryInterval / 60)
            let detail = self.lastLogReason()
            let body = detail.isEmpty
                ? "Still starting after \(minutes) min. This is normal for a large model; cancel from the menu if it looks stuck."
                : "Still starting after \(minutes) min — \(detail)"
            self.postNotification(title: "ds4-server still starting", body: body)
        }

        healthChecker.isStartingUp = { [weak self] in
            self?.status.isStartingUp ?? false
        }

        healthChecker.isRunning = { [weak self] in
            if case .running = self?.status { return true }
            return false
        }
    }

    // MARK: - Auto-restart

    private func statusDidChange(from old: ServerStatus) {
        refreshKeepAwake()
        guard status != old else { return }
        postPendingRestartNoticeIfFinished()
        if case .running = status {
            armStabilityWindow()
        } else {
            stabilityWorkItem?.cancel()
            stabilityWorkItem = nil
        }
    }

    /// Announce a finished automatic restart, and drop the notice if the
    /// restart was cancelled or failed (its own report covers that).
    private func postPendingRestartNoticeIfFinished() {
        guard let notice = pendingRestartNotice else { return }
        switch status {
        case .running:
            pendingRestartNotice = nil
            postNotification(title: notice.title, body: notice.body)
        case .stopped, .error:
            pendingRestartNotice = nil
        case .starting, .stopping, .restarting:
            break
        }
    }

    /// Start the window that closes an auto-restart episode. Cancelling a work
    /// item is not proof its block did not run, so the block re-checks the
    /// generation and the status before clearing the ledger.
    private func armStabilityWindow() {
        healthGeneration &+= 1
        let generation = healthGeneration
        stabilityWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.healthGeneration == generation, case .running = self.status else {
                return
            }
            self.autoRestartAttempted = false
        }
        stabilityWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + stabilityWindow, execute: work)
    }

    /// Restart automatically when the policy allows it. Returns true when a
    /// relaunch was started, in which case the caller reports nothing. The
    /// notice is armed here and posted once the replacement is running, so it
    /// describes a restart that happened rather than one still in progress.
    private func autoRestartIfAllowed(title: String, completionBody: String) -> Bool {
        let decision = AutoRestartPolicy.decision(
            preferenceEnabled: autoRestartServer,
            restartable: true,
            attemptedThisEpisode: autoRestartAttempted
        )
        guard decision == .restart else { return false }
        autoRestartAttempted = true
        activeLaunchSource = .restart
        activeLaunchAttemptID = UUID()
        pendingRestartNotice = (title: title, body: completionBody)
        status = .restarting
        startWhenPortAvailable()
        return true
    }

    /// Report a restartable failure without relaunching. The body names the
    /// reason and says why nothing restarted: the preference is off, or this
    /// incident's one automatic restart is already spent.
    private func reportStopped(title: String, reason: String) {
        activeLaunchSource = nil
        activeLaunchAttemptID = nil
        status = .error(reason)
        let explanation: String?
        if !autoRestartServer {
            explanation = "Automatic restart is off."
        } else if autoRestartAttempted {
            explanation = "Automatic restart is not repeating."
        } else {
            explanation = nil
        }
        let body = explanation.map { Self.sentence($0, after: reason) } ?? reason
        postNotification(title: title, body: body)
    }

    /// Join a reason and an explanation into one notification body, adding a
    /// period when the reason (often a raw log line) does not end with one.
    private static func sentence(_ explanation: String, after reason: String) -> String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return explanation }
        guard let last = trimmed.last, ".!?".contains(last) else {
            return "\(trimmed). \(explanation)"
        }
        return "\(trimmed) \(explanation)"
    }

    // MARK: - Configuration

    /// The server log path, for the menu-bar "Open Log in Console" action.
    var logPath: String { config.logPath }

    /// When the current run last served a request, read by the status menu
    /// when it opens. Not published: the menu recomputes on every refresh.
    var lastServerUsageAt: Date? { processManager.lastUsageAt }

    /// Apply the menu-bar display preference immediately without restarting the
    /// managed server. ProcessManager starts or stops its incremental log reader.
    func setShowsPerformanceInMenuBar(_ requested: Bool) {
        guard requested != showsPerformanceInMenuBar else { return }
        config.setShowsPerformanceInMenuBar(requested)
        showsPerformanceInMenuBar = requested
        if !requested {
            apply(performancePolicy.reset(now: Date()))
        }
        processManager.setPerformanceMonitoring(requested)
    }

    /// Apply the keep-awake preference immediately. Like the display preference
    /// above, it is an app-only setting: it does not alter ds4-server's command
    /// line and must not enter the Apply & Restart path.
    func setKeepsAwakeWhileRunning(_ requested: Bool) {
        guard requested != keepsAwakeWhileRunning else { return }
        config.setKeepsAwakeWhileRunning(requested)
        keepsAwakeWhileRunning = requested
        refreshKeepAwake()
    }

    /// Apply the quit-confirmation preference immediately. Like the keep-awake
    /// preference above, it is an app-only setting: it does not alter
    /// ds4-server's command line and must not enter the Apply & Restart path.
    func setConfirmQuitWhileServerActive(_ requested: Bool) {
        guard requested != confirmQuitWhileServerActive else { return }
        config.setConfirmQuitWhileServerActive(requested)
        confirmQuitWhileServerActive = requested
    }

    /// Apply the auto-restart preference immediately, on the same terms.
    func setAutoRestartServer(_ requested: Bool) {
        guard requested != autoRestartServer else { return }
        config.setAutoRestartServer(requested)
        autoRestartServer = requested
    }

    /// Forget one row's history in Settings' recent menus. Takes effect at
    /// once; no setting changes, so there is nothing to apply.
    func clearRecentSelections(field: RecentSelections.Field, scope: String? = nil) {
        config.clearRecentSelections(field: field, scope: scope)
        recentSelections = config.recentSelections
    }

    /// Snapshot used by Settings to edit a draft without mutating the running
    /// process until the user applies it.
    func configurationSnapshot() -> ServerConfiguration.Config {
        config.snapshot()
    }

    /// Recompute the status menu's description of the configured model. The
    /// cheap part — resolve the path and read its identity — runs here; a miss
    /// schedules the GGUF header read off the main thread, so opening the menu
    /// never waits on the file. Apply and initial setup prime the cache with
    /// the profile they already inspected, so the type is usually already
    /// there.
    func refreshActiveModelInfo() {
        let current = config.snapshot()
        let location = ActiveModelDescription.locate(
            modelPath: current.modelPath,
            serverPath: current.serverPath
        )
        // The same file is already being read; leave that work alone.
        if activeModelRefreshTask != nil, activeModelRefreshLocation == location {
            return
        }
        if let cached = activeModelCache.cachedInfo(for: location) {
            invalidateActiveModelRefresh()
            if activeModelInfo != cached { activeModelInfo = cached }
            return
        }
        invalidateActiveModelRefresh()
        let placeholder = ActiveModelDescription.placeholder(location: location)
        if activeModelInfo != placeholder { activeModelInfo = placeholder }
        guard location.isAvailable else {
            activeModelCache.store(placeholder, for: location)
            return
        }
        let generation = activeModelRefreshGeneration
        activeModelRefreshLocation = location
        let path = location.resolvedPath
        let inspect = inspectModelProfile
        activeModelRefreshTask = Task { [weak self] in
            let profile = await Task.detached(priority: .utility) {
                inspect(path)
            }.value
            guard !Task.isCancelled, let self,
                  self.activeModelRefreshGeneration == generation
            else { return }
            let info = ActiveModelDescription.make(location: location, profile: profile)
            self.activeModelCache.store(info, for: location)
            self.appliedModelProfile = (location, profile)
            if self.activeModelInfo != info { self.activeModelInfo = info }
            self.activeModelRefreshTask = nil
            self.activeModelRefreshLocation = nil
        }
    }

    /// Describe the model from a profile the caller already inspected, so the
    /// status menu does not read the header a second time.
    private func primeActiveModelInfo(with profile: DS4ModelProfile) {
        // A read started for the previous model must not land after this one.
        invalidateActiveModelRefresh()
        let current = config.snapshot()
        let location = ActiveModelDescription.locate(
            modelPath: current.modelPath,
            serverPath: current.serverPath
        )
        let info = ActiveModelDescription.make(location: location, profile: profile)
        activeModelCache.store(info, for: location)
        appliedModelProfile = (location, profile)
        if activeModelInfo != info { activeModelInfo = info }
    }

    /// The profile of the model `config` names: the one already inspected
    /// when it still describes that file, otherwise a header read. Only an
    /// Apply that changes the model needs it, for the paths left behind.
    private func profileOfModel(in config: ServerConfiguration.Config) async -> DS4ModelProfile? {
        let location = ActiveModelDescription.locate(
            modelPath: config.modelPath,
            serverPath: config.serverPath
        )
        guard location.isAvailable else { return nil }
        if let applied = appliedModelProfile, applied.location == location {
            return applied.profile
        }
        let inspect = inspectModelProfile
        let path = location.resolvedPath
        return await Task.detached(priority: .userInitiated) {
            inspect(path)
        }.value
    }

    /// Discard any read that is still in flight. Every path that resolves the
    /// description without starting a read calls this, so a result computed
    /// for an older model or file cannot overwrite the current one.
    private func invalidateActiveModelRefresh() {
        activeModelRefreshGeneration &+= 1
        activeModelRefreshTask?.cancel()
        activeModelRefreshTask = nil
        activeModelRefreshLocation = nil
    }

    /// Apply the app's login-item setting without restarting ds4-server.
    func setLaunchAtLogin(_ requested: Bool) -> ServerConfiguration.LoginItemUpdate {
        objectWillChange.send()
        return config.setLaunchAtLogin(requested)
    }

    var needsInitialSetup: Bool {
        config.needsInitialSetup
    }

    func completeInitialSetup(
        serverPath: String,
        modelPath: String,
        modelProfile: DS4ModelProfile
    ) {
        config.completeInitialSetup(
            serverPath: serverPath,
            modelPath: modelPath,
            modelProfile: modelProfile
        )
        recentSelections = config.recentSelections
        primeActiveModelInfo(with: modelProfile)
    }

    /// Clear the current server log and its rotated backup. ProcessManager
    /// truncates the active file in place, so this is safe while the server runs.
    func clearLog() throws {
        try processManager.clearLogCollection(logPath: config.logPath)
    }

    /// Whether the live child process is writing to the selected trace path.
    /// Settings uses this to prevent unlinking an active trace descriptor.
    func isWritingTrace(at tracePath: String) -> Bool {
        guard processManager.isProcessRunning else { return false }
        let active = config.snapshot()
        guard active.traceEnabled else { return false }
        return Self.standardizedPath(active.tracePath) == Self.standardizedPath(tracePath)
    }

    func deleteTrace(at tracePath: String) throws {
        guard !isWritingTrace(at: tracePath) else {
            throw TraceDeletionError.active
        }
        try processManager.deleteTraceFile(tracePath: tracePath)
    }

    private static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: DS4ServerCommand.expandingTilde(path))
            .standardizedFileURL.path
    }


    // MARK: - Public API

    /// Start the ds4-server process. Valid from .stopped or .error.
    /// A restart's relaunch arrives here as .restarting and keeps that label.
    func start() {
        start(source: .manual)
    }

    private func start(source: ServerLaunchSource) {
        // A fresh start supersedes any pending restart-wait.
        // (processManager.launch clears its own restartTimer.)
        switch status {
        case .stopped, .error:
            status = .starting
        case .restarting:
            break  // keep .restarting until healthy
        case .starting, .running, .stopping:
            return  // re-entrant guard
        }

        // A hand-started run earns a fresh automatic-restart attempt: the user
        // has intervened, so the incident's spent ledger should not suppress
        // recovery from a later unrelated failure. Internal relaunches
        // (.restart) keep the ledger.
        if source == .manual {
            autoRestartAttempted = false
        }

        activeLaunchSource = source
        activeLaunchAttemptID = UUID()
        guard let healthURL = processManager.launch(configuration: config.snapshot()) else {
            // launch() already set status to .error via onStatusChange.
            return
        }

        // Begin readiness polling. ds4-server can spend a substantial amount of
        // time loading the model and requesting Metal residency before it opens
        // its HTTP listener, so readiness has no artificial deadline.
        healthChecker.startPolling(url: healthURL)
    }

    /// Stop the server. Also the cancel path for an in-progress start or restart.
    func stop() {
        // Cancel health/startup timers first so they don't fire after we've
        // decided to stop.
        healthChecker.stop()
        processManager.terminate()
        activeLaunchSource = nil
        activeLaunchAttemptID = nil

        // If there was no live child process, we're already stopped.
        if !processManager.isProcessRunning {
            status = .stopped
        } else {
            status = .stopping
        }
    }

    /// Restart the running server: terminate, wait for port to free, relaunch.
    /// The whole sequence reports .restarting (cancellable via stop()).
    /// If no server is currently running, this is equivalent to start().
    func restart() {
        healthChecker.stop()
        guard processManager.isProcessRunning else {
            // Nothing live to stop — just start as an internal relaunch.
            start(source: .restart)
            return
        }
        processManager.restart()
        status = .restarting
    }

    /// The result of applying a Settings draft, so the caller reports what
    /// actually happened rather than re-deriving it from `status`.
    struct ApplyResult {
        enum Kind {
            case invalid
            case applied
            case appliedAndRestarting
        }

        let kind: Kind
        /// Set when part of the configuration could not be put into effect.
        /// Today only launch-at-login, which the system can refuse outright or
        /// leave pending the user's approval.
        let warning: String?

        static let invalid = ApplyResult(kind: .invalid, warning: nil)
    }

    /// The GGUF inspection `applyConfiguration` needs in order to validate a
    /// snapshot. Reading these opens and parses up to three files, so a caller
    /// that already did that work off the main thread should pass it in rather
    /// than make the main thread repeat it.
    struct InspectedProfiles {
        let model: DS4ModelProfile
        let support: DS4SupportProfile
        let vision: DS4VisionProfile
    }

    /// The outgoing configuration and its model family, used to remember
    /// resource paths only after Apply succeeds.
    struct ModelHistoryInspection {
        let previous: ServerConfiguration.Config
        let model: DS4ModelProfile?
    }

    /// Prepare history before committing a draft. A cache miss reads the
    /// outgoing model off the main thread, without changing applied state.
    func inspectModelHistory(
        for newConfig: ServerConfiguration.Config,
        model: DS4ModelProfile
    ) async -> ModelHistoryInspection {
        let previous = config.snapshot()
        let sameModel = ServerConfiguration.Config.modelKey(
            for: previous.modelPath,
            serverPath: previous.serverPath
        ) == ServerConfiguration.Config.modelKey(
            for: newConfig.modelPath,
            serverPath: newConfig.serverPath
        )
        let previousModel = sameModel ? model : await profileOfModel(in: previous)
        return ModelHistoryInspection(previous: previous, model: previousModel)
    }

    /// Apply a complete Settings snapshot. A live server is restarted so the
    /// new command line takes effect; a stopped server uses it on its next start.
    ///
    /// `inspected` is the profiles for `newConfig`'s model, support, and vision
    /// paths. Passing nil re-reads them here, on whatever thread called — which
    /// for a Settings Apply is the main one.
    ///
    /// `history` must describe the currently applied configuration. The caller
    /// can discard it if the draft changes while its inspection is in flight.
    ///
    /// Passing the profiles in reads no GGUF header at this point, so a GGUF
    /// replaced between inspection and this call is validated against the
    /// older profile. `ProcessManager.launch` re-reads and re-validates every path
    /// before the child starts, which is where that is caught.
    @discardableResult
    func applyConfiguration(
        _ newConfig: ServerConfiguration.Config,
        inspected: InspectedProfiles? = nil,
        history: ModelHistoryInspection
    ) -> ApplyResult {
        guard history.previous == config.snapshot() else { return .invalid }
        let serverDirectory = DS4ServerCommand.serverDirectory(for: newConfig.serverPath)
        let modelProfile = inspected?.model
            ?? GGUFModelInspector.profile(for: newConfig.modelPath, relativeTo: serverDirectory)
        let supportProfile = inspected?.support ?? GGUFModelInspector.supportProfile(
            for: newConfig.mtpPath,
            relativeTo: serverDirectory
        )
        let visionProfile = inspected?.vision ?? GGUFModelInspector.visionProfile(
            for: newConfig.visionPath,
            relativeTo: serverDirectory
        )
        guard newConfig.validationErrors(
            modelProfile: modelProfile,
            supportProfile: supportProfile,
            visionProfile: visionProfile
        ).isEmpty else { return .invalid }
        // Only a process that is actually alive needs restarting; .starting with
        // a dead process (a launch that never got off the ground) does not.
        let shouldRestart: Bool
        switch status {
        case .starting, .running, .restarting:
            shouldRestart = processManager.isProcessRunning
        case .stopped, .stopping, .error:
            shouldRestart = false
        }
        // ServerConfiguration is a separate reference object, so replacing its
        // value does not trigger this ObservableObject automatically. Publish
        // the mutation so Settings immediately recomputes its draft comparison.
        objectWillChange.send()
        config.replace(with: newConfig)
        let warning = config.save()?.message
        // Only now, with the configuration applied and its model validated,
        // does anything enter the recent menus.
        config.recordAppliedSelections(
            previous: history.previous,
            previousModel: history.model,
            appliedModel: modelProfile
        )
        recentSelections = config.recentSelections
        // The caller inspected this model for validation; reuse it instead of
        // making the status menu read the header again.
        primeActiveModelInfo(with: modelProfile)
        if shouldRestart {
            restart()
            return ApplyResult(kind: .appliedAndRestarting, warning: warning)
        }
        return ApplyResult(kind: .applied, warning: warning)
    }

    // MARK: - Port-wait relaunch (post-restart)

    private func startWhenPortAvailable() {
        let current = config.snapshot()
        processManager.startWhenPortAvailable(host: current.host, port: current.port)
        // When the port is free, onPortAvailable fires → start(source: .restart)
        // → launch + health polling. We keep .restarting until healthy.
    }

    // MARK: - Keep awake

    /// Reconciles the assertion with the preference, the run state, and the
    /// power source. Called from `status`'s observer, the preference setter, and
    /// the power-source notification, so every input that can change the answer
    /// arrives here.
    private func refreshKeepAwake() {
        let state = KeepAwakePolicy.state(
            preferenceEnabled: keepsAwakeWhileRunning,
            status: status,
            onExternalPower: externalPower.isOnExternalPower
        )
        if state == .active {
            idleSleepAssertion.hold()
        } else {
            idleSleepAssertion.release()
        }
        guard state != keepAwakeState else { return }
        keepAwakeState = state
    }

    // MARK: - Performance display

    /// PerformanceDisplayPolicy decides *when* the menu bar may change; this
    /// side owns the clock, the two timers, and the published value.
    private func receivePerformance(_ update: ServerPerformance) {
        guard showsPerformanceInMenuBar else { return }
        apply(performancePolicy.receive(update, now: Date()))
    }

    private func apply(_ effects: [PerformanceDisplayPolicy.Effect]) {
        for effect in effects {
            switch effect {
            case .display(let update):
                performance = update

            case .cancelPublish:
                performancePublishWorkItem?.cancel()
                performancePublishWorkItem = nil

            case .schedulePublish(let delay):
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.performancePublishWorkItem = nil
                    self.apply(self.performancePolicy.publishTimerFired(now: Date()))
                }
                performancePublishWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)

            case .cancelIdle:
                performanceIdleWorkItem?.cancel()
                performanceIdleWorkItem = nil

            case .scheduleIdle(let delay):
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.performanceIdleWorkItem = nil
                    self.apply(self.performancePolicy.idleTimerFired(now: Date()))
                }
                performanceIdleWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            }
        }
    }

    // MARK: - Log tail (for crash/error descriptions)

    private func lastLogReason() -> String {
        processManager.lastLogReason(logPath: config.logPath)
    }

    // MARK: - Notifications

    private func reportLaunchFailure(_ message: String) {
        guard let source = activeLaunchSource,
              let attemptID = activeLaunchAttemptID,
              reportedLaunchAttemptID != attemptID
        else { return }

        reportedLaunchAttemptID = attemptID
        activeLaunchSource = nil
        activeLaunchAttemptID = nil

        let failure = ServerLaunchFailure(message: message, source: source)
        onLaunchFailure?(failure)
        // A manual start has the user's attention already; the app layer shows
        // it a modal alert. Only an internal relaunch needs a notification.
        guard source == .restart else { return }
        postNotification(
            title: failure.notificationTitle,
            body: failure.notificationBody,
            categoryIdentifier: ServerNotification.launchFailureCategory,
            userInfo: [ServerNotification.settingsPaneKey: failure.settingsDestination.rawValue]
        )
    }

    /// Post a macOS notification so the user is informed of server state changes
    /// even when not watching the menubar icon.
    private func postNotification(
        title: String,
        body: String,
        categoryIdentifier: String? = nil,
        userInfo: [String: String] = [:]
    ) {
        if let notificationSink {
            notificationSink(title, body)
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let categoryIdentifier {
            content.categoryIdentifier = categoryIdentifier
        }
        content.userInfo = userInfo
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                os_log(.error, log: self.log, "unable to schedule notification: %{public}@",
                       error.localizedDescription)
            }
        }
    }
}

private enum TraceDeletionError: LocalizedError {
    case active

    var errorDescription: String? {
        "Stop the server or apply tracing off before deleting the active trace."
    }
}
