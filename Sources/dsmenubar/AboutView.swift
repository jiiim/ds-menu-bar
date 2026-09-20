// SPDX-FileCopyrightText: Copyright James Martin and DS Menu Bar contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI

/// Custom About window modeled after the standard "About Finder" panel:
/// fixed size, no minimize/zoom, centered icon and text, small system fonts.
struct AboutView: View {
    private var version: String {
        let release = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "dev"
        guard let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              !build.isEmpty
        else { return release }
        return "\(release) (\(build))"
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)

            Text("DS Menu Bar")
                .font(.system(size: 13, weight: .bold))

            // Markdown must stay a string literal — a variable would render as
            // plain text instead of a tappable link.
            Text("A Menu Bar Control for [DwarfStar](https://github.com/antirez/ds4)")
                .font(.system(size: 11))

            Text("DS Menu Bar version \(version)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            // Markdown must stay a string literal here too — see above. The
            // rendered text is unchanged, so the frame width still holds.
            Text("© James Martin and [DS Menu Bar contributors](https://github.com/jiiim/ds-menu-bar/graphs/contributors)")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(20)
        .frame(width: 270)
        .fixedSize()
    }
}

/// Hosts the singleton SwiftUI About view in a standard AppKit window. This is
/// used because macOS 26's NSHostingSceneRepresentation does not present a
/// `Window` scene through `openWindow(id:)`.
@MainActor
final class AboutWindowController: NSWindowController, NSWindowDelegate {
    init() {
        let content = NSHostingController(rootView: AboutView())
        let window = NSWindow(contentViewController: content)
        window.styleMask = [.titled, .closable]
        // Titled but not shown, matching the standard About panel. The title
        // is still what the Window menu lists this window under.
        window.title = "About DS Menu Bar"
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        content.view.layoutSubtreeIfNeeded()
        window.setContentSize(content.view.fittingSize)

        super.init(window: window)
        window.delegate = self
        park(window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            park(window)
        }
    }

    private func park(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let area = screen.visibleFrame
        let frame = window.frame
        window.setFrameOrigin(NSPoint(
            x: area.midX - frame.width / 2,
            y: area.maxY - area.height / 5 - frame.height
        ))
    }
}
