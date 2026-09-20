// SPDX-FileCopyrightText: Copyright 2026 James Martin
// SPDX-License-Identifier: MIT

import Foundation
import os.log

// MARK: - TerminationInfo
//
// Passed to the termination callback so the orchestrator (ServerManager) can
// decide the next status and whether to post a user notification.

struct TerminationInfo: Sendable {
    /// Process exited with status 0.
    let clean: Bool
    /// A stop/restart we initiated (not a spontaneous crash).
    let intentional: Bool
    /// The stop was the first half of a restart — relaunch once the port is free.
    let pendingRestart: Bool
    /// If set, the failure description recorded before we terminated the process
    /// (for example, an unreachable running server). The orchestrator uses it instead of the
    /// generic "killed by signal" message.
    let failureReason: String?
}

// MARK: - ProcessManager
//
/// Handles the ds4-server child-process lifecycle: launch, terminate, restart,
/// port-wait polling, log-file management. It is *stateless with respect to the
/// UI* — it reports transitions via closures so the owning ServerManager can
/// publish @Published status changes on the main actor.

@MainActor
final class ProcessManager {
    // MARK: - Callbacks (wired by ServerManager)

    /// Called when the process lifecycle changes status (starting, stopping, etc.).
    var onStatusChange: ((ServerStatus) -> Void)?

    /// Called when the child process has fully terminated.
    var onTerminated: ((TerminationInfo) -> Void)?

    /// Called by startWhenPortAvailable once the listen port is free.
    /// The orchestrator should respond by calling its own start() so health
    /// polling is wired up correctly.
    var onPortAvailable: (() -> Void)?

    /// Called for failures that prevent a launch from creating a child process.
    /// ServerManager adds the launch source and chooses the user-facing route.
    var onLaunchFailure: ((String) -> Void)?

    /// Called when ds4-server's log reports a request phase or average rate.
    var onPerformanceChange: ((ServerPerformance) -> Void)?

    // MARK: - Private state

    private var process: Process?
    /// Identifies the launch that owns `process` and `logFileHandle`. A
    /// termination handler carrying a stale ID belongs to a run that has already
    /// been replaced, and must not finalize the current run's state.
    private var currentRunID: UUID?
    private var logFileHandle: FileHandle?
    private var logWriteSource: DispatchSourceFileSystemObject?
    private var logSizeCheckScheduled = false
    private var logMonitorID = UUID()
    private var logRotationMonitorID: UUID?
    private var activeLogPath: String?
    private var performanceMonitoringEnabled = false
    private let performanceReader = ServerPerformanceLogReader()
    private let performanceQueue = DispatchQueue(
        label: "com.jiiim.ds-menu-bar.performance-log",
        qos: .utility
    )
    private let logRotationQueue = DispatchQueue(
        label: "com.jiiim.ds-menu-bar.log-rotation",
        qos: .utility
    )
    private let log = OSLog(subsystem: "com.jiiim.ds-menu-bar", category: "server")

    /// True while a stop/restart we initiated is in flight; the resulting
    /// termination is then treated as clean rather than a crash.
    private var intentionalStop = false

    /// When set, the next full termination launches a fresh process (see
    /// restart()). Cleared once the termination handler picks it up.
    private var pendingRestart = false

    /// Set to the failure description right before WE terminate a server we
    /// detected as failed (for example, unreachable). The termination
    /// handler uses it to report the real cause instead of a misleading
    /// "killed by signal".
    private var failureReason: String?

    /// Timer used to poll for port availability after a restart's stop phase.
    private var restartTimer: DispatchSourceTimer?

    // MARK: - Launch

    /// Build and run the ds4-server child process with the given configuration.
    /// Returns the health-check URL on success, or nil if pre-flight checks or
    /// launch failed (status is set via onStatusChange in that case).
    @discardableResult
    func launch(configuration: ServerConfiguration.Config) -> URL? {
        dispatchPrecondition(condition: .onQueue(.main))
        // A new launch owns the lifecycle flags outright. Every path that reaches
        // here today runs after the termination handler has already cleared them
        // on the main queue, so this is belt-and-braces — but it means a future
        // caller cannot inherit a dead process's stop or restart intent and have
        // the next termination misreported because of it.
        intentionalStop = false
        pendingRestart = false
        failureReason = nil
        // A fresh start supersedes any pending restart-wait.
        restartTimer?.cancel(); restartTimer = nil

        let resolvedServerPath = DS4ServerCommand.expandingTilde(configuration.serverPath)
        let serverDir = DS4ServerCommand.serverDirectory(for: configuration.serverPath)
        let resolvedModelPath = DS4ServerCommand.resolving(configuration.modelPath, relativeTo: serverDir)
        let resolvedMTPPath = DS4ServerCommand.resolving(configuration.mtpPath, relativeTo: serverDir)
        let resolvedVisionPath = DS4ServerCommand.resolving(configuration.visionPath, relativeTo: serverDir)

        // Persisted or externally edited configuration must not bypass basic
        // file checks at the process boundary.
        guard FileManager.default.isExecutableRegularFile(atPath: resolvedServerPath) else {
            return failLaunch("ds4-server not found or not executable at \(resolvedServerPath)")
        }
        let modelProfile: DS4ModelProfile
        switch DS4SelectionValidation.modelValidation(for: resolvedModelPath) {
        case .success(let profile):
            modelProfile = profile
        case .failure(let error):
            return failLaunch(error.launchMessage(at: resolvedModelPath))
        }
        let supportProfile = GGUFModelInspector.supportProfile(
            for: configuration.mtpPath,
            relativeTo: serverDir
        )
        let visionProfile = GGUFModelInspector.visionProfile(
            for: configuration.visionPath,
            relativeTo: serverDir
        )
        if let firstError = configuration.firstValidationError(
            modelProfile: modelProfile,
            supportProfile: supportProfile,
            visionProfile: visionProfile
        ) {
            return failLaunch("Invalid server configuration: \(firstError)")
        }

        // Pre-flight: give precise errors instead of a cryptic non-zero exit.
        // Every path checked here is already absolute — DS4ServerCommand.resolving
        // anchored relative ones to serverDir, which is the working directory set
        // on the child below — so these checks see the same files the server will.
        let usesExternalSupport =
            (configuration.mtpMode == .external && modelProfile.supportsExternalMTP) ||
            (configuration.mtpMode == .dspark && modelProfile.supportsDSpark)
        if usesExternalSupport {
            guard FileManager.default.isReadableRegularFile(atPath: resolvedMTPPath) else {
                return failLaunch("MTP model not readable at \(resolvedMTPPath)")
            }
            // Validation above catches readable mismatches. Keep this explicit
            // guard beside the filesystem check so a launch can never silently
            // hand ds4-server a support model for the other runtime.
            let expectedKind: DS4SupportKind = configuration.mtpMode == .dspark
                ? .dspark
                : .legacyMTP
            let detected = GGUFModelInspector.supportProfile(for: resolvedMTPPath)
            guard detected.kind == expectedKind else {
                return failLaunch(
                    configuration.mtpMode == .dspark
                        ? "Selected MTP model is not a DSpark support GGUF"
                        : "Selected MTP model is not a legacy MTP support GGUF"
                )
            }
        }
        if modelProfile.supportsVision && configuration.visionEnabled &&
            !configuration.visionPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard FileManager.default.isReadableRegularFile(atPath: resolvedVisionPath) else {
                return failLaunch("vision model not readable at \(resolvedVisionPath)")
            }
            guard visionProfile.isCompatible(with: modelProfile) else {
                return failLaunch("vision GGUF is incompatible with \(modelProfile.displayName) at \(resolvedVisionPath)")
            }
        }

        var components = URLComponents()
        components.scheme = "http"
        components.host = DS4ServerCommand.healthProbeHost(for: configuration.host)
        components.port = configuration.port
        components.path = "/v1/models"
        guard let healthURL = components.url else {
            return failLaunch("Unable to construct a health-check URL for host \(configuration.host)")
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: resolvedServerPath)

        let args = DS4ServerCommand.arguments(
            configuration: configuration,
            resolvedModelPath: resolvedModelPath,
            resolvedMTPPath: resolvedMTPPath,
            resolvedVisionPath: resolvedVisionPath,
            modelProfile: modelProfile,
            supportProfile: supportProfile,
            visionProfile: visionProfile
        )
        proc.arguments = args
        let environmentOverrides = DS4ServerCommand.environmentOverrides(
            configuration: configuration,
            modelProfile: modelProfile
        )
        proc.environment = DS4ServerCommand.launchEnvironment(
            configuration: configuration,
            modelProfile: modelProfile
        )

        // Working directory: the server binary's directory.
        proc.currentDirectoryURL = URL(fileURLWithPath: serverDir)

        // Open the log in append-only mode — do NOT truncate, so logs
        // accumulate across restarts. Both stdout and stderr go straight to it.
        let logPathResolved = DS4ServerCommand.expandingTilde(configuration.logPath)
        let fm = FileManager.default
        // Ensure the parent directory exists with owner-only permissions.
        let logDir = (logPathResolved as NSString).deletingLastPathComponent
        Self.createOwnerOnlyDirectory(logDir, fm: fm)
        // KV cache files hold prompt text and model state, and the default
        // location is inside world-writable /tmp. Create the directory here so
        // it is owner-only rather than whatever umask ds4-server runs with.
        if configuration.kvDiskEnabled {
            Self.createOwnerOnlyDirectory(
                DS4ServerCommand.expandingTilde(configuration.kvDiskDir),
                fm: fm
            )
        }
        // Rotate an oversized log left by an older run before opening the live
        // append descriptor. Runtime monitoring below handles later growth.
        let maxLogBytes = configuration.logMaxSizeMB * 1024 * 1024
        if let size = (try? fm.attributesOfItem(atPath: logPathResolved))?[.size] as? Int,
           size >= maxLogBytes {
            let startupFD = open(logPathResolved, O_WRONLY | O_APPEND)
            if startupFD >= 0 {
                do {
                    try Self.rotateLog(
                        at: logPathResolved,
                        maximumBytes: maxLogBytes,
                        activeFileDescriptor: startupFD
                    )
                } catch {
                    // Not fatal — the launch proceeds against the oversized log
                    // rather than refusing to start over a housekeeping failure.
                    os_log(
                        .error,
                        log: log,
                        "startup log rotation failed: %{public}@",
                        String(describing: error)
                    )
                }
                close(startupFD)
            }
        }
        let fd = open(logPathResolved, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard fd >= 0 else {
            cleanup()
            return failLaunch("Unable to open server log at \(logPathResolved)")
        }
        // Bound locally as well as stored: the termination handler closes *this*
        // handle, never whatever `logFileHandle` happens to hold when it fires.
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        logFileHandle = handle
        // Enforce owner-only perms even if the file pre-existed with looser modes.
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logPathResolved)
        proc.standardOutput = handle

        // Launch header — exactly what was run and where.
        writeLog("=== dsmenubar launch \(Self.timestamp()) ===\n")
        writeLog("exec: \(resolvedServerPath)\n")
        writeLog("cwd:  \(serverDir)\n")
        if !environmentOverrides.isEmpty {
            let renderedEnvironment = DS4ServerCommand.managedQwenEnvironmentKeys.compactMap { key in
                environmentOverrides[key].map { "\(key)=\($0)" }
            }.joined(separator: " ")
            writeLog("env:  \(renderedEnvironment)\n")
        }
        writeLog("argv: \(args.joined(separator: " "))\n")
        writeLog("---\n")

        // Both stdout and stderr go directly to the log file — no pipe,
        // no dispatch source, no race between async reads and termination.
        proc.standardError = handle

        // A trace records prompts, generated output, and tool calls, so it is at
        // least as sensitive as the log: create it owner-only before the server
        // gets a chance to create it with the default umask.
        if configuration.traceEnabled,
           !configuration.tracePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let tracePath = DS4ServerCommand.expandingTilde(configuration.tracePath)
            Self.createOwnerOnlyDirectory((tracePath as NSString).deletingLastPathComponent, fm: fm)
            if !fm.fileExists(atPath: tracePath) {
                fm.createFile(atPath: tracePath, contents: nil,
                              attributes: [.posixPermissions: 0o600])
            }
        }

        // Identifies this launch for the termination handler. A later launch
        // mints a new one, which is how a late handler recognizes that the
        // state it would finalize is no longer its own.
        let runID = UUID()

        // Fires on a Foundation-internal queue. It touches none of this class's
        // state there: every field below is main-queue-only, and closing the log
        // from the callback queue raced `cleanup()` into a double close.
        proc.terminationHandler = { [weak self] p in
            // Both streams write directly to the log file, so there's no pipe
            // to drain — the termination handler only needs to close the file.
            let clean = (p.terminationReason == .exit && p.terminationStatus == 0)
            // Resolve the weak reference here rather than inside the hop: the
            // main block then captures an immutable binding instead of this
            // closure's mutable capture.
            let manager = self

            DispatchQueue.main.async {
                guard let self = manager else {
                    handle.closeFile()
                    return
                }
                // A relaunch may already own `logFileHandle` and `process` by
                // the time this lands. Close only the handle this run opened and
                // leave the newer run's state alone — finalizing it here would
                // close the live log and drop the live process reference.
                //
                // Keyed on the run rather than on `process === p`, because
                // `terminate()` nils `process` when it finds the child already
                // reaped; that path still owes the orchestrator its callback.
                guard self.currentRunID == runID else {
                    handle.closeFile()
                    return
                }
                self.currentRunID = nil
                handle.closeFile()
                self.stopLogMonitoring()
                let wasIntentional = self.intentionalStop
                let wasPendingRestart = self.pendingRestart
                let reason = self.failureReason
                self.intentionalStop = false
                self.pendingRestart = false
                self.failureReason = nil
                self.logFileHandle = nil
                self.process = nil

                self.restartTimer?.cancel(); self.restartTimer = nil

                // Notify the orchestrator; it decides the next status.
                self.onTerminated?(TerminationInfo(
                    clean: clean,
                    intentional: wasIntentional,
                    pendingRestart: wasPendingRestart,
                    failureReason: reason
                ))
            }
        }

        do {
            try proc.run()
            process = proc
            currentRunID = runID
            startLogMonitoring(
                path: logPathResolved,
                maximumBytes: maxLogBytes,
                process: proc,
                fileDescriptor: fd
            )
            return healthURL
        } catch {
            let message = "failed to launch: \(error.localizedDescription)"
            writeLog("\(message)\n")
            cleanup()
            return failLaunch(message)
        }
    }

    private func failLaunch(_ message: String) -> URL? {
        onStatusChange?(.error(message))
        onLaunchFailure?(message)
        return nil
    }

    // MARK: - Terminate

    /// Send SIGTERM to the child process. Also the cancel path for an in-progress
    /// start or restart — the caller should have cancelled any health/startup
    /// timers before invoking this.
    func terminate() {
        dispatchPrecondition(condition: .onQueue(.main))
        restartTimer?.cancel(); restartTimer = nil

        guard let proc = process, proc.isRunning else {
            // No live child (already stopped/errored, or waiting on a port).
            process = nil
            return
        }

        intentionalStop = true
        cancelLogRotation(for: proc)
        proc.terminate()  // SIGTERM
        // No forced kill on a timer: we let the server shut down and watch for it
        // via the termination handler, which finalizes state.
    }

    /// Convenience: set `failureReason` then terminate. Used by HealthChecker
    /// when a running server becomes unreachable.
    func terminate(withFailureReason reason: String) {
        failureReason = reason
        terminate()
    }

    // MARK: - Restart

    /// Terminate the running server so a relaunch can follow once its port is
    /// free. The caller should set status to .restarting.
    ///
    /// Precondition: a process is running. The orchestrator routes the
    /// not-running case to launch() directly, so there is no launch fallback
    /// here — and none of the launch config is needed, since the relaunch is
    /// wired up by the orchestrator (onPortAvailable → its own start()).
    func restart() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let proc = process, proc.isRunning else { return }
        pendingRestart = true
        intentionalStop = true
        cancelLogRotation(for: proc)
        proc.terminate()  // SIGTERM; the termination handler picks up the relaunch
        // The actual relaunch happens in startWhenPortAvailable, triggered by
        // the termination callback when pendingRestart is true.
    }

    // MARK: - Port availability

    /// Start, but only after the listen port is actually free. The old process
    /// has already exited by the time we get here, yet the kernel can hold its
    /// port briefly (e.g. TIME_WAIT from recent health-check connections), and
    /// binding too soon makes the replacement ds4-server fail. Poll the real
    /// port state — no fixed delay — and launch the moment it can be bound.
    ///
    /// When the port becomes available we invoke `onPortAvailable` rather than
    /// launching directly, so the orchestrator can set up health polling.
    func startWhenPortAvailable(host: String, port: Int) {
        dispatchPrecondition(condition: .onQueue(.main))
        if Self.isListenPortAvailable(host: host, port: port) {
            onPortAvailable?()
            return
        }
        // The probe can be stricter than the server's own bind — a host that
        // resolves to several addresses is probed on all of them — so something
        // else holding the port would otherwise pin the app in .restarting with
        // no recovery but a manual Stop. Past the deadline, relaunch anyway and
        // let ds4-server's own bind failure land in the log where it belongs.
        let deadline = Date().addingTimeInterval(Self.portWaitTimeout)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.2, repeating: 0.2)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            let free = Self.isListenPortAvailable(host: host, port: port)
            guard free || Date() >= deadline else { return }
            if !free {
                os_log(.error, log: self.log,
                       "port %d still held after %.0fs; relaunching anyway",
                       port, Self.portWaitTimeout)
            }
            self.restartTimer?.cancel(); self.restartTimer = nil
            self.onPortAvailable?()
        }
        restartTimer = timer
        timer.resume()
    }

    /// How long the post-restart port wait may run before relaunching regardless.
    private static let portWaitTimeout: TimeInterval = 10

    /// Whether the configured host:port can be bound right now — i.e. the old
    /// server has fully released it. Deliberately mirrors the server's own bind
    /// (no SO_REUSEADDR): the real ds4-server cannot bind over a socket still in
    /// TIME_WAIT, so neither must this probe. Adding SO_REUSEADDR here would make
    /// the probe report the port "available" during TIME_WAIT while a relaunch
    /// would still fail with EADDRINUSE — defeating the point of the port-wait.
    ///
    /// The host is resolved rather than parsed as a dotted quad: `localhost` and
    /// any other name used to have no numeric form and fell back to INADDR_ANY,
    /// which probes every interface instead of the one the server binds. Each
    /// resolved address is probed, IPv4 and IPv6 alike, because any of them could
    /// be the one the server ends up on.
    ///
    /// Static and free of instance state so it can be unit-tested directly.
    nonisolated static func isListenPortAvailable(host: String, port: Int) -> Bool {
        // Out of range, or 0 (which always binds to an ephemeral port and would
        // report a meaningless "available"): let launch surface the real error.
        guard let p = UInt16(exactly: port), p > 0 else { return true }

        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var resolved: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(p), &hints, &resolved) == 0, resolved != nil else {
            return true  // unresolvable: launch reports it far more clearly than a stalled wait
        }
        defer { freeaddrinfo(resolved) }

        var candidate = resolved
        while let current = candidate {
            let fd = socket(current.pointee.ai_family,
                            current.pointee.ai_socktype,
                            current.pointee.ai_protocol)
            // A family this machine cannot open (no IPv6, say) is not a port
            // conflict — skip it rather than reporting the port as held.
            if fd >= 0 {
                let rc = bind(fd, current.pointee.ai_addr, current.pointee.ai_addrlen)
                close(fd)
                if rc != 0 { return false }
            }
            candidate = current.pointee.ai_next
        }
        return true
    }

    // MARK: - Logging

    private func startLogMonitoring(
        path: String,
        maximumBytes: Int,
        process monitoredProcess: Process,
        fileDescriptor: Int32
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        stopLogMonitoring()
        let monitorID = UUID()
        logMonitorID = monitorID
        activeLogPath = path

        if performanceMonitoringEnabled {
            performanceQueue.async { [performanceReader] in
                performanceReader.start(path: path)
            }
        }

        let monitorFileDescriptor = dup(fileDescriptor)
        guard monitorFileDescriptor >= 0 else {
            os_log(.error, log: log, "unable to monitor server log: %{public}@",
                   String(cString: strerror(errno)))
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: monitorFileDescriptor,
            eventMask: .write,
            queue: .main
        )
        source.setEventHandler { [weak self, weak monitoredProcess] in
            guard let self, let monitoredProcess else { return }
            self.readPerformanceUpdates(monitorID: monitorID)
            self.scheduleLogSizeCheck(
                monitorID: monitorID,
                path: path,
                maximumBytes: maximumBytes,
                process: monitoredProcess,
                fileDescriptor: fileDescriptor
            )
        }
        source.setCancelHandler {
            close(monitorFileDescriptor)
        }
        logWriteSource = source
        source.resume()
    }

    private func stopLogMonitoring() {
        dispatchPrecondition(condition: .onQueue(.main))
        logWriteSource?.cancel()
        logWriteSource = nil
        logSizeCheckScheduled = false
        logMonitorID = UUID()
        logRotationMonitorID = nil
        activeLogPath = nil
        performanceQueue.async { [performanceReader] in
            performanceReader.stop()
        }
        // Nothing is reported while the display is off, so a launch or an exit
        // does not need to announce an idle nobody is showing.
        if performanceMonitoringEnabled {
            onPerformanceChange?(.idle)
        }
    }

    /// Enable or disable incremental performance parsing without changing the
    /// server process. Enabling during a request starts at EOF and receives the
    /// next complete progress record rather than presenting stale log history.
    func setPerformanceMonitoring(_ enabled: Bool) {
        guard enabled != performanceMonitoringEnabled else { return }
        performanceMonitoringEnabled = enabled

        guard enabled else {
            performanceQueue.async { [performanceReader] in
                performanceReader.stop()
            }
            onPerformanceChange?(.idle)
            return
        }

        // With no server running there is nothing to read yet; the flag above
        // is enough, because startLogMonitoring opens the reader at launch.
        guard let path = activeLogPath else { return }
        performanceQueue.async { [performanceReader] in
            performanceReader.start(path: path)
        }
    }

    private func readPerformanceUpdates(monitorID: UUID) {
        guard performanceMonitoringEnabled else { return }
        performanceQueue.async { [weak self, performanceReader] in
            let updates = performanceReader.readAvailable()
            guard !updates.isEmpty else { return }
            // Resolved here so the main hop captures an immutable binding
            // rather than this closure's mutable capture.
            let manager = self
            DispatchQueue.main.async {
                guard let self = manager,
                      self.performanceMonitoringEnabled,
                      self.logMonitorID == monitorID
                else { return }
                for update in updates {
                    self.onPerformanceChange?(update)
                }
            }
        }
    }

    private func rewindPerformanceReader() {
        guard performanceMonitoringEnabled else { return }
        performanceQueue.async { [performanceReader] in
            performanceReader.rewind()
        }
    }

    /// A server suspended for rotation must be resumed before termination. The
    /// background copy will see its invalidated rotation ID and discard its
    /// temporary file instead of touching a later process's log.
    private func cancelLogRotation(for monitoredProcess: Process) {
        guard logRotationMonitorID != nil else { return }
        logRotationMonitorID = nil
        _ = monitoredProcess.resume()
    }

    /// Coalesce bursts so log-heavy servers cause at most one stat per second.
    private func scheduleLogSizeCheck(
        monitorID: UUID,
        path: String,
        maximumBytes: Int,
        process monitoredProcess: Process,
        fileDescriptor: Int32
    ) {
        guard monitorID == logMonitorID, !logSizeCheckScheduled else { return }
        logSizeCheckScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self, weak monitoredProcess] in
            guard let self else { return }
            guard monitorID == self.logMonitorID else { return }
            self.logSizeCheckScheduled = false
            guard let monitoredProcess else { return }
            self.rotateLogIfNeeded(
                monitorID: monitorID,
                path: path,
                maximumBytes: maximumBytes,
                process: monitoredProcess,
                fileDescriptor: fileDescriptor
            )
        }
    }

    private func rotateLogIfNeeded(
        monitorID: UUID,
        path: String,
        maximumBytes: Int,
        process monitoredProcess: Process,
        fileDescriptor: Int32
    ) {
        guard monitorID == logMonitorID,
              logRotationMonitorID == nil,
              process === monitoredProcess,
              monitoredProcess.isRunning,
              let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size]
                as? NSNumber,
              size.uint64Value >= UInt64(maximumBytes)
        else { return }

        logRotationMonitorID = monitorID
        guard monitoredProcess.suspend() else {
            logRotationMonitorID = nil
            return
        }

        logRotationQueue.async { [weak self, weak monitoredProcess] in
            let result = Result {
                try Self.makeLogBackup(
                    at: path,
                    maximumBytes: maximumBytes
                )
            }
            // Resolved here so the main hop captures immutable bindings rather
            // than this closure's mutable captures.
            let manager = self
            let rotatedProcess = monitoredProcess
            DispatchQueue.main.async {
                guard let self = manager,
                      let monitoredProcess = rotatedProcess,
                      self.logRotationMonitorID == monitorID,
                      self.process === monitoredProcess,
                      monitoredProcess.isRunning
                else {
                    if case .success(let temporaryURL) = result {
                        try? FileManager.default.removeItem(at: temporaryURL)
                    }
                    _ = rotatedProcess?.resume()
                    return
                }

                do {
                    let temporaryURL = try result.get()
                    defer { try? FileManager.default.removeItem(at: temporaryURL) }
                    try Self.installLogBackup(
                        temporaryURL,
                        at: path,
                        activeFileDescriptor: fileDescriptor
                    )
                    self.rewindPerformanceReader()
                } catch {
                    os_log(
                        .error,
                        log: self.log,
                        "log rotation failed: %{public}@",
                        String(describing: error)
                    )
                }
                self.logRotationMonitorID = nil
                _ = monitoredProcess.resume()
            }
        }
    }

    /// Preserve the newest bytes as `.1`, replace that backup atomically, and
    /// truncate the active inode so an inherited append descriptor stays valid.
    nonisolated static func rotateLog(
        at path: String,
        maximumBytes: Int,
        activeFileDescriptor: Int32
    ) throws {
        let temporaryURL = try makeLogBackup(at: path, maximumBytes: maximumBytes)
        do {
            try installLogBackup(
                temporaryURL,
                at: path,
                activeFileDescriptor: activeFileDescriptor
            )
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    /// Copy the newest complete segment while the server is suspended. The
    /// caller installs it only if this rotation still owns the active process.
    nonisolated private static func makeLogBackup(at path: String, maximumBytes: Int) throws -> URL {
        let fm = FileManager.default
        let activeURL = URL(fileURLWithPath: path)
        let temporaryURL = URL(fileURLWithPath: path + ".1.tmp-\(UUID().uuidString)")
        var removeTemporaryFile = true
        defer {
            if removeTemporaryFile {
                try? fm.removeItem(at: temporaryURL)
            }
        }

        guard fm.createFile(
            atPath: temporaryURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let input = try FileHandle(forReadingFrom: activeURL)
        let output = try FileHandle(forWritingTo: temporaryURL)
        defer {
            try? input.close()
            try? output.close()
        }

        let size = try input.seekToEnd()
        let retainedBytes = min(size, UInt64(maximumBytes))
        try input.seek(toOffset: size - retainedBytes)
        var remaining = retainedBytes
        while remaining > 0 {
            let count = Int(min(remaining, 1024 * 1024))
            guard let data = try input.read(upToCount: count), !data.isEmpty else {
                throw CocoaError(.fileReadUnknown)
            }
            try output.write(contentsOf: data)
            remaining -= UInt64(data.count)
        }
        try output.synchronize()

        // The defer above removes failed copies. A successful caller takes
        // ownership of the temporary path and atomically installs it.
        removeTemporaryFile = false
        return temporaryURL
    }

    nonisolated private static func installLogBackup(
        _ temporaryURL: URL,
        at path: String,
        activeFileDescriptor: Int32
    ) throws {
        let backupURL = URL(fileURLWithPath: path + ".1")
        let renameResult = temporaryURL.path.withCString { temporaryPath in
            backupURL.path.withCString { backupPath in
                rename(temporaryPath, backupPath)
            }
        }
        guard renameResult == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard ftruncate(activeFileDescriptor, 0) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    /// Create `directory` (and any missing parents) owner-only. A directory that
    /// already exists is left as-is: the log and trace paths are user-chosen, and
    /// silently narrowing the permissions of an existing directory — which may be
    /// a shared or project folder — is not this app's call to make.
    nonisolated static func createOwnerOnlyDirectory(_ directory: String, fm: FileManager) {
        guard !directory.isEmpty, !fm.fileExists(atPath: directory) else { return }
        try? fm.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
    }

    private func writeLog(_ s: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let handle = logFileHandle, let data = s.data(using: .utf8) else { return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            // Best-effort, but a silent failure here leaves a log that looks
            // merely empty — which reads as "the server said nothing" rather
            // than "the app could not write".
            os_log(
                .error,
                log: log,
                "unable to write to server log: %{public}@",
                String(describing: error)
            )
        }
    }

    /// Truncate the active log in place so a running server can keep writing to
    /// its existing append-only file descriptor, then remove the rotated copy.
    func clearLogCollection(logPath: String) throws {
        guard logRotationMonitorID == nil else {
            throw CocoaError(.fileWriteUnknown)
        }
        let path = (logPath as NSString).expandingTildeInPath
        let fm = FileManager.default
        if fm.fileExists(atPath: path) {
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            try handle.truncate(atOffset: 0)
            rewindPerformanceReader()
        }

        let rotatedPath = path + ".1"
        if fm.fileExists(atPath: rotatedPath) {
            try fm.removeItem(atPath: rotatedPath)
        }
    }

    /// Remove an inactive request trace. Refuse non-files so a mistaken custom
    /// path cannot recursively delete a directory.
    func deleteTraceFile(tracePath: String) throws {
        let path = (tracePath as NSString).expandingTildeInPath
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDirectory) else { return }
        guard !isDirectory.boolValue, fm.isReadableRegularFile(atPath: path) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try fm.removeItem(atPath: path)
    }

    /// The server diagnostic for the most recent failed launch. Argument-parser
    /// failures print the actual error first and then a complete help screen, so
    /// taking the final log line would report an example command instead.
    func launchFailureReason(logPath: String) -> String {
        let lines = recentLogLines(logPath: logPath)
        guard !lines.isEmpty else { return "" }

        let launchStart = lines.lastIndex(where: {
            $0.hasPrefix("=== dsmenubar launch ")
        })
        let currentLaunch = launchStart.map { lines.dropFirst($0 + 1) } ?? lines[...]
        let output = currentLaunch.filter { !Self.isLaunchMetadata($0) }
        guard !output.isEmpty else { return "" }

        let usageIndex = output.firstIndex(where: { $0.hasPrefix("Usage:") })
        let beforeUsage = usageIndex.map { output[..<$0] } ?? output[...]
        let diagnosticTerms = [
            "error", "fatal", "fail", "unknown", "invalid", "unsupported",
            "not found", "no such file", "unable", "cannot", "missing",
        ]
        if let diagnostic = beforeUsage.last(where: { line in
            let lowercased = line.lowercased()
            return diagnosticTerms.contains(where: lowercased.contains)
        }) {
            return diagnostic
        }

        // Help-producing parse failures conventionally print their diagnostic
        // before the program name and description. Without a help block, the
        // last line remains the best indication of a later startup failure.
        if usageIndex != nil {
            return beforeUsage.first ?? ""
        }
        return beforeUsage.last ?? output.last ?? ""
    }

    /// The last meaningful line of the log — usually the fatal message for a
    /// process that had already reached its running state.
    func lastLogReason(logPath: String) -> String {
        recentLogLines(logPath: logPath)
            .filter { !Self.isLaunchMetadata($0) }
            .last ?? ""
    }

    private func recentLogLines(logPath: String) -> [String] {
        let path = (logPath as NSString).expandingTildeInPath
        // Read only the tail: the log can grow large and we only need the last
        // meaningful line. A first line sliced by the byte window is harmless —
        // lossy UTF-8 decoding tolerates it and it gets filtered out anyway.
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        let tailBytes: UInt64 = 64 * 1024
        let end = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: end > tailBytes ? end - tailBytes : 0)
        guard let data = try? handle.readToEnd() else { return [] }
        let content = String(decoding: data, as: UTF8.self)
        return content
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func isLaunchMetadata(_ line: String) -> Bool {
        line.hasPrefix("===") || line.hasPrefix("exec:") ||
            line.hasPrefix("cwd:") || line.hasPrefix("env:") ||
            line.hasPrefix("argv:") || line == "---"
    }

    // MARK: - Cleanup

    /// Release all resources associated with the current process (file handles,
    /// timers, process reference). Called after launch failure or when the
    /// orchestrator decides not to restart.
    func cleanup() {
        dispatchPrecondition(condition: .onQueue(.main))
        stopLogMonitoring()
        process = nil
        currentRunID = nil
        failureReason = nil
        logFileHandle?.closeFile()
        logFileHandle = nil
        restartTimer?.cancel(); restartTimer = nil
    }

    // MARK: - Process state queries

    /// Whether the child process exists and is running.
    var isProcessRunning: Bool {
        guard let proc = process else { return false }
        return proc.isRunning
    }

    /// The process identifier of the currently running server, if any.
    var currentPID: Int32? {
        guard let proc = process, proc.isRunning else { return nil }
        return proc.processIdentifier
    }

    // MARK: - Utilities

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private static func timestamp() -> String {
        dateFormatter.string(from: Date())
    }
}
