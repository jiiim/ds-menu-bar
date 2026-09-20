// SPDX-FileCopyrightText: Copyright James Martin and DS Menu Bar contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Why a launch was attempted. This decides how a failure reaches the user:
/// a manual start gets a modal alert, an internal relaunch gets a notification.
/// The app never starts the server on its own, so there is no background case.
enum ServerLaunchSource: Equatable {
    case manual
    case restart
}

enum ServerSettingsDestination: String, Equatable {
    case general
    case model
    case mtp
}

@MainActor
enum SettingsNavigation {
    static let pendingPaneKey = "dsmenubar.pendingSettingsPane"
    static let destinationNotification = Notification.Name("dsmenubar.settingsDestination")
    private static var openSettingsAction: (() -> Void)?

    static func install(openSettings: @escaping () -> Void) {
        openSettingsAction = openSettings
    }

    static func request(_ destination: ServerSettingsDestination) {
        UserDefaults.standard.set(destination.rawValue, forKey: pendingPaneKey)
    }

    static func open(_ destination: ServerSettingsDestination) {
        request(destination)
        openSettingsAction?()
        // Opening a Settings scene is asynchronous. Give SwiftUI a turn to
        // install the view's notification subscription before delivering the
        // requested pane; the persisted request remains as an onAppear fallback.
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: destinationNotification,
                object: destination.rawValue
            )
        }
    }

    static func consumePendingPane() -> ServerSettingsDestination? {
        guard let rawValue = UserDefaults.standard.string(forKey: pendingPaneKey),
              let destination = ServerSettingsDestination(rawValue: rawValue)
        else { return nil }
        UserDefaults.standard.removeObject(forKey: pendingPaneKey)
        return destination
    }
}

struct ServerLaunchFailure: Equatable, Identifiable {
    let id: UUID
    let message: String
    let source: ServerLaunchSource
    let settingsDestination: ServerSettingsDestination

    init(
        message: String,
        source: ServerLaunchSource,
        settingsDestination: ServerSettingsDestination? = nil,
        id: UUID = UUID()
    ) {
        self.id = id
        self.message = message
        self.source = source
        self.settingsDestination = settingsDestination ?? Self.destination(for: message)
    }

    var notificationTitle: String {
        source == .restart ? "ds4-server could not restart" : "ds4-server could not start"
    }

    var notificationBody: String {
        let limit = 240
        guard message.count > limit else { return message }
        return String(message.prefix(limit - 1)) + "…"
    }

    private static func destination(for message: String) -> ServerSettingsDestination {
        let lowercased = message.lowercased()
        if lowercased.contains("mtp") || lowercased.contains("dspark") {
            return .mtp
        }
        if lowercased.contains("model") || lowercased.contains("vision") {
            return .model
        }
        return .general
    }
}

enum ServerNotification {
    static let openSettingsAction = "dsmenubar.openSettings"
    static let launchFailureCategory = "dsmenubar.launchFailure"
    static let settingsPaneKey = "settingsPane"
}
