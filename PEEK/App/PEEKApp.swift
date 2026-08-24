import AppKit
import Darwin
import SwiftUI

enum AppBrand {
    static let displayName = "PEEK"
    static let menuBarIconAssetName = "PEEKMenuBarIcon"
}

extension Notification.Name {
    static let peekOpenDocumentSearchSettings = Notification.Name(
        "PEEK.openDocumentSearchSettings"
    )
}

@MainActor
enum PEEKSettingsWindowPresenter {
    static let windowIdentifier = NSUserInterfaceItemIdentifier("PEEK.settings")
    private static let focusRetryDelays: [TimeInterval] = [0, 0.08, 0.2]
    private static var presentationGeneration: UInt64 = 0
    private static var contentFactory: (() -> AnyView)?
    private static var windowController: NSWindowController?

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
            focusRetryDelays.forEach { delay in
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    focusSettingsWindowIfCurrent(generation)
                }
            }
        }
    }

    static func isSettingsWindow(_ window: NSWindow) -> Bool {
        window.identifier == windowIdentifier
    }

    /// Hides only PEEK's owned settings window and leaves the menu-bar app alive.
    /// This is used for Command-Q while Settings is visible; explicit Quit
    /// actions still terminate the application normally.
    @discardableResult
    static func closeIfVisible(in windows: [NSWindow] = NSApp.windows) -> Bool {
        // Cancel delayed focus retries first so a just-hidden Settings window
        // cannot be ordered front again a few milliseconds after Command-Q.
        invalidatePendingPresentation()
        let visibleSettingsWindows = windows.filter {
            isSettingsWindow($0) && ($0.isVisible || $0.isMiniaturized)
        }
        guard !visibleSettingsWindows.isEmpty else { return false }

        visibleSettingsWindows.forEach { $0.orderOut(nil) }
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
    /// existing NSWindow with orderOut. The generation check prevents delayed
    /// retries from an older presentation attempt from reopening it.
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

@MainActor
final class PEEKAppDelegate: NSObject, NSApplicationDelegate {
    private let instanceLock = SingleInstanceLock()
    private var ownsInstanceLock = false
    private var screenCaptureMetadataTask: Task<Void, Never>?
    private var screenCaptureMetadataLifecycleGeneration: UInt64 = 0
    private var settingsQuitShortcutMonitor: Any?
#if DEBUG
    private let screenshotToolbarPreviewController = ScreenshotEditorController()
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            SearchPanelController.shared.prepare(
                provider: FileSearchPanelProvider.shared
            )
        }
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--show-screenshot-toolbar-for-ui-testing") {
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
                TranslationPanelController.shared.show(previewMode: true)
            }
        } else if ProcessInfo.processInfo.arguments.contains("--show-settings-for-ui-testing") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                PEEKSettingsWindowPresenter.show()
            }
        } else {
            scheduleFirstLaunchDocumentAuthorizationPrompt()
        }
#else
        scheduleFirstLaunchDocumentAuthorizationPrompt()
#endif
    }

#if DEBUG
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
        for window in NSApp.windows
        where window.isVisible && PEEKSettingsWindowPresenter.isSettingsWindow(window) {
            window.orderOut(nil)
        }
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
        UserDefaults.standard.set(
            true,
            forKey: PEEKPreferenceKey.openDocumentSearchSettings
        )
        PEEKSettingsWindowPresenter.show()
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .peekOpenDocumentSearchSettings,
                object: nil
            )
        }
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
