// SPDX-FileCopyrightText: Copyright 2026 James Martin
// SPDX-License-Identifier: MIT

import Foundation
import SwiftUI

// MARK: - Settings panes

enum SettingsPane: String, CaseIterable, Hashable, Identifiable {
    case general
    case model
    case server
    case performance
    case kvCache
    case mtp
    case diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .model: return "Model"
        case .server: return "Server"
        case .performance: return "Performance"
        case .kvCache: return "KV Cache"
        case .mtp: return "MTP"
        case .diagnostics: return "Diagnostics"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .model: return "cube"
        case .server: return "network"
        case .performance: return "gauge.with.dots.needle.67percent"
        case .kvCache: return "internaldrive"
        case .mtp: return "bolt"
        case .diagnostics: return "stethoscope"
        }
    }

    /// The pane that renders a field's row. Apply switches to this pane when a
    /// field refuses the draft, so a message is never attached to a control on
    /// a pane the user cannot see. Exhaustive on purpose: a new field has to
    /// say where it is shown rather than silently landing on General.
    static func containing(_ field: ServerConfiguration.Config.Field) -> SettingsPane {
        switch field {
        case .serverPath, .modelPath, .visionPath, .qwenImageMaxTokens:
            return .model
        case .host, .port, .defaultTokens, .batchedSessions, .mixedPrefillQuantum:
            return .server
        case .ctxSize, .prefillChunk, .threads, .powerPercent, .ssdStreamingEnabled,
             .ssdStreamingCacheExperts, .ssdStreamingFullLayers, .ssdStreamingPreloadExperts:
            return .performance
        case .kvDiskDir, .kvDiskSpaceMB, .kvCacheMinTokens, .kvCacheColdMaxTokens,
             .kvCacheContinuedIntervalTokens, .kvCacheBoundaryTrimTokens,
             .kvCacheBoundaryAlignTokens, .toolMemoryMaxIDs:
            return .kvCache
        case .mtpMode, .mtpPath, .mtpDraft, .mtpMargin, .dsparkConfidence:
            return .mtp
        case .logPath, .logMaxSizeMB, .tracePath, .simulateUsedMemory:
            return .diagnostics
        }
    }
}

struct SettingsDerivedInputs: Equatable, Hashable {
    // Resource paths in the draft are absolute. Editor text remains separate
    // until Apply, so changing the server directory cannot reinterpret an
    // untouched relative display string.
    let modelPath: String
    let mtpPath: String
    let visionPath: String

    init(_ config: ServerConfiguration.Config) {
        modelPath = config.modelPath
        mtpPath = config.mtpPath
        visionPath = config.visionPath
    }

    func modelDiffers(from other: Self) -> Bool {
        modelPath != other.modelPath
    }

    func supportDiffers(from other: Self) -> Bool {
        mtpPath != other.mtpPath
    }

    func visionDiffers(from other: Self) -> Bool {
        visionPath != other.visionPath
    }
}

struct SettingsFileIdentity: Equatable, Sendable {
    let size: UInt64?
    let modificationDate: Date?

    init(path: String) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        size = (attributes?[.size] as? NSNumber)?.uint64Value
        modificationDate = attributes?[.modificationDate] as? Date
    }

    private init(size: UInt64?, modificationDate: Date?) {
        self.size = size
        self.modificationDate = modificationDate
    }

    static let unavailable = Self(size: nil, modificationDate: nil)
}

struct SettingsDerivedFileIdentities: Equatable, Sendable {
    let model: SettingsFileIdentity
    let support: SettingsFileIdentity
    let vision: SettingsFileIdentity

    static let unavailable = Self(
        model: .unavailable,
        support: .unavailable,
        vision: .unavailable
    )

    static func inspecting(_ config: ServerConfiguration.Config) -> Self {
        let directory = DS4ServerCommand.serverDirectory(for: config.serverPath)
        return Self(
            model: SettingsFileIdentity(path: DS4ServerCommand.resolving(
                config.modelPath,
                relativeTo: directory
            )),
            support: SettingsFileIdentity(path: DS4ServerCommand.resolving(
                config.mtpPath,
                relativeTo: directory
            )),
            vision: SettingsFileIdentity(path: DS4ServerCommand.resolving(
                config.visionPath,
                relativeTo: directory
            ))
        )
    }
}

/// What one Apply learned about the selected files. Gathered off the main
/// thread in a single pass so the checks, the profiles they produced, and the
/// file identities they were read from cannot drift apart.
struct SettingsApplyChecks {
    let serverError: String?
    let serverIdentity: SettingsFileIdentity
    let modelError: String?
    let model: DS4ModelProfile
    let support: DS4SupportProfile
    let vision: DS4VisionProfile
    let identities: SettingsDerivedFileIdentities
    let mtpIsReadable: Bool
    let visionIsReadable: Bool
}

struct SettingsDerivedTaskID: Hashable {
    let inputs: SettingsDerivedInputs
    let refreshRevision: Int
}

/// A row that selects a path through a panel. Every path in the draft comes
/// from one of these, so a stored path is always something that existed when
/// it was chosen.
enum SettingsPathField: Hashable {
    case server
    case model
    case vision
    case kvDiskDirectory
    case mtp
    case logDirectory
    case traceDirectory

    var choosesDirectory: Bool {
        switch self {
        case .server, .model, .vision, .mtp:
            return false
        case .kvDiskDirectory, .logDirectory, .traceDirectory:
            return true
        }
    }

    var choosesGGUF: Bool {
        switch self {
        case .model, .vision, .mtp:
            return true
        case .server, .kvDiskDirectory, .logDirectory, .traceDirectory:
            return false
        }
    }
}

/// The two paths naming a file the app creates rather than one the user owns.
/// A panel cannot select a file that does not exist, so the folder is picked
/// and the name is typed.
enum SettingsFileNameField: Hashable, CaseIterable {
    case log
    case trace

    var errorKey: ServerConfiguration.Config.Field {
        switch self {
        case .log: return .logPath
        case .trace: return .tracePath
        }
    }
}
