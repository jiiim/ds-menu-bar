// SPDX-FileCopyrightText: Copyright James Martin and DS Menu Bar contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - HealthChecker

/// Polls the ds4-server HTTP endpoint (/v1/models) to detect readiness and
/// ongoing health.
///
/// This class is *stateless with respect to the UI* — it reports results via
/// closures so the owning ServerManager can publish @Published status changes
/// on the main actor.
@MainActor
final class HealthChecker {
    // MARK: - Callbacks (wired by ServerManager)

    /// Called when a health check succeeds for a server that was starting up.
    /// The orchestrator resolves the PID to report in the .running status.
    var onHealthSuccess: (() -> Void)?

    /// Called when a health check fails while the server was already running.
    var onUnreachable: ((String) -> Void)?

    /// Called once per start when a startup has been running for
    /// `stallAdvisoryInterval` without the listener coming up. This is an
    /// advisory only — nothing is terminated — so the user learns that a long
    /// startup is still in progress instead of watching an unchanging status.
    var onStartupStalled: (() -> Void)?

    /// A closure that can return whether the server is still in a starting-up
    /// state (.starting or .restarting).
    var isStartingUp: (() -> Bool)?

    /// A closure that can return whether the server was in .running state.
    var isRunning: (() -> Bool)?

    // MARK: - Private state

    /// Poll cadence while starting/restarting — fast, so the UI confirms
    /// "running" promptly once the server answers.
    private let fastInterval: Int
    /// Poll cadence once a run has been confirmed healthy.
    private let steadyInterval: Int
    /// How long a startup may run before the user gets an advisory. Chosen to be
    /// well past a normal large-model load, since it must never read as a
    /// deadline — a startup past this point is still perfectly valid.
    let stallAdvisoryInterval: TimeInterval

    /// A private session rather than `URLSession.shared`. The shared session's
    /// cookie and cache storage gives the process a CFNetwork storage database,
    /// and macOS attributes the assertion taken while that database is flushed
    /// to this app — which is why Activity Monitor reported DS Menu Bar as
    /// preventing sleep despite the app holding no assertion of its own. A
    /// loopback readiness probe needs neither cookies nor a response cache.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    /// Consecutive failed polls required before a confirmed-healthy server is
    /// terminated. One failed poll used to be enough, which made any two-second
    /// stall fatal — a wake from sleep lands a poll while the server's pages are
    /// still being faulted back in, and nothing here knows a sleep happened.
    /// Three polls cost at most ~30s of extra detection latency, which nothing
    /// is waiting on, and the server they protect can take minutes to reload.
    let failureThreshold: Int

    /// The defaults are the production values; every one of them is a duration
    /// or a count that a test would otherwise have to wait out in real time.
    init(
        fastInterval: Int = 2,
        steadyInterval: Int = 10,
        stallAdvisoryInterval: TimeInterval = 600,
        failureThreshold: Int = 3
    ) {
        self.fastInterval = fastInterval
        self.steadyInterval = steadyInterval
        self.stallAdvisoryInterval = stallAdvisoryInterval
        self.failureThreshold = failureThreshold
    }

    /// Readable for tests; the run is only ever advanced or cleared here.
    private(set) var consecutiveFailures = 0
    private var healthTimer: DispatchSourceTimer?
    private var healthURL: URL?
    private var startupBegan: Date?
    private var stallAdvisoryPosted = false

    /// Bumped whenever polling starts, stops, or changes cadence. A response
    /// carrying a superseded generation is discarded, so a request still in
    /// flight when the run it belonged to ended cannot act on the one that
    /// replaced it — in particular, a slow failure landing after a success can
    /// no longer terminate a server that was just confirmed healthy.
    ///
    /// This and every other field here are touched only on the main queue.
    private var generation = 0

    // MARK: - Polling control

    /// Begin polling `url` for readiness. There is deliberately no startup
    /// deadline: ds4-server loads the engine and requests Metal residency before
    /// opening its HTTP listener, and that duration depends heavily on model,
    /// memory pressure, and the Mac's current state.
    func startPolling(url: URL) {
        healthURL = url
        consecutiveFailures = 0
        startupBegan = Date()
        stallAdvisoryPosted = false
        scheduleHealthTimer(interval: fastInterval)
    }

    /// Stop all timers and reset state. Called when the server is stopped or
    /// restarted.
    func stop() {
        generation &+= 1
        healthTimer?.cancel(); healthTimer = nil
        consecutiveFailures = 0
        healthURL = nil
        startupBegan = nil
        stallAdvisoryPosted = false
    }

    /// Recreate the health-poll timer at the given cadence. `firstDeadline`
    /// defaults to now for startup; after readiness, the next poll is delayed so
    /// the app does not immediately issue a duplicate request.
    private func scheduleHealthTimer(interval: Int, firstDeadline: DispatchTime = .now()) {
        generation &+= 1
        healthTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .background))
        timer.schedule(deadline: firstDeadline, repeating: .seconds(interval),
                       leeway: .seconds(max(1, interval / 2)))
        timer.setEventHandler { [weak self] in
            self?.checkHealth()
        }
        timer.resume()
        healthTimer = timer
    }

    // MARK: - Health check

    /// The timer fires on a background queue, so the request is issued from the
    /// main queue instead: every field this reads or writes lives there, and the
    /// generation stamped on the request has to be the one current at issue time.
    ///
    /// `nonisolated` states what is already true. The timer's event handler is a
    /// non-Sendable closure, so the compiler infers this class's main-actor
    /// isolation for it and then checks nothing — the handler still runs on a
    /// background queue. Declared this way, the hop below is the only way in,
    /// and an edit that reaches for main-queue state from here is a diagnostic
    /// rather than a silent race.
    nonisolated private func checkHealth() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            MainActor.assumeIsolated { self.issueHealthRequest() }
        }
    }

    private func issueHealthRequest() {
        guard let url = healthURL else { return }
        let issued = generation
        let req = URLRequest(url: url, timeoutInterval: 2)
        Self.session.dataTask(with: req) { [weak self] _, response, error in
            guard let s = self else { return }
            DispatchQueue.main.async {
                // Superseded by a stop, a restart, or a cadence change.
                guard issued == s.generation else { return }
                if let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 {
                    // Server is alive and answering.
                    s.consecutiveFailures = 0
                    if s.isStartingUp?() == true {
                        // PID is resolved by the orchestrator; we just signal success.
                        s.startupBegan = nil
                        s.onHealthSuccess?()
                        s.scheduleHealthTimer(
                            interval: s.steadyInterval,
                            firstDeadline: .now() + .seconds(s.steadyInterval))
                    }
                } else {
                    let errMsg = error.map { $0.localizedDescription }
                        ?? "HTTP \(String(describing: (response as? HTTPURLResponse)?.statusCode))"
                    // If it was running and now unreachable, report failure —
                    // but only once a run of polls has failed, so a single
                    // stalled request cannot kill a working server.
                    if s.isRunning?() == true {
                        s.consecutiveFailures += 1
                        if s.consecutiveFailures >= s.failureThreshold {
                            s.consecutiveFailures = 0
                            s.onUnreachable?(
                                "unreachable for \(s.failureThreshold) checks: \(errMsg)"
                            )
                        }
                    }
                    // If still starting, keep trying. Model loading and Metal
                    // residency happen before the listener exists. Once past the
                    // advisory interval, say so once — and keep polling.
                    if s.isStartingUp?() == true, !s.stallAdvisoryPosted,
                       let began = s.startupBegan,
                       Date().timeIntervalSince(began) >= s.stallAdvisoryInterval {
                        s.stallAdvisoryPosted = true
                        s.onStartupStalled?()
                    }
                }
            }
        }.resume()
    }
}
