// SPDX-FileCopyrightText: Copyright James Martin and DS Menu Bar contributors
// SPDX-License-Identifier: MIT

import Foundation
import IOKit.ps
import IOKit.pwr_mgt
import os.log

// MARK: - Keep-awake state

/// What the keep-awake preference is doing right now, which is not the same
/// question as whether it is enabled: the assertion is only held while a server
/// process is live and the Mac is on a power adapter. The menu shows the check
/// mark for the preference and this for the effect.
enum KeepAwakeState: Equatable {
    case off
    case active
    case waitingForPower
    case serverStopped

    /// Second line under the menu item. Nothing is shown when the preference is
    /// off, because an unchecked item has no behavior left to explain.
    var menuSubtitle: String? {
        switch self {
        case .off:              return nil
        case .active:           return "Active"
        case .waitingForPower:  return "Waiting for a power adapter"
        case .serverStopped:    return "Server stopped"
        }
    }
}

/// Expressed without IOKit or a clock so the state table can be exercised
/// directly. ServerManager owns the assertion and performs the effect.
enum KeepAwakePolicy {
    static func state(
        preferenceEnabled: Bool,
        status: ServerStatus,
        onExternalPower: Bool
    ) -> KeepAwakeState {
        guard preferenceEnabled else { return .off }
        guard status.holdsServerProcess else { return .serverStopped }
        return onExternalPower ? .active : .waitingForPower
    }
}

// MARK: - Idle-sleep assertion

/// Holds one named `PreventUserIdleSystemSleep` assertion.
///
/// This blocks *idle* system sleep only. The display still sleeps on its own
/// timer, and a lid close, an Apple-menu sleep, or a critical battery level all
/// still sleep the Mac. The name is what `pmset -g assertions` prints, so an
/// assertion this app is holding can be attributed without guesswork — which is
/// exactly what the unnamed CFNetwork assertion this app used to trigger made
/// impossible.
final class IdleSleepAssertion {
    private let name: String
    private let log = OSLog(subsystem: "com.jiiim.ds-menu-bar", category: "power")
    private var identifier = IOPMAssertionID(0)

    init(name: String) {
        self.name = name
    }

    var isHeld: Bool { identifier != IOPMAssertionID(0) }

    func hold() {
        guard !isHeld else { return }
        var created = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            name as CFString,
            &created
        )
        guard result == kIOReturnSuccess else {
            os_log(.error, log: log, "unable to hold idle-sleep assertion: 0x%{public}x", result)
            return
        }
        identifier = created
    }

    func release() {
        guard isHeld else { return }
        IOPMAssertionRelease(identifier)
        identifier = IOPMAssertionID(0)
    }
}

// MARK: - External power

/// Reports whether the Mac is drawing from something other than its battery,
/// and calls back when that changes.
///
/// Only an explicit battery report withholds the assertion. A Mac with no
/// battery reports AC power, so a desktop is never excluded by this gate, and a
/// power source that cannot be read cannot silently disable the feature.
final class ExternalPowerMonitor {
    /// Called on the main run loop when the providing power source changes.
    var onChange: (() -> Void)?

    private var runLoopSource: CFRunLoopSource?

    var isOnExternalPower: Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue()
        else { return true }
        return (type as String) != kIOPSBatteryPowerValue
    }

    func start() {
        guard runLoopSource == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<ExternalPowerMonitor>.fromOpaque(context)
                .takeUnretainedValue()
                .onChange?()
        }, context)?.takeRetainedValue() else { return }
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }

    func stop() {
        guard let source = runLoopSource else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        runLoopSource = nil
    }
}
