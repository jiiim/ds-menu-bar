// SPDX-FileCopyrightText: Copyright James Martin and DS Menu Bar contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Describes how long ago a server last served a request, for the status menu.
///
/// Hand-rolled rather than `RelativeDateTimeFormatter` so the wording is
/// deterministic and can be asserted without locale surprises. A future
/// timestamp clamps to "just now": a clock stepping backwards must not read as
/// a request in the future.
enum ServerActivityRecency {
    /// The full menu line. A launched server is "started" whether or not it has
    /// finished loading, so `.starting` and `.running` show the value; every
    /// other state shows a dash because the run is not usable.
    static func menuTitle(for status: ServerStatus, activity: Date?, now: Date) -> String {
        switch status {
        case .starting, .running:
            return "Last activity: " + describe(since: activity, now: now)
        case .stopped, .stopping, .restarting, .error:
            return "Last activity: ---"
        }
    }

    static func describe(since date: Date?, now: Date) -> String {
        guard let date else { return "unused" }
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "less than a minute ago" }
        if seconds < 3_600 {
            let minutes = Int(seconds / 60)
            return "\(minutes) minute\(minutes == 1 ? "" : "s") ago"
        }
        if seconds < 86_400 {
            let hours = Int(seconds / 3_600)
            return "\(hours) hour\(hours == 1 ? "" : "s") ago"
        }
        let days = Int(seconds / 86_400)
        return "\(days) day\(days == 1 ? "" : "s") ago"
    }
}
