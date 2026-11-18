import AppKit
import ApplicationServices
import SwiftUI

private final class ClipboardHistoryPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class ClipboardHistoryPanelChromeView: NSVisualEffectView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
    }

    private func configure() {
        material = .popover
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
    }
}

@MainActor
final class ClipboardHistoryPanelController: NSObject, NSWindowDelegate {
    static let shared = ClipboardHistoryPanelController()

    private var panel: ClipboardHistoryPanel?
    private var viewModel: ClipboardHistoryViewModel?
    private var hostingController: NSHostingController<ClipboardHistoryPanelView>?
    private var presentationID = UUID()

    func show() {
        let (panel, viewModel) = ensurePanel()
        if !panel.isVisible || !panel.isKeyWindow {
            let id = UUID()
            presentationID = id
            let target = NSWorkspace.shared.frontmostApplication
            viewModel.onRequestPaste = { [weak self] in
                guard let self else { throw Self.pasteUnavailable }
                try await self.paste(into: target, presentationID: id)
            }
        }
        viewModel.activate()
        position(panel)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func toggle() {
        panel?.isVisible == true ? close() : show()
    }

    func close() {
        viewModel?.deactivate()
        panel?.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? NSPanel, window === panel else { return }
        close()
    }

    private func ensurePanel() -> (ClipboardHistoryPanel, ClipboardHistoryViewModel) {
        if let panel, let viewModel { return (panel, viewModel) }

        let viewModel = ClipboardHistoryViewModel()
        viewModel.onRequestClose = { [weak self] in self?.close() }
        let hosting = NSHostingController(
            rootView: ClipboardHistoryPanelView(viewModel: viewModel)
        )
        let chrome = ClipboardHistoryPanelChromeView(frame: .zero)
        chrome.autoresizingMask = [.width, .height]
        hosting.view.frame = chrome.bounds
        hosting.view.autoresizingMask = [.width, .height]
        chrome.addSubview(hosting.view)

        let panel = ClipboardHistoryPanel(
            contentRect: CGRect(x: 0, y: 0, width: 880, height: 610),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.contentView = chrome
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        self.panel = panel
        self.viewModel = viewModel
        self.hostingController = hosting
        return (panel, viewModel)
    }

    /// Centers the panel on the display containing the pointer, while keeping the
    /// complete window inside that display's usable area on every invocation.
    private func position(_ panel: NSPanel) {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let visibleFrame = screen?.visibleFrame else {
            panel.center()
            return
        }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.midY - size.height / 2
        ))
    }

    private static var pasteUnavailable: ClipboardHistoryError {
        .unavailable(L10n.tr("未能粘贴到原应用，内容已保留在剪贴板中"))
    }

    private func paste(into target: NSRunningApplication?, presentationID: UUID) async throws {
        guard AXIsProcessTrusted() else {
            throw ClipboardHistoryError.accessibilityRequired
        }
        guard self.presentationID == presentationID, NSRunningApplication.current.isActive,
              panel?.isKeyWindow == true, let target, !target.isEqual(NSRunningApplication.current) else {
            throw Self.pasteUnavailable
        }
        guard !target.isTerminated else {
            throw ClipboardHistoryError.unavailable(L10n.tr("原应用已经关闭，内容已保留在剪贴板中"))
        }

        try await Self.deliverPaste(to: target.processIdentifier, activate: {
            let activated: Bool
            if #available(macOS 14.0, *) {
                NSApp.yieldActivation(to: target)
                activated = target.activate(from: .current, options: [])
            } else {
                activated = target.activate(options: [.activateIgnoringOtherApps])
            }
            if activated { self.close() }
            return activated
        }, hasFocus: {
            self.presentationID == presentationID &&
                !target.isTerminated &&
                target.isEqual(NSWorkspace.shared.frontmostApplication)
        }, post: Self.postPasteEvents)
    }

    static func deliverPaste(
        to processID: pid_t,
        activate: () -> Bool,
        hasFocus: () -> Bool,
        post: (pid_t) throws -> Void
    ) async throws {
        guard processID > 0, activate() else { throw pasteUnavailable }
        try await Task.sleep(nanoseconds: 140_000_000)
        guard hasFocus() else { throw pasteUnavailable }
        try post(processID)
    }

    private static func postPasteEvents(to processID: pid_t) throws {
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false) else {
            throw pasteUnavailable
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.postToPid(processID)
        keyUp.postToPid(processID)
    }
}
