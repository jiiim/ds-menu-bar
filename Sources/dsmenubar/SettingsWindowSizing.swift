// SPDX-FileCopyrightText: Copyright James Martin and DS Menu Bar contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI

// MARK: - Settings window sizing

/// Fits the Settings window's height to the active pane, growing or shrinking,
/// as Apple's own settings windows do. Width never changes: moving the pane
/// tabs sideways is worse than moving the action bar up or down. The user
/// cannot drag the size either, since it would last only until the next fit.
///
/// SwiftUI measures the pane's content height (see `SettingsView.fitted`);
/// this reads the visible height between the bars from AppKit at the moment
/// it applies. SwiftUI delivers measurements after the fact, often after the
/// window has moved on, so only the window-independent half comes from it.
/// Repeating a fit is then a no-op, and stale reports cannot feed a loop.
@MainActor
final class SettingsWindowFitter {
    private weak var window: NSWindow?
    /// The first measurement can arrive before the sizer view joins the window.
    private var pendingContentHeight: CGFloat?
    /// Set around the fitter's own animated `setFrame`.
    private var isResizing = false

    /// Size the window so `contentHeight` fits between the bars.
    func fit(contentHeight: CGFloat) {
        guard let window else {
            pendingContentHeight = contentHeight
            return
        }
        guard !isResizing, let visibleHeight = visiblePaneHeight(in: window) else { return }
        apply(targetHeight: window.frame.height - visibleHeight + contentHeight, to: window)
    }

    fileprivate func attach(_ window: NSWindow) {
        self.window = window
        window.styleMask.remove(.resizable)
        if let contentHeight = pendingContentHeight {
            pendingContentHeight = nil
            fit(contentHeight: contentHeight)
        }
    }

    /// The pane Form's viewport less the bars inset over it. Outermost scroll
    /// views only: a scrolling control inside a pane is not the pane.
    private func visiblePaneHeight(in window: NSWindow) -> CGFloat? {
        guard let contentView = window.contentView else { return nil }
        contentView.layoutSubtreeIfNeeded()
        guard let scrollView = outermostScrollViews(in: contentView)
            .first(where: { !$0.isHiddenOrHasHiddenAncestor })
        else { return nil }
        let insets = scrollView.contentInsets
        return scrollView.contentView.bounds.height - insets.top - insets.bottom
    }

    private func outermostScrollViews(in view: NSView) -> [NSScrollView] {
        if let scrollView = view as? NSScrollView {
            return [scrollView]
        }
        return view.subviews.flatMap(outermostScrollViews)
    }

    private func apply(targetHeight: CGFloat, to window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        // A pane taller than the screen stops at it and scrolls.
        let availableFrame = screen.visibleFrame.insetBy(dx: 0, dy: 16)
        let height = min(ceil(targetHeight), availableFrame.height)
        guard abs(height - window.frame.height) > 1 else { return }

        var frame = window.frame
        let top = min(frame.maxY, availableFrame.maxY)
        frame.size.height = height
        frame.origin.y = max(availableFrame.minY, top - height)
        isResizing = true
        window.setFrame(frame, display: true, animate: window.isVisible)
        isResizing = false
    }
}

/// Measures a Form row that is hidden, from a hidden copy of its content and
/// the padding the Form puts around the row above it. The padding is the
/// distance between two neighbouring rows' tops, less the upper row's content.
struct SettingsReservedRow: Equatable {
    var contentHeight: CGFloat?
    /// Content frame of the row two above the hidden one.
    var defaultTokensFrame: CGRect?
    /// Content top of the row directly above the hidden one.
    var residentSessionsTop: CGFloat?

    var height: CGFloat? {
        guard let contentHeight, let defaultTokensFrame, let residentSessionsTop else {
            return nil
        }
        let rowPadding = residentSessionsTop - defaultTokensFrame.minY - defaultTokensFrame.height
        return contentHeight + rowPadding
    }
}

/// Hands the hosting window to the fitter.
struct SettingsWindowSizer: NSViewRepresentable {
    let fitter: SettingsWindowFitter

    func makeNSView(context: Context) -> SettingsWindowSizingView {
        SettingsWindowSizingView(fitter: fitter)
    }

    func updateNSView(_ nsView: SettingsWindowSizingView, context: Context) {}
}

@MainActor
final class SettingsWindowSizingView: NSView {
    private let fitter: SettingsWindowFitter

    init(fitter: SettingsWindowFitter) {
        self.fitter = fitter
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            fitter.attach(window)
        }
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
