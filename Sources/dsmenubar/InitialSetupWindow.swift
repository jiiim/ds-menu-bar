// SPDX-FileCopyrightText: Copyright James Martin and DS Menu Bar contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct InitialSetupView: View {
    let onContinue: (
        _ serverPath: String,
        _ modelPath: String,
        _ modelProfile: DS4ModelProfile
    ) -> Void

    @State private var serverPath = ""
    @State private var modelPath = ""
    @State private var serverError: String?
    @State private var modelError: String?
    @State private var modelProfile: DS4ModelProfile?
    @State private var isCheckingServer = false
    @State private var isCheckingModel = false

    private var canContinue: Bool {
        return !serverPath.isEmpty && serverError == nil &&
            !modelPath.isEmpty && modelError == nil && modelProfile != nil &&
            !isCheckingServer && !isCheckingModel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Set Up DS Menu Bar")
                    .font(.title2.bold())
                Text(
                    "Choose the ds4-server executable and a DwarfStar-specific " +
                        "main GGUF model to begin."
                )
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 0) {
                selectionRow(
                    title: "ds4-server",
                    path: DS4ServerCommand.presentingPath(serverPath),
                    error: serverError,
                    isChecking: isCheckingServer,
                    checkingText: "Checking ds4-server…",
                    action: chooseServer
                )
                Divider()
                    .padding(.leading, 16)
                selectionRow(
                    title: "Main GGUF model",
                    path: DS4ServerCommand.presentingResourcePath(
                        modelPath,
                        relativeTo: DS4ServerCommand.serverDirectory(for: serverPath)
                    ),
                    error: modelError,
                    isChecking: isCheckingModel,
                    checkingText: "Checking GGUF model…",
                    action: chooseModel
                )
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 5) {
                Text(
                    "DwarfStar requires DwarfStar-specific GGUF model files. " +
                        "See the DwarfStar GitHub page for installation instructions and model details."
                )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Link(
                    "Open DwarfStar on GitHub",
                    destination: URL(string: "https://github.com/antirez/ds4")!
                )
            }

            HStack {
                Button("Quit") {
                    // Routed through the delegate so the quit policy has one
                    // entry point. It always proceeds from here: the server
                    // cannot be starting or running before setup completes.
                    NSApp.sendAction(#selector(AppDelegate.requestQuit(_:)), to: nil, from: nil)
                }
                Spacer()
                Button("Continue", action: continueSetup)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canContinue)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func selectionRow(
        title: String,
        path: String,
        error: String?,
        isChecking: Bool = false,
        checkingText: String = "Checking…",
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title)
                        .fontWeight(.medium)
                    if !path.isEmpty && error == nil {
                        if isChecking {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                }
                Text(path.isEmpty ? "Required" : path)
                    .font(.callout)
                    .foregroundStyle(path.isEmpty ? Color.secondary : Color.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(path)
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                } else if isChecking {
                    Text(checkingText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            Button("Choose…", action: action)
        }
        .padding(16)
    }

    private func chooseServer() {
        let panel = NSOpenPanel()
        panel.title = "Choose ds4-server"
        panel.message = "Select the ds4-server executable."
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        panel.directoryURL = startingDirectory(for: serverPath)

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        serverPath = DS4ServerCommand.storingAbsolutePath(url.path)
        serverError = nil
        isCheckingServer = true
        let selectedPath = serverPath
        Task {
            let error = await Task.detached(priority: .userInitiated) {
                DS4SelectionValidation.serverError(for: selectedPath)
            }.value
            guard serverPath == selectedPath else { return }
            serverError = error
            isCheckingServer = false
        }
    }

    private func chooseModel() {
        let panel = NSOpenPanel()
        panel.title = "Choose Main GGUF Model"
        panel.message = "Select the DwarfStar-specific main GGUF model ds4-server should load."
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        if let gguf = UTType(filenameExtension: "gguf", conformingTo: .data) {
            panel.allowedContentTypes = [gguf]
        }
        if !serverPath.isEmpty, serverError == nil {
            panel.directoryURL = DS4SelectionValidation.preferredModelDirectory(
                forServerPath: serverPath
            )
        } else {
            panel.directoryURL = startingDirectory(for: modelPath)
        }

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        modelPath = DS4ServerCommand.storingResourcePath(
            url.path,
            relativeTo: DS4ServerCommand.serverDirectory(for: serverPath)
        )
        modelError = nil
        modelProfile = nil
        isCheckingModel = true
        let selectedPath = modelPath
        Task {
            let validation = await Task.detached(priority: .userInitiated) {
                DS4SelectionValidation.modelValidation(for: selectedPath)
            }.value
            guard modelPath == selectedPath else { return }
            switch validation {
            case .success(let profile):
                modelProfile = profile
                modelError = nil
            case .failure(let error):
                modelProfile = nil
                modelError = error.message
            }
            isCheckingModel = false
        }
    }

    private func continueSetup() {
        guard canContinue, let modelProfile else { return }
        onContinue(serverPath, modelPath, modelProfile)
    }

    private func startingDirectory(for path: String) -> URL {
        guard !path.isEmpty else {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        return URL(fileURLWithPath: expanded(path)).deletingLastPathComponent()
    }

    private func expanded(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

}

@MainActor
final class InitialSetupWindowController: NSWindowController {
    init(
        onContinue: @escaping (
            _ serverPath: String,
            _ modelPath: String,
            _ modelProfile: DS4ModelProfile
        ) -> Void
    ) {
        let view = InitialSetupView(onContinue: onContinue)
        let hostingController = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Set Up DS Menu Bar"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
