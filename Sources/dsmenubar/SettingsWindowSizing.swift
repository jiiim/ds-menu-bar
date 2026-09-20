// SPDX-FileCopyrightText: Copyright James Martin and DS Menu Bar contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI

// MARK: - Settings window sizing

struct SettingsWindowSizer: NSViewRepresentable {
    let revision: Int

    func makeNSView(context: Context) -> SettingsWindowSizingView {
        SettingsWindowSizingView()
    }

    func updateNSView(_ nsView: SettingsWindowSizingView, context: Context) {
        nsView.scheduleResize()
    }
}

@MainActor
final class SettingsWindowSizingView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleResize()
    }

    func scheduleResize() {
        DispatchQueue.main.async { [weak self] in
            self?.resizeToFitTallestPane()
        }
    }

    private func resizeToFitTallestPane() {
        guard let window,
              window.isVisible,
              !window.inLiveResize,
              let screen = window.screen ?? NSScreen.main,
              let contentView = window.contentView
        else { return }

        let largestOverflow = scrollViews(in: contentView).reduce(CGFloat.zero) { result, scrollView in
            guard let documentView = scrollView.documentView else { return result }
            let overflow = documentView.bounds.height - scrollView.contentView.bounds.height
            return max(result, overflow)
        }
        guard largestOverflow > 1 else { return }

        let availableFrame = screen.visibleFrame.insetBy(dx: 0, dy: 16)
        let targetHeight = min(
            ceil(window.frame.height + largestOverflow),
            availableFrame.height
        )
        guard targetHeight > window.frame.height + 1 else { return }

        var frame = window.frame
        let top = min(frame.maxY, availableFrame.maxY)
        frame.size.height = targetHeight
        frame.origin.y = max(availableFrame.minY, top - targetHeight)
        window.setFrame(frame, display: true, animate: true)
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        var result = view.subviews.flatMap(scrollViews)
        if let scrollView = view as? NSScrollView {
            result.append(scrollView)
        }
        return result
    }
}

extension ServerManager {
    var statusColor: Color {
        switch status {
        case .running: return .green
        case .error: return .red
        case .starting, .restarting, .stopping: return .orange
        case .stopped: return .secondary
        }
    }
}
