import AppKit
import Darwin
import SwiftUI

enum AppBrand {
    static let displayName = "PEEK"
    static let menuBarIconAssetName = "PEEKMenuBarIcon"
}

enum PEEKSettingsDestination: String, CaseIterable, Identifiable, Sendable {
    case general
    case search
    case clipboard
    case shortcuts
    case translation
    case capture
    case appearance
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return L10n.tr("通用")
        case .search: return L10n.tr("搜索")
        case .clipboard: return L10n.tr("剪贴板")
        case .shortcuts: return L10n.tr("快捷键")
        case .translation: return L10n.tr("翻译")
        case .capture: return L10n.tr("截图")
        case .appearance: return L10n.tr("外观")
        case .about: return L10n.tr("关于")
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .search: return "magnifyingglass"
        case .clipboard: return "clipboard"
        case .shortcuts: return "keyboard"
        case .translation: return "character.book.closed"
        case .capture: return "viewfinder.circle"
        case .appearance: return "paintpalette"
        case .about: return "info.circle"
        }
    }
}

/// Keeps a settings destination until the cached SwiftUI settings graph has
/// consumed it. This works for both an already-open window and the first
/// presentation, without relying on a notification posted after a fixed delay.
@MainActor
final class PEEKSettingsRouteCoordinator: ObservableObject {
    static let shared = PEEKSettingsRouteCoordinator()

    @Published private(set) var revision: UInt64 = 0
    private var pendingDestination: PEEKSettingsDestination?

    func request(_ destination: PEEKSettingsDestination) {
        pendingDestination = destination
        revision &+= 1
        if revision == 0 {
            revision = 1
        }
    }

    func consumePendingDestination() -> PEEKSettingsDestination? {
        defer { pendingDestination = nil }
        return pendingDestination
    }
}

/// Mirrors whether the retained settings window is actually on screen. The
/// settings view uses this signal to stop index polling while it is hidden or
/// minimized instead of keeping a permanent background timer alive.
@MainActor
final class PEEKSettingsWindowVisibility: ObservableObject {
    static let shared = PEEKSettingsWindowVisibility()

    @Published private(set) var isVisible = false

    func update(_ isVisible: Bool) {
        guard self.isVisible != isVisible else { return }
        self.isVisible = isVisible
    }
}

@MainActor
private final class PEEKSettingsWindowDelegate: NSObject, NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        PEEKSettingsWindowVisibility.shared.update(false)
    }

    func windowDidMiniaturize(_ notification: Notification) {
        PEEKSettingsWindowVisibility.shared.update(false)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        PEEKSettingsWindowVisibility.shared.update(window.isVisible)
    }
}

@MainActor
enum PEEKSettingsWindowPresenter {
    static let windowIdentifier = NSUserInterfaceItemIdentifier("PEEK.settings")
    private static var presentationGeneration: UInt64 = 0
    private static var contentFactory: (() -> AnyView)?
    private static var windowController: NSWindowController?
    private static let windowDelegate = PEEKSettingsWindowDelegate()

    static func configure(screenshotService: ScreenshotService) {
        contentFactory = {
            AnyView(
                SettingsView()
                    .environmentObject(screenshotService)
                    .frame(minWidth: 980, minHeight: 640)
            )
        }
    }

    static func show() {
        let generation = beginPresentationAttempt()
        // MenuBarExtra actions run while AppKit is still dismissing the menu.
        // Defer presentation to the next run loop so the settings window can
        // become key instead of being ordered behind the previously active app.
        DispatchQueue.main.async {
            guard isCurrentPresentationAttempt(generation) else { return }
            guard let controller = settingsWindowController() else { return }
            NSApp.activate(ignoringOtherApps: true)
            controller.showWindow(nil)
            focusSettingsWindowIfCurrent(generation)
            // Settings displays clipboard storage usage even when history is
            // paused, so load its metadata only after the window is requested.
            ClipboardHistoryMonitor.shared.reloadIfNeeded()
        }
    }

    static func show(destination: PEEKSettingsDestination) {
        PEEKSettingsRouteCoordinator.shared.request(destination)
        show()
    }

    static func isSettingsWindow(_ window: NSWindow) -> Bool {
        window.identifier == windowIdentifier
    }

    /// Hides only PEEK's owned settings window and leaves the menu-bar app alive.
    /// This is used for Command-Q while Settings is visible; explicit Quit
    /// actions still terminate the application normally.
    @discardableResult
    static func closeIfVisible(in windows: [NSWindow] = NSApp.windows) -> Bool {
        // Invalidate a presentation already queued for the next run loop so a
        // just-hidden Settings window cannot be ordered front again.
        invalidatePendingPresentation()
        let visibleSettingsWindows = windows.filter {
            isSettingsWindow($0) && ($0.isVisible || $0.isMiniaturized)
        }
        guard !visibleSettingsWindows.isEmpty else { return false }

        visibleSettingsWindows.forEach { $0.orderOut(nil) }
        PEEKSettingsWindowVisibility.shared.update(false)
        return true
    }

    @discardableResult
    static func beginPresentationAttempt() -> UInt64 {
        presentationGeneration &+= 1
        if presentationGeneration == 0 {
            presentationGeneration = 1
        }
        return presentationGeneration
    }

    static func isCurrentPresentationAttempt(_ generation: UInt64) -> Bool {
        generation == presentationGeneration
    }

    private static func invalidatePendingPresentation() {
        _ = beginPresentationAttempt()
    }

    /// Brings the owned settings window back even when Command-Q previously hid its
    /// existing NSWindow with orderOut. The generation check prevents an older
    /// queued presentation attempt from reopening it.
    @discardableResult
    static func focusSettingsWindowIfCurrent(
        _ generation: UInt64,
        in windows: [NSWindow] = NSApp.windows,
        activateApplication: Bool = true
    ) -> Bool {
        guard isCurrentPresentationAttempt(generation) else { return false }
        guard let window = windows.first(where: isSettingsWindow) else { return false }
        window.collectionBehavior.insert(.moveToActiveSpace)
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        if activateApplication {
            NSApp.activate(ignoringOtherApps: true)
        }
        PEEKSettingsWindowVisibility.shared.update(true)
        return true
    }

    static func makeWindowController(rootView: AnyView) -> NSWindowController {
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 980, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hostingController
        window.identifier = windowIdentifier
        window.title = AppBrand.displayName
        window.minSize = NSSize(width: 980, height: 640)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.delegate = windowDelegate
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.setFrameAutosaveName("PEEK.SettingsWindow")
        window.center()
        return NSWindowController(window: window)
    }

    private static func settingsWindowController() -> NSWindowController? {
        if let windowController {
            return windowController
        }
        guard let contentFactory else { return nil }
        let controller = makeWindowController(rootView: contentFactory())
        windowController = controller
        return controller
    }
}

enum PEEKSettingsQuitShortcutPolicy {
    static func matches(
        charactersIgnoringModifiers: String?,
        modifierFlags: NSEvent.ModifierFlags
    ) -> Bool {
        let relevantModifiers = modifierFlags.intersection([
            .command,
            .option,
            .control,
            .shift,
        ])
        return relevantModifiers == .command
            && charactersIgnoringModifiers?.lowercased() == "q"
    }
}

@main
struct PEEKApp: App {
    @NSApplicationDelegateAdaptor(PEEKAppDelegate.self) private var appDelegate
    @StateObject private var screenshotService: ScreenshotService
    private let searchProvider: FileSearchPanelProvider

    init() {
        let service = ScreenshotService()
        let searchProvider = FileSearchPanelProvider.shared
        _screenshotService = StateObject(wrappedValue: service)
        self.searchProvider = searchProvider
        PEEKSettingsWindowPresenter.configure(screenshotService: service)
        PEEKBuiltInToolLauncher.shared.configure(screenshotService: service)
        ScreenshotGlobalHotKeyManager.shared.start { action, diagnosticSession in
            ScreenshotCaptureDiagnostics.record(
                "action_handler_started",
                session: diagnosticSession
            )
            switch action {
            case .region:
                await ScreenshotCaptureDiagnostics.$currentSession.withValue(
                    diagnosticSession
                ) {
                    await service.captureRegion(
                        presentationDelayNanoseconds: ScreenshotCapturePresentationDelay
                            .hotKeyNanoseconds
                    )
                }
            case .scrolling:
                await ScreenshotCaptureDiagnostics.$currentSession.withValue(
                    diagnosticSession
                ) {
                    await service.captureScrolling(
                        presentationDelayNanoseconds: ScreenshotCapturePresentationDelay
                            .hotKeyNanoseconds
                    )
                }
            case .ocr:
                await ScreenshotCaptureDiagnostics.$currentSession.withValue(
                    diagnosticSession
                ) {
                    await service.captureAndRecognizeText(
                        presentationDelayNanoseconds: ScreenshotCapturePresentationDelay
                            .hotKeyNanoseconds
                    )
                }
            case .search:
                SearchPanelController.shared.toggle(provider: searchProvider)
            case .translation:
                TranslationPanelController.shared.toggle()
            case .clipboardHistory:
                ClipboardHistoryPanelController.shared.toggle()
            }
        }
    }

    var body: some Scene {
        MenuBarExtra(AppBrand.displayName, image: AppBrand.menuBarIconAssetName) {
            MenuBarMenuView(searchProvider: searchProvider)
                .environmentObject(screenshotService)
        }
        .menuBarExtraStyle(.menu)
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button(L10n.tr("关闭设置")) {
                    PEEKSettingsWindowPresenter.closeIfVisible()
                }
                .keyboardShortcut("q", modifiers: [.command])
            }
        }
    }
}

/// Central action dispatcher for commands opened from PEEK search. Screenshot
/// actions wait until the search panel is hidden so it cannot enter the capture.
@MainActor
final class PEEKBuiltInToolLauncher {
    static let shared = PEEKBuiltInToolLauncher()

    private weak var screenshotService: ScreenshotService?

    private init() {}

    func configure(screenshotService: ScreenshotService) {
        self.screenshotService = screenshotService
    }

    func open(_ behavior: SearchPanelLaunchBehavior) {
        switch behavior {
        case .fileURL:
            SearchPanelController.shared.close()
        case .peekTranslation:
            SearchPanelController.shared.close()
            TranslationPanelController.shared.show()
        case .peekClipboardHistory:
            SearchPanelController.shared.close()
            ClipboardHistoryPanelController.shared.show()
        case .peekSettings(let destination):
            SearchPanelController.shared.close()
            PEEKSettingsWindowPresenter.show(destination: destination)
        case .peekRegionCapture, .peekScrollingCapture, .peekOCRCapture:
            guard let screenshotService else { return }
            SearchPanelController.shared.closeThenPerform {
                Task { @MainActor in
                    switch behavior {
                    case .peekRegionCapture:
                        await screenshotService.captureRegion()
                    case .peekScrollingCapture:
                        await screenshotService.captureScrolling()
                    case .peekOCRCapture:
                        await screenshotService.captureAndRecognizeText()
                    default:
                        break
                    }
                }
            }
        }
    }
}

@MainActor
final class PEEKAppDelegate: NSObject, NSApplicationDelegate {
    private let instanceLock = SingleInstanceLock()
    private var ownsInstanceLock = false
    private var screenCaptureMetadataTask: Task<Void, Never>?
    private var screenCaptureMetadataLifecycleGeneration: UInt64 = 0
    private var settingsQuitShortcutMonitor: Any?
#if DEBUG
    private let screenshotToolbarPreviewController = ScreenshotEditorController()
    private let screenshotSelectionPreviewCoordinator = ScreenshotCaptureCoordinator()
    private var screenshotSelectionPreviewTask: Task<Void, Never>?
#endif

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard instanceLock.acquire() else {
            activateExistingInstance()
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
            return
        }
        ownsInstanceLock = true
        PEEKAppearanceController.applyCurrent()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationFinishedRestoringWindows(_:)),
            name: NSApplication.didFinishRestoringWindowsNotification,
            object: NSApp
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ownsInstanceLock else { return }
        hideAutomaticallyRestoredWindows()
        installSettingsQuitShortcutMonitor()
        installScreenCaptureMetadataLifecycleObservers()
        refreshScreenCaptureMetadata(invalidateFirst: false)
        FileSearchIndexRuntime.shared.start()
        ClipboardHistoryMonitor.shared.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            SearchPanelController.shared.prepare(
                provider: FileSearchPanelProvider.shared
            )
        }
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--show-screenshot-selection-for-ui-testing") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.showScreenshotSelectionPreview()
            }
        } else if ProcessInfo.processInfo.arguments.contains("--show-screenshot-toolbar-for-ui-testing") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.showScreenshotToolbarPreview()
            }
        } else if ProcessInfo.processInfo.arguments.contains("--show-ocr-result-for-ui-testing") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.showOCRResultPreview()
            }
        } else if ProcessInfo.processInfo.arguments.contains("--show-search-panel-for-ui-testing") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                SearchPanelController.shared.show(
                    provider: FileSearchPanelProvider.shared,
                    initialQuery: "wei xin"
                )
            }
        } else if ProcessInfo.processInfo.arguments.contains("--show-translation-panel-for-ui-testing") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                TranslationPanelController.shared.show()
            }
        } else if ProcessInfo.processInfo.arguments.contains("--show-onboarding-for-ui-testing") {
            PEEKFirstLaunchOnboardingPolicy.requestReplay()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                PEEKSettingsWindowPresenter.show()
            }
        } else if ProcessInfo.processInfo.arguments.contains("--show-settings-for-ui-testing") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                PEEKSettingsWindowPresenter.show()
            }
        } else {
            scheduleInitialExperience()
        }
#else
        scheduleInitialExperience()
#endif
    }

#if DEBUG
    private func showScreenshotSelectionPreview() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let selectionSize = CGSize(
            width: min(920, screen.frame.width * 0.55),
            height: min(560, screen.frame.height * 0.48)
        )
        let selectionRect = CGRect(
            x: screen.frame.midX - selectionSize.width / 2,
            y: screen.frame.midY - selectionSize.height / 2,
            width: selectionSize.width,
            height: selectionSize.height
        ).integral

        screenshotSelectionPreviewTask?.cancel()
        screenshotSelectionPreviewTask = Task { @MainActor [weak self] in
            guard let self else { return }
            _ = try? await screenshotSelectionPreviewCoordinator.captureRegion(
                requestPermissionIfNeeded: false,
                presentationDelayNanoseconds: 0,
                initialSelectionRect: selectionRect,
                initialSelectionHint: L10n.tr("拖动选区可移动，拖动边角可缩放")
            )
        }
    }

    private func showScreenshotToolbarPreview() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let safeFrame = screen.visibleFrame.insetBy(dx: 48, dy: 80)
        let selectionSize = CGSize(
            width: min(980, safeFrame.width),
            height: min(460, safeFrame.height)
        )
        let selectionRect = CGRect(
            x: safeFrame.midX - selectionSize.width / 2,
            y: safeFrame.midY - selectionSize.height / 2 + 72,
            width: selectionSize.width,
            height: selectionSize.height
        ).integral
        let image = NSImage(size: selectionSize, flipped: false) { rect in
            NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
            rect.fill()
            NSColor(calibratedWhite: 0.16, alpha: 1).setFill()
            NSBezierPath(
                roundedRect: rect.insetBy(dx: 72, dy: 64),
                xRadius: 20,
                yRadius: 20
            ).fill()
            return true
        }
        NSApp.activate(ignoringOtherApps: true)
        screenshotToolbarPreviewController.editInline(
            image: image,
            selectionRect: selectionRect,
            screenFrame: screen.frame,
            renderSelection: { _ in image },
            onSelectionChanged: { _ in },
            onAction: nil,
            initialTool: .pen,
            focusToolbarForUITesting: true
        ) { _, _ in }
    }

    private func showOCRResultPreview() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flagIndex = arguments.firstIndex(of: "--show-ocr-result-for-ui-testing"),
              arguments.indices.contains(flagIndex + 1),
              let image = NSImage(contentsOfFile: arguments[flagIndex + 1]) else {
            return
        }
        Task { @MainActor in
            do {
                let result = try await PEEKOCRService().recognize(image: image)
                _ = PEEKOCRResultPresenter.shared.present(
                    result: result,
                    image: image,
                    title: L10n.tr("图片 OCR")
                )
            } catch {
                let alert = NSAlert(error: error)
                alert.runModal()
            }
        }
    }
#endif

    func applicationWillTerminate(_ notification: Notification) {
        screenCaptureMetadataTask?.cancel()
        screenCaptureMetadataTask = nil
        if let settingsQuitShortcutMonitor {
            NSEvent.removeMonitor(settingsQuitShortcutMonitor)
            self.settingsQuitShortcutMonitor = nil
        }
        removeScreenCaptureMetadataLifecycleObservers()
        NotificationCenter.default.removeObserver(
            self,
            name: NSApplication.didFinishRestoringWindowsNotification,
            object: NSApp
        )
        ClipboardHistoryMonitor.shared.stop()
        FileSearchIndexRuntime.shared.stop()
        SearchPanelController.shared.destroy()
        TranslationPanelController.shared.destroy()
        ScreenshotGlobalHotKeyManager.shared.stop()
    }

    private func installSettingsQuitShortcutMonitor() {
        guard settingsQuitShortcutMonitor == nil else { return }
        settingsQuitShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            event in
            guard PEEKSettingsQuitShortcutPolicy.matches(
                charactersIgnoringModifiers: event.charactersIgnoringModifiers,
                modifierFlags: event.modifierFlags
            ), PEEKSettingsWindowPresenter.closeIfVisible() else {
                return event
            }

            // Consume Command-Q only after hiding Settings. Explicit menu-bar
            // Quit does not produce this key event and still terminates PEEK.
            return nil
        }
    }

    /// Prewarm only ScreenCaptureKit metadata when screen recording access is
    /// already granted. This never prompts and never stores desktop pixels.
    private func refreshScreenCaptureMetadata(invalidateFirst: Bool) {
        let generation = nextScreenCaptureMetadataLifecycleGeneration()
        screenCaptureMetadataTask?.cancel()
        screenCaptureMetadataTask = Task.detached(priority: .utility) {
            let accepted = await SystemScreenImageCapturer.applyMetadataLifecycleTransition(
                generation: generation,
                invalidateCachedMetadata: invalidateFirst
            )
            guard accepted, !Task.isCancelled else { return }
            await SystemScreenImageCapturer.prewarmIfAuthorized()
        }
    }

    private func invalidateScreenCaptureMetadata() {
        let generation = nextScreenCaptureMetadataLifecycleGeneration()
        screenCaptureMetadataTask?.cancel()
        screenCaptureMetadataTask = Task.detached(priority: .utility) {
            _ = await SystemScreenImageCapturer.applyMetadataLifecycleTransition(
                generation: generation,
                invalidateCachedMetadata: true
            )
        }
    }

    private func nextScreenCaptureMetadataLifecycleGeneration() -> UInt64 {
        screenCaptureMetadataLifecycleGeneration &+= 1
        if screenCaptureMetadataLifecycleGeneration == 0 {
            screenCaptureMetadataLifecycleGeneration = 1
        }
        return screenCaptureMetadataLifecycleGeneration
    }

    private func installScreenCaptureMetadataLifecycleObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: NSApp
        )
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(
            self,
            selector: #selector(workspaceWillSleep(_:)),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(workspaceDidWake(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    private func removeScreenCaptureMetadataLifecycleObservers() {
        NotificationCenter.default.removeObserver(
            self,
            name: NSApplication.didChangeScreenParametersNotification,
            object: NSApp
        )
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.removeObserver(
            self,
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        workspaceCenter.removeObserver(
            self,
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    @objc private func screenParametersDidChange(_ notification: Notification) {
        refreshScreenCaptureMetadata(invalidateFirst: true)
    }

    @objc private func workspaceWillSleep(_ notification: Notification) {
        invalidateScreenCaptureMetadata()
    }

    @objc private func workspaceDidWake(_ notification: Notification) {
        refreshScreenCaptureMetadata(invalidateFirst: true)
    }

    private func activateExistingInstance() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .first { $0.processIdentifier != currentPID }?
            .activate(options: [.activateIgnoringOtherApps])
    }

    @objc private func applicationFinishedRestoringWindows(_ notification: Notification) {
        hideAutomaticallyRestoredWindows()
    }

    private func hideAutomaticallyRestoredWindows() {
        var didHideSettings = false
        for window in NSApp.windows
        where window.isVisible && PEEKSettingsWindowPresenter.isSettingsWindow(window) {
            window.orderOut(nil)
            didHideSettings = true
        }
        if didHideSettings {
            PEEKSettingsWindowVisibility.shared.update(false)
        }
    }

    private func scheduleInitialExperience() {
        guard !scheduleFirstLaunchOnboarding() else { return }
        scheduleFirstLaunchDocumentAuthorizationPrompt()
    }

    @discardableResult
    private func scheduleFirstLaunchOnboarding() -> Bool {
        guard PEEKFirstLaunchOnboardingPolicy.preparePresentationIfNeeded() else {
            return false
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            PEEKSettingsWindowPresenter.show()
        }
        return true
    }

    private func scheduleFirstLaunchDocumentAuthorizationPrompt() {
        let defaultRoots = FileSearchDocumentDefaultRootStore.shared.roots
        let authorizedRoots = FileSearchAuthorizedRootStore.shared.roots
        let missingRoots = FileSearchDocumentRootAuthorization.missingRoots(
            from: defaultRoots,
            authorizedRoots: authorizedRoots
        )
        guard FileSearchFirstLaunchAuthorizationPromptPolicy.shouldPresent(
            missingRootCount: missingRoots.count
        ) else {
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = L10n.tr("完成文件搜索目录授权")
            alert.informativeText = L10n.tr(
                "还有 %d 个默认目录未授权。打开搜索设置后，点击目录右侧的“授权”按钮即可；PEEK 不会自动扫描未授权位置。",
                missingRoots.count
            )
            alert.addButton(withTitle: L10n.tr("打开设置"))
            alert.addButton(withTitle: L10n.tr("稍后"))
            if alert.runModal() == .alertFirstButtonReturn {
                self.openDocumentSearchSettings()
            }
        }
    }

    private func openDocumentSearchSettings() {
        PEEKSettingsWindowPresenter.show(destination: .search)
    }
}

private final class SingleInstanceLock {
    private var fileDescriptor: Int32 = -1

    func acquire() -> Bool {
        guard fileDescriptor == -1 else { return true }

        let fileManager = FileManager.default
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return false
        }

        let directory = applicationSupport.appendingPathComponent("PEEK", isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return false
        }

        let lockURL = directory.appendingPathComponent("PEEK.instance.lock")
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return false }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            return false
        }

        fileDescriptor = descriptor
        return true
    }

    deinit {
        guard fileDescriptor >= 0 else { return }
        flock(fileDescriptor, LOCK_UN)
        Darwin.close(fileDescriptor)
    }
}
