// SPDX-FileCopyrightText: Copyright James Martin and DS Menu Bar contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Decides whether a restartable server failure earns one automatic restart.
///
/// The ledger behind `attemptedThisEpisode` is deliberately blunt: a single
/// attempt, cleared only after a replacement has stayed healthy for
/// `stabilityWindow`. If the server is failing for an underlying reason, the
/// second failure is reported instead of relaunching into the same fault.
enum AutoRestartPolicy {
    enum Decision: Equatable {
        case restart
        case report
    }

    /// How long a run must stay continuously healthy before the episode closes
    /// and a later failure is allowed its own automatic restart.
    static let stabilityWindow: TimeInterval = 300

    static func decision(
        preferenceEnabled: Bool,
        restartable: Bool,
        attemptedThisEpisode: Bool
    ) -> Decision {
        guard preferenceEnabled, restartable, !attemptedThisEpisode else {
            return .report
        }
        return .restart
    }
}
