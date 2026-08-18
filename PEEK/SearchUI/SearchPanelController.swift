import AppKit
import SwiftUI

private final class SearchFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Explicit presentation API. Call `show(provider:)` from a menu item, button,
/// command, or a future non-conflicting shortcut; SearchUI itself registers no
/// global shortcut and therefore cannot conflict with macOS input-source keys.
@MainActor
final class SearchPanelController: NSObject, NSWindowDelegate {
    static let shared = SearchPanelController()

    private var panel: SearchFloatingPanel?
    private var viewModel: SearchPanelViewModel?

    func show(
        provider: any SearchPanelProviding,
        actionHandler: (any SearchPanelActionHandling)? = nil,
        initialQuery: String? = nil
    ) {
        if let panel, panel.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            return
        }

        let settingsWasVisible = NSApp.windows.contains {
            PEEKSettingsWindowPresenter.isSettingsWindow($0) && $0.isVisible
        }
        let viewModel = SearchPanelViewModel(
            provider: provider,
            actionHandler: actionHandler
        )
        if let initialQuery {
            viewModel.query = initialQuery
        }
        viewModel.onRequestClose = { [weak self] in
            self?.close()
        }

        let rootView = SearchPanelView(viewModel: viewModel)
        let hostingController = NSHostingController(rootView: rootView)
        let panel = SearchFloatingPanel(
            contentRect: CGRect(x: 0, y: 0, width: 920, height: 680),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = CGSize(width: 840, height: 590)
        panel.contentViewController = hostingController
        panel.delegate = self
        let frameAutosaveName = "PEEK.SearchPanel.v4"
        let preferences = SearchPanelPreferences.current()
        panel.alphaValue = CGFloat(preferences.windowOpacity)
        if preferences.position == .remembered {
            panel.setFrameAutosaveName(frameAutosaveName)
        }
        if preferences.position != .remembered
            || !panel.setFrameUsingName(frameAutosaveName) {
            panel.setContentSize(CGSize(width: 920, height: 680))
            position(panel, on: preferredScreen(for: preferences.screen))
        }

        self.panel = panel
        self.viewModel = viewModel
        FileSearchIndexRuntime.shared.setSearchPanelActive(true)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        guard !settingsWasVisible else { return }
        [0.0, 0.08, 0.2, 0.5].forEach { delay in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                NSApp.windows
                    .filter {
                        PEEKSettingsWindowPresenter.isSettingsWindow($0)
                            && $0.isVisible
                    }
                    .forEach { $0.orderOut(nil) }
                panel.makeKeyAndOrderFront(nil)
            }
        }
    }

    func toggle(
        provider: any SearchPanelProviding,
        actionHandler: (any SearchPanelActionHandling)? = nil
    ) {
        if panel?.isVisible == true {
            close()
        } else {
            show(provider: provider, actionHandler: actionHandler)
        }
    }

    func close() {
        FileSearchIndexRuntime.shared.setSearchPanelActive(false)
        viewModel?.shutdown()
        panel?.orderOut(nil)
        panel?.contentViewController = nil
        panel = nil
        viewModel = nil
    }

    func windowWillClose(_ notification: Notification) {
        FileSearchIndexRuntime.shared.setSearchPanelActive(false)
        viewModel?.shutdown()
        panel?.contentViewController = nil
        panel = nil
        viewModel = nil
    }

    private func preferredScreen(
        for preference: SearchWindowScreenPreference
    ) -> NSScreen? {
        guard preference == .mouse else { return NSScreen.main }
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
            ?? NSScreen.main
    }

    private func position(_ panel: NSPanel, on screen: NSScreen?) {
        guard let visibleFrame = screen?.visibleFrame else {
            panel.center()
            return
        }
        let frame = panel.frame
        panel.setFrameOrigin(CGPoint(
            x: visibleFrame.midX - frame.width / 2,
            y: visibleFrame.midY - frame.height / 2
        ))
    }
}
