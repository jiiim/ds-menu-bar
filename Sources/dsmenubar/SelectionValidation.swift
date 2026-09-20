// SPDX-FileCopyrightText: Copyright James Martin and DS Menu Bar contributors
// SPDX-License-Identifier: MIT

import Foundation

enum DS4SelectionValidation {
    enum ModelError: Error {
        case unreadable
        case directory
        case invalid
        case supportArtifact

        var message: String {
            switch self {
            case .unreadable:
                return "Choose a readable GGUF model file."
            case .directory:
                return "Choose a model file, not a directory."
            case .invalid:
                return "Choose a valid GGUF model file."
            case .supportArtifact:
                return "Choose a main model GGUF, not a support GGUF."
            }
        }

        func launchMessage(at path: String) -> String {
            switch self {
            case .unreadable:
                return "model not readable at \(path)"
            case .directory:
                return "model path is a directory at \(path)"
            case .invalid:
                return "model is not a valid GGUF at \(path)"
            case .supportArtifact:
                return "main model is a support GGUF at \(path)"
            }
        }
    }

    static func serverError(for path: String) -> String? {
        let candidate = DS4ServerCommand.expandingTilde(path)
        guard FileManager.default.isExecutableRegularFile(atPath: candidate) else {
            return "Choose an executable ds4-server file."
        }
        guard executableIdentifiesAsDS4Server(at: candidate) else {
            return "Choose ds4-server, not another executable."
        }
        return nil
    }

    static func modelError(for path: String) -> String? {
        switch modelValidation(for: path) {
        case .success:
            return nil
        case .failure(let error):
            return error.message
        }
    }

    /// Recognize support artifacts when their metadata is understood, while
    /// allowing future GGUF metadata and versions to reach ds4-server.
    static func modelValidation(
        for path: String
    ) -> Result<DS4ModelProfile, ModelError> {
        let candidate = DS4ServerCommand.expandingTilde(path)
        guard FileManager.default.isReadableRegularFile(atPath: candidate) else {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return .failure(.directory)
            }
            return .failure(.unreadable)
        }
        guard GGUFModelInspector.hasGGUFMagic(at: candidate) else {
            return .failure(.invalid)
        }
        let profile = GGUFModelInspector.profile(for: candidate)
        guard !profile.isSupportArtifact else {
            return .failure(.supportArtifact)
        }
        return .success(profile)
    }

    static func preferredModelDirectory(forServerPath path: String) -> URL {
        let serverDirectory = URL(
            fileURLWithPath: DS4ServerCommand.expandingTilde(path)
        ).deletingLastPathComponent()
        let ggufDirectory = serverDirectory.appendingPathComponent("gguf", isDirectory: true)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(
            atPath: ggufDirectory.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue {
            return ggufDirectory
        }
        return serverDirectory
    }

    private static func executableIdentifiesAsDS4Server(at path: String) -> Bool {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsmenubar-help-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil),
              let output = try? FileHandle(forWritingTo: outputURL)
        else { return false }
        defer {
            try? output.close()
            try? FileManager.default.removeItem(at: outputURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--help"]
        process.standardOutput = output
        process.standardError = output

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return false
        }

        guard finished.wait(timeout: .now() + 5) == .success else {
            process.terminate()
            return false
        }
        guard process.terminationStatus == 0 else { return false }

        try? output.synchronize()
        guard let reader = try? FileHandle(forReadingFrom: outputURL) else { return false }
        defer { try? reader.close() }
        let data = (try? reader.read(upToCount: 64 * 1_024)) ?? Data()
        return String(decoding: data, as: UTF8.self).contains("Usage: ds4-server")
    }
}
