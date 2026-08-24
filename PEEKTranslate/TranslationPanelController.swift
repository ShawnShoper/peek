import AppKit
import QuartzCore
import SwiftUI

private final class TranslationFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class TranslationPanelChromeView: NSVisualEffectView {
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
        updateBorderColor()
    }

    private func configure() {
        material = .popover
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = TranslationPanelLayout.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        updateBorderColor()
    }

    private func updateBorderColor() {
        layer?.borderColor = NSColor.separatorColor
            .withAlphaComponent(0.5)
            .cgColor
    }
}

private final class TranslationPanelContentViewController: NSViewController {
    private let hostingController: NSHostingController<TranslationPanelRootView>

    init(rootView: TranslationPanelRootView) {
        hostingController = NSHostingController(rootView: rootView)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = TranslationPanelChromeView(frame: .zero)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(hostingController)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hostingController.view)
        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }
}

@MainActor
final class TranslationPanelController: NSObject, NSWindowDelegate {
    static let shared = TranslationPanelController()

    private var panel: TranslationFloatingPanel?
    private var previewMode = false
    private var closeGeneration = 0
    private var isClosing = false

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidResignActive(_:)),
            name: NSApplication.didResignActiveNotification,
            object: NSApp
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func show(previewMode: Bool = false) {
        if self.previewMode != previewMode {
            destroy()
        }
        closeGeneration &+= 1
        isClosing = false
        self.previewMode = previewMode
        let panel = ensurePanel()
        panel.setFrame(targetFrame(), display: false)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                ? 0
                : 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    func toggle() {
        if panel?.isVisible == true {
            close()
        } else {
            show()
        }
    }

    func close() {
        guard let panel, panel.isVisible, !isClosing else { return }
        isClosing = true
        closeGeneration &+= 1
        let generation = closeGeneration
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            finishClosing(panel, generation: generation)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak panel] in
            Task { @MainActor [weak self] in
                guard let self, let panel else { return }
                self.finishClosing(panel, generation: generation)
            }
        }
    }

    func destroy() {
        closeGeneration &+= 1
        isClosing = false
        let oldPanel = panel
        panel = nil
        oldPanel?.delegate = nil
        oldPanel?.orderOut(nil)
        oldPanel?.contentViewController = nil
        oldPanel?.close()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        close()
        return false
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let resignedPanel = notification.object as? TranslationFloatingPanel,
              resignedPanel === panel,
              resignedPanel.isVisible else {
            return
        }
        DispatchQueue.main.async { [weak self, weak resignedPanel] in
            guard let self,
                  let resignedPanel,
                  resignedPanel === self.panel,
                  TranslationPanelDismissalPolicy.shouldDismissAfterKeyChange(
                      isVisible: resignedPanel.isVisible,
                      isKeyWindow: resignedPanel.isKeyWindow
                  ) else {
                return
            }
            self.close()
        }
    }

    @objc private func screenParametersDidChange(_ notification: Notification) {
        guard let panel, panel.isVisible else { return }
        panel.setFrame(targetFrame(), display: true, animate: false)
    }

    @objc private func applicationDidResignActive(_ notification: Notification) {
        close()
    }

    private func finishClosing(
        _ closingPanel: TranslationFloatingPanel,
        generation: Int
    ) {
        guard generation == closeGeneration,
              closingPanel === panel else {
            return
        }
        destroy()
    }

    private func ensurePanel() -> TranslationFloatingPanel {
        if let panel { return panel }

        let panel = TranslationFloatingPanel(
            contentRect: CGRect(
                origin: .zero,
                size: CGSize(
                    width: TranslationPanelLayout.width,
                    height: TranslationPanelLayout.height
                )
            ),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.minSize = CGSize(
            width: TranslationPanelLayout.minimumWidth,
            height: TranslationPanelLayout.minimumHeight
        )
        panel.contentViewController = TranslationPanelContentViewController(
            rootView: TranslationPanelRootView(
                previewMode: previewMode,
                onClose: { [weak self] in self?.close() }
            )
        )
        panel.setAccessibilityLabel(L10n.tr("PEEK 翻译"))
        self.panel = panel
        return panel
    }

    private func targetFrame() -> CGRect {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame
            ?? CGRect(
                x: 0,
                y: 0,
                width: TranslationPanelLayout.width,
                height: TranslationPanelLayout.height
            )
        return TranslationPanelLayout.centeredFrame(in: visibleFrame)
    }
}
