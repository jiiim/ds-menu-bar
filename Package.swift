// swift-tools-version: 5.9
// SPDX-FileCopyrightText: Copyright James Martin and DS Menu Bar contributors
// SPDX-License-Identifier: MIT

import PackageDescription

/// Swift 5 language mode with complete data-race checking. The checks are
/// diagnostics here, not errors: the point is to catch cross-queue access to
/// main-queue state (see ProcessManager, HealthChecker, ServerManager) without
/// taking on the unrelated source breaks that Swift 6 language mode brings.
let strictConcurrency: [SwiftSetting] = [
    .enableUpcomingFeature("StrictConcurrency"),
]

let package = Package(
    name: "dsmenubar",
    platforms: [
        .macOS("26.0"),
    ],
    targets: [
        .executableTarget(
            name: "dsmenubar",
            swiftSettings: strictConcurrency
        ),
        .testTarget(
            name: "dsmenubarTests",
            dependencies: ["dsmenubar"],
            swiftSettings: strictConcurrency
        ),
    ]
)
