// SPDX-FileCopyrightText: Copyright James Martin and DS Menu Bar contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Decides whether a quit request needs confirmation.
///
/// This is the whole policy; the app layer owns the alert and the Apple-event
/// handling. A separate value keeps the truth table testable without an
/// NSApplication, and keeps the `.cancelDuplicate` rule in one place: a quit
/// that arrives while the confirmation is already up must not stack a second
/// alert or answer the first one twice.
enum QuitConfirmation {
    enum Decision: Equatable {
        case proceed
        case prompt
        case cancelDuplicate
    }

    static func decision(
        status: ServerStatus,
        preferenceEnabled: Bool,
        promptIsPending: Bool
    ) -> Decision {
        guard preferenceEnabled, status.requiresQuitConfirmation else {
            return .proceed
        }
        return promptIsPending ? .cancelDuplicate : .prompt
    }
}
