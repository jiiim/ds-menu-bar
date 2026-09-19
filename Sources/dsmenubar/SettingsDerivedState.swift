// SPDX-FileCopyrightText: Copyright 2026 James Martin
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - Derived-state inspection
//
// The two file-inspection passes Settings runs off the main thread. Both are
// pure functions of a config plus the previous pass's results, which is what
// lets them be tested: the decisions that matter — when a profile is reused
// instead of re-read, and when the server executable is re-run — are here
// rather than tangled in the view's @State.

/// What one derived-state refresh learned. `identities` is the file
/// size/mtime triple the profiles were read from, so the next pass can tell a
/// file replaced in place from one merely re-selected.
struct SettingsDerivedResult {
    let model: DS4ModelProfile
    let modelError: String?
    let support: DS4SupportProfile
    let vision: DS4VisionProfile
    let identities: SettingsDerivedFileIdentities
}

/// The previous pass's results, reused when the corresponding file has not
/// moved or changed.
struct SettingsDerivedPrevious {
    let inputs: SettingsDerivedInputs
    let model: DS4ModelProfile
    let modelError: String?
    let support: DS4SupportProfile
    let vision: DS4VisionProfile
    let identities: SettingsDerivedFileIdentities
}

/// Which files must be inspected again after Apply transforms the draft into
/// the configuration it will persist. Model-profile restoration currently
/// preserves the server and main-model paths, but the full-files case prevents
/// that invariant from becoming an unchecked assumption if the transform grows.
enum SettingsApplyReinspection {
    case none
    case auxiliaryFiles(ServerConfiguration.Config)
    case allFiles(ServerConfiguration.Config)

    static func plan(
        inspected: ServerConfiguration.Config,
        restored: ServerConfiguration.Config
    ) -> Self {
        let inspectedInputs = SettingsDerivedInputs(inspected)
        let restoredInputs = SettingsDerivedInputs(restored)
        if inspected.serverPath != restored.serverPath ||
            restoredInputs.modelDiffers(from: inspectedInputs) {
            return .allFiles(restored)
        }
        if restoredInputs.supportDiffers(from: inspectedInputs) ||
            restoredInputs.visionDiffers(from: inspectedInputs) {
            return .auxiliaryFiles(restored)
        }
        return .none
    }
}

enum SettingsDerivedRefresh {
    /// Re-inspect only what changed. A path that differs from the previous
    /// pass, or whose file changed underneath an unchanged path, is read again;
    /// everything else carries the previous profile forward.
    ///
    /// `forceRefresh` re-reads regardless, for the cases where the paths are
    /// identical but the answer may not be — the app regaining focus, a revert,
    /// or the same path being picked again.
    static func compute(
        config: ServerConfiguration.Config,
        inputs: SettingsDerivedInputs,
        previous: SettingsDerivedPrevious,
        forceRefresh: Bool
    ) -> SettingsDerivedResult {
        let directory = DS4ServerCommand.serverDirectory(for: config.serverPath)
        let identities = SettingsDerivedFileIdentities.inspecting(config)
        // Validate rather than only inspect, so a model that is missing,
        // unreadable, a directory, or a support GGUF is reported when
        // Settings opens instead of waiting for Apply to refuse it. An
        // empty path is not a bad selection: `validationErrors` already
        // asks for one, and that message is the clearer of the two.
        let modelResult: (profile: DS4ModelProfile, error: String?)
        if config.modelPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            modelResult = (.unknown, nil)
        } else if forceRefresh || inputs.modelDiffers(from: previous.inputs) ||
            identities.model != previous.identities.model {
            let resolved = DS4ServerCommand.resolving(config.modelPath, relativeTo: directory)
            switch DS4SelectionValidation.modelValidation(for: resolved) {
            case .success(let profile):
                modelResult = (profile, nil)
            case .failure(.supportArtifact):
                // Keep the real profile: `validationErrors` names which
                // support GGUF was chosen, and the detected-model section
                // shows it. Apply still refuses the selection.
                modelResult = (GGUFModelInspector.profile(for: resolved), nil)
            case .failure(let error):
                modelResult = (.unknown, error.message)
            }
        } else {
            modelResult = (previous.model, previous.modelError)
        }
        return SettingsDerivedResult(
            model: modelResult.profile,
            modelError: modelResult.error,
            support: forceRefresh || inputs.supportDiffers(from: previous.inputs) ||
                identities.support != previous.identities.support
                ? GGUFModelInspector.supportProfile(for: config.mtpPath, relativeTo: directory)
                : previous.support,
            vision: forceRefresh || inputs.visionDiffers(from: previous.inputs) ||
                identities.vision != previous.identities.vision
                ? GGUFModelInspector.visionProfile(for: config.visionPath, relativeTo: directory)
                : previous.vision,
            identities: identities
        )
    }
}

extension SettingsApplyChecks {
    /// Everything one Apply needs to know about the selected files, gathered in
    /// a single pass so the checks, the profiles they produced, and the
    /// identities they were read from cannot drift apart.
    ///
    /// The `previousServer*` triple is the executable checked earlier in this
    /// session, or nil when nothing has been checked yet. Matching path, size,
    /// and modification date skips re-running the binary — the only genuinely
    /// expensive check here; nil never matches, so the check runs.
    static func compute(
        candidate: ServerConfiguration.Config,
        previousServerPath: String,
        previousServerIdentity: SettingsFileIdentity?,
        previousServerError: String?
    ) -> SettingsApplyChecks {
        let directory = DS4ServerCommand.serverDirectory(for: candidate.serverPath)
        let resolvedModel = DS4ServerCommand.resolving(
            candidate.modelPath,
            relativeTo: directory
        )
        let modelResult = DS4SelectionValidation.modelValidation(for: resolvedModel)
        let profile: DS4ModelProfile
        let modelError: String?
        switch modelResult {
        case .success(let detected):
            profile = detected
            modelError = nil
        case .failure(let error):
            profile = .unknown
            modelError = error.message
        }
        let serverIdentity = SettingsFileIdentity(
            path: DS4ServerCommand.expandingTilde(candidate.serverPath)
        )
        let serverError: String?
        if candidate.serverPath == previousServerPath,
           previousServerIdentity == serverIdentity {
            serverError = previousServerError
        } else {
            serverError = DS4SelectionValidation.serverError(for: candidate.serverPath)
        }
        return SettingsApplyChecks(
            serverError: serverError,
            serverIdentity: serverIdentity,
            modelError: modelError,
            model: profile,
            support: GGUFModelInspector.supportProfile(
                for: candidate.mtpPath,
                relativeTo: directory
            ),
            vision: GGUFModelInspector.visionProfile(
                for: candidate.visionPath,
                relativeTo: directory
            ),
            identities: SettingsDerivedFileIdentities.inspecting(candidate),
            mtpIsReadable: FileManager.default.isReadableRegularFile(atPath:
                DS4ServerCommand.resolving(candidate.mtpPath, relativeTo: directory)
            ),
            visionIsReadable: FileManager.default.isReadableRegularFile(atPath:
                DS4ServerCommand.resolving(candidate.visionPath, relativeTo: directory)
            )
        )
    }

    /// A model switch can restore model-specific support and vision paths after
    /// the initial Apply pass inspected the draft. Re-read those paths while
    /// retaining the main-model and executable results, which still describe
    /// the same files.
    func reinspectingAuxiliaryFiles(
        for restoredConfig: ServerConfiguration.Config
    ) -> SettingsApplyChecks {
        let directory = DS4ServerCommand.serverDirectory(for: restoredConfig.serverPath)
        return SettingsApplyChecks(
            serverError: serverError,
            serverIdentity: serverIdentity,
            modelError: modelError,
            model: model,
            support: GGUFModelInspector.supportProfile(
                for: restoredConfig.mtpPath,
                relativeTo: directory
            ),
            vision: GGUFModelInspector.visionProfile(
                for: restoredConfig.visionPath,
                relativeTo: directory
            ),
            identities: SettingsDerivedFileIdentities.inspecting(restoredConfig),
            mtpIsReadable: FileManager.default.isReadableRegularFile(atPath:
                DS4ServerCommand.resolving(restoredConfig.mtpPath, relativeTo: directory)
            ),
            visionIsReadable: FileManager.default.isReadableRegularFile(atPath:
                DS4ServerCommand.resolving(restoredConfig.visionPath, relativeTo: directory)
            )
        )
    }
}
