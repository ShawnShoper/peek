import AppKit
import QuartzCore
import SwiftUI

private final class SearchFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class SearchPanelChromeView: NSVisualEffectView {
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
        layer?.cornerRadius = SearchPanelLayout.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        updateBorderColor()
    }

    private func updateBorderColor() {
        layer?.borderColor = NSColor.separatorColor
            .withAlphaComponent(0.42)
            .cgColor
    }
}

private final class SearchPanelContentViewController: NSViewController {
    private let hostingController: NSHostingController<SearchPanelView>
    private var expandedCanvasHeight = SearchPanelLayout.expandedHeight

    init(rootView: SearchPanelView) {
        hostingController = NSHostingController(rootView: rootView)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = SearchPanelChromeView(frame: .zero)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(hostingController)
        hostingController.view.autoresizingMask = []
        view.addSubview(hostingController.view)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        hostingController.view.frame = SearchPanelLayout.canvasFrame(
            in: view.bounds,
            expandedHeight: expandedCanvasHeight
        )
    }

    func setExpandedCanvasHeight(_ height: CGFloat) {
        let resolvedHeight = max(SearchPanelLayout.collapsedHeight, height)
        guard abs(expandedCanvasHeight - resolvedHeight) > 0.5 else { return }
        expandedCanvasHeight = resolvedHeight
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
    }
}

enum SearchPanelLayout {
    static let width: CGFloat = 920
    static let collapsedHeight: CGFloat = 58
    static let expandedHeight: CGFloat = 680
    static let minimumWidth: CGFloat = 840
    static let expansionDuration: TimeInterval = 0.20
    static let collapseDuration: TimeInterval = 0.16
    static let screenMargin: CGFloat = 16
    static let cornerRadius: CGFloat = 16

    /// The SwiftUI scene is laid out once at its expanded size. The AppKit
    /// chrome clips this top-anchored canvas as the window height changes.
    static func canvasFrame(
        in bounds: CGRect,
        expandedHeight: CGFloat
    ) -> CGRect {
        let canvasHeight = max(collapsedHeight, expandedHeight)
        return CGRect(
            x: bounds.minX,
            y: bounds.maxY - canvasHeight,
            width: bounds.width,
            height: canvasHeight
        )
    }

    static func shouldAnimate(
        requested: Bool,
        panelVisible: Bool,
        reduceMotion: Bool
    ) -> Bool {
        requested && panelVisible && !reduceMotion
    }

    /// Recreates the legacy layout reference: the complete search panel is
    /// centered inside the current screen's usable area. Both compact and
    /// expanded states derive from this frame so the search field never moves.
    static func centeredExpandedFrame(in visibleFrame: CGRect) -> CGRect {
        let availableWidth = max(1, visibleFrame.width - screenMargin * 2)
        let availableHeight = max(
            collapsedHeight,
            visibleFrame.height - screenMargin * 2
        )
        let targetWidth = min(width, availableWidth)
        let targetHeight = min(expandedHeight, availableHeight)
        return CGRect(
            x: visibleFrame.midX - targetWidth / 2,
            y: visibleFrame.midY - targetHeight / 2,
            width: targetWidth,
            height: targetHeight
        ).integral
    }

    static func animationDuration(expanded: Bool) -> TimeInterval {
        expanded ? expansionDuration : collapseDuration
    }

    static func centeredFrame(
        expanded: Bool,
        in visibleFrame: CGRect
    ) -> CGRect {
        let reference = centeredExpandedFrame(in: visibleFrame)
        guard !expanded else { return reference }
        return CGRect(
            x: reference.minX,
            y: reference.maxY - collapsedHeight,
            width: reference.width,
            height: collapsedHeight
        )
    }

    static func frame(
        from currentFrame: CGRect,
        expanded: Bool,
        visibleFrame: CGRect?
    ) -> CGRect {
        let maximumExpandedHeight = visibleFrame.map {
            max(collapsedHeight, $0.height - screenMargin * 2)
        } ?? expandedHeight
        let targetHeight = expanded
            ? min(expandedHeight, maximumExpandedHeight)
            : collapsedHeight
        var targetFrame = currentFrame
        targetFrame.size.height = targetHeight
        targetFrame.origin.y = currentFrame.maxY - targetHeight

        guard let visibleFrame else { return targetFrame }
        if targetFrame.minY < visibleFrame.minY {
            targetFrame.origin.y = visibleFrame.minY
        }
        if targetFrame.maxY > visibleFrame.maxY {
            targetFrame.origin.y = visibleFrame.maxY - targetHeight
        }
        return targetFrame
    }
}

/// Explicit presentation API. Call `show(provider:)` from a menu item, button,
/// command, or a future non-conflicting shortcut; SearchUI itself registers no
/// global shortcut and therefore cannot conflict with macOS input-source keys.
@MainActor
final class SearchPanelController: NSObject, NSWindowDelegate {
    static let shared = SearchPanelController()

    private var panel: SearchFloatingPanel?
    private var viewModel: SearchPanelViewModel?
    private var panelIsExpanded: Bool?
    private var panelAnimationGeneration = 0

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Builds the reusable panel and warms the default query while the app is
    /// idle. It never presents a window or marks the search UI as active.
    func prepare(
        provider: any SearchPanelProviding,
        actionHandler: (any SearchPanelActionHandling)? = nil
    ) {
        let (_, viewModel) = ensurePanel(
            provider: provider,
            actionHandler: actionHandler
        )
        viewModel.prewarm()
    }

    func show(
        provider: any SearchPanelProviding,
        actionHandler: (any SearchPanelActionHandling)? = nil,
        initialQuery: String? = nil
    ) {
        if let panel, panel.isVisible {
            if let initialQuery {
                viewModel?.activateForPanel(initialQuery: initialQuery)
            }
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            return
        }

        let settingsWasVisible = NSApp.windows.contains {
            PEEKSettingsWindowPresenter.isSettingsWindow($0) && $0.isVisible
        }
        let (panel, viewModel) = ensurePanel(
            provider: provider,
            actionHandler: actionHandler
        )
        let preferences = SearchPanelPreferences.current()
        panel.alphaValue = CGFloat(preferences.windowOpacity)
        viewModel.activateForPanel(initialQuery: initialQuery)
        setPanelExpanded(viewModel.hasVisibleQuery, animated: false)
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
        viewModel?.pauseForPanel()
        panel?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingPanel = notification.object as? NSPanel,
              panel === closingPanel else {
            return
        }
        FileSearchIndexRuntime.shared.setSearchPanelActive(false)
        viewModel?.pauseForPanel()
    }

    /// Permanently releases the cached SwiftUI graph. Normal dismissals should
    /// call `close()` so repeated global-shortcut invocations stay fast.
    func destroy() {
        FileSearchIndexRuntime.shared.setSearchPanelActive(false)
        guard let closingPanel = panel else {
            viewModel?.shutdown()
            viewModel = nil
            return
        }
        let closingViewModel = viewModel
        panel = nil
        viewModel = nil
        closingViewModel?.shutdown()
        closingPanel.delegate = nil
        closingPanel.orderOut(nil)
        DispatchQueue.main.async {
            closingPanel.contentViewController = nil
        }
    }

    private func ensurePanel(
        provider: any SearchPanelProviding,
        actionHandler: (any SearchPanelActionHandling)?
    ) -> (SearchFloatingPanel, SearchPanelViewModel) {
        if let panel, let viewModel {
            return (panel, viewModel)
        }

        let viewModel = SearchPanelViewModel(
            provider: provider,
            actionHandler: actionHandler
        )
        viewModel.onRequestClose = { [weak self] in
            self?.close()
        }
        let contentController = SearchPanelContentViewController(
            rootView: SearchPanelView(
                viewModel: viewModel,
                onExpansionChanged: { [weak self] expanded in
                    self?.setPanelExpanded(expanded, animated: true)
                }
            )
        )
        let panel = SearchFloatingPanel(
            contentRect: CGRect(
                x: 0,
                y: 0,
                width: SearchPanelLayout.width,
                height: SearchPanelLayout.expandedHeight
            ),
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
        panel.minSize = CGSize(
            width: SearchPanelLayout.minimumWidth,
            height: SearchPanelLayout.collapsedHeight
        )
        panel.contentViewController = contentController
        panel.delegate = self
        let frameAutosaveName = "PEEK.SearchPanel.v4"
        let preferences = SearchPanelPreferences.current()
        panel.alphaValue = CGFloat(preferences.windowOpacity)
        if preferences.position == .remembered {
            panel.setFrameAutosaveName(frameAutosaveName)
        }
        if preferences.position != .remembered
            || !panel.setFrameUsingName(frameAutosaveName) {
            position(
                panel,
                on: preferredScreen(for: preferences.screen),
                expanded: viewModel.hasVisibleQuery
            )
        }

        self.panel = panel
        self.viewModel = viewModel
        panelIsExpanded = nil
        _ = contentController.view
        contentController.view.layoutSubtreeIfNeeded()
        return (panel, viewModel)
    }

    private func setPanelExpanded(_ expanded: Bool, animated: Bool) {
        guard let panel else { return }
        let preferences = SearchPanelPreferences.current()
        let preferred = preferredScreen(for: preferences.screen)
        let screen = preferences.position == .centered
            ? preferred
            : panel.screen ?? preferred
        let targetFrame: CGRect
        if preferences.position == .centered,
           let visibleFrame = screen?.visibleFrame {
            targetFrame = SearchPanelLayout.centeredFrame(
                expanded: expanded,
                in: visibleFrame
            )
        } else {
            targetFrame = SearchPanelLayout.frame(
                from: panel.frame,
                expanded: expanded,
                visibleFrame: screen?.visibleFrame
            )
        }
        if expanded,
           let contentController = panel.contentViewController
            as? SearchPanelContentViewController {
            contentController.setExpandedCanvasHeight(targetFrame.height)
        }
        let stateChanged = panelIsExpanded != expanded
        panelIsExpanded = expanded
        let frameChanged = abs(panel.frame.minX - targetFrame.minX) > 0.5
            || abs(panel.frame.minY - targetFrame.minY) > 0.5
            || abs(panel.frame.width - targetFrame.width) > 0.5
            || abs(panel.frame.height - targetFrame.height) > 0.5
        guard stateChanged || frameChanged else {
            return
        }

        panelAnimationGeneration &+= 1
        let animationGeneration = panelAnimationGeneration
        let shouldAnimate = SearchPanelLayout.shouldAnimate(
            requested: animated,
            panelVisible: panel.isVisible,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
        guard shouldAnimate else {
            panel.setFrame(targetFrame, display: true)
            panel.invalidateShadow()
            return
        }
        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = SearchPanelLayout.animationDuration(
                    expanded: expanded
                )
                context.timingFunction = CAMediaTimingFunction(
                    name: .easeInEaseOut
                )
                context.allowsImplicitAnimation = true
                panel.animator().setFrame(targetFrame, display: true)
            },
            completionHandler: { [weak self, weak panel] in
                Task { @MainActor [weak self, weak panel] in
                    guard let self,
                          self.panelAnimationGeneration == animationGeneration else {
                        return
                    }
                    panel?.invalidateShadow()
                }
            }
        )
    }

    private func preferredScreen(
        for preference: SearchWindowScreenPreference
    ) -> NSScreen? {
        guard preference == .mouse else { return NSScreen.main }
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
            ?? NSScreen.main
    }

    @objc private func screenParametersDidChange(_ notification: Notification) {
        guard panel?.isVisible == true else { return }
        setPanelExpanded(
            panelIsExpanded ?? viewModel?.hasVisibleQuery ?? false,
            animated: false
        )
    }

    private func position(
        _ panel: NSPanel,
        on screen: NSScreen?,
        expanded: Bool
    ) {
        guard let visibleFrame = screen?.visibleFrame else {
            panel.center()
            return
        }
        panel.setFrame(
            SearchPanelLayout.centeredFrame(
                expanded: expanded,
                in: visibleFrame
            ),
            display: false
        )
    }
}
