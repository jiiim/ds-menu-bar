// SPDX-FileCopyrightText: Copyright James Martin and DS Menu Bar contributors
// SPDX-License-Identifier: MIT

import Foundation

/// What the status menu can say about the model the app is configured to run.
/// The GGUF header is read here, so this is a snapshot of the file, not a
/// cache of anything the server reported.
struct ActiveModelInfo: Equatable {
    /// Nothing configured yet; the status menu hides the row.
    static let empty = ActiveModelInfo(
        typeName: nil,
        fileName: "",
        isAvailable: false,
        isInspected: false,
        resolvedPath: ""
    )

    /// Detected family name, when the header names a family the app knows.
    let typeName: String?
    /// Last path component, which is what the user recognises.
    let fileName: String
    /// The configured file is a readable regular file.
    let isAvailable: Bool
    /// False while the header read is still running off the main thread.
    let isInspected: Bool
    /// The model path as the launched server resolves it.
    let resolvedPath: String
}

enum ActiveModelDescription {
    /// Where the configured model resolves to, and the size and modification
    /// date that decide whether a cached inspection still describes it.
    struct Location: Equatable, Sendable {
        let fileName: String
        let resolvedPath: String
        let identity: SettingsFileIdentity

        var isAvailable: Bool { identity != .unavailable }
    }

    static func locate(modelPath: String, serverPath: String) -> Location {
        let fileName = (modelPath as NSString).lastPathComponent
        let directory = DS4ServerCommand.serverDirectory(for: serverPath)
        let resolved = DS4ServerCommand.resolving(modelPath, relativeTo: directory)
        guard !resolved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              FileManager.default.isReadableRegularFile(atPath: resolved)
        else {
            return Location(
                fileName: fileName,
                resolvedPath: resolved,
                identity: .unavailable
            )
        }
        return Location(
            fileName: fileName,
            resolvedPath: resolved,
            // attributesOfItem reports a symlink's own size and date, so the
            // identity has to come from the file the link points at or a
            // replaced target would keep its old description cached.
            identity: SettingsFileIdentity(
                path: URL(fileURLWithPath: resolved).resolvingSymlinksInPath().path
            )
        )
    }

    /// What can be said without reading the header: the name and whether the
    /// file is there. The type arrives when the background read finishes.
    static func placeholder(location: Location) -> ActiveModelInfo {
        ActiveModelInfo(
            typeName: nil,
            fileName: location.fileName,
            isAvailable: location.isAvailable,
            isInspected: false,
            resolvedPath: location.resolvedPath
        )
    }

    static func make(location: Location, profile: DS4ModelProfile) -> ActiveModelInfo {
        guard location.isAvailable else {
            return ActiveModelInfo(
                typeName: nil,
                fileName: location.fileName,
                isAvailable: false,
                isInspected: true,
                resolvedPath: location.resolvedPath
            )
        }
        return ActiveModelInfo(
            typeName: profile.isKnown ? profile.displayName : nil,
            fileName: location.fileName,
            isAvailable: true,
            isInspected: true,
            resolvedPath: location.resolvedPath
        )
    }
}

/// Stores the last description under the file it was read from. The caller
/// schedules the header read; this only decides whether one is needed, so an
/// unchanged model costs a single stat and a replaced one misses.
final class ActiveModelCache {
    private var cached: (location: ActiveModelDescription.Location, info: ActiveModelInfo)?

    func cachedInfo(for location: ActiveModelDescription.Location) -> ActiveModelInfo? {
        guard let cached, cached.location == location else { return nil }
        return cached.info
    }

    func store(_ info: ActiveModelInfo, for location: ActiveModelDescription.Location) {
        cached = (location, info)
    }
}
