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
    private static let settingsWindowIdentifier = "com_apple_SwiftUI_Settings_window"
    private static let focusRetryDelays: [TimeInterval] = [0, 0.08, 0.2]

    static func show() {
        // MenuBarExtra actions run while AppKit is still dismissing the menu.
        // Defer presentation to the next run loop so the settings window can
        // become key instead of being ordered behind the previously active app.
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.sendAction(
                Selector(("showSettingsWindow:")),
                to: nil,
                from: nil
            )
            focusRetryDelays.forEach { delay in
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    focusSettingsWindowIfAvailable()
                }
            }
        }
    }

    static func isSettingsWindow(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue == settingsWindowIdentifier
    }

    private static func focusSettingsWindowIfAvailable() {
        guard let window = NSApp.windows.first(where: isSettingsWindow) else { return }
        window.collectionBehavior.insert(.moveToActiveSpace)
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
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
        ScreenshotGlobalHotKeyManager.shared.start { action in
            Task { @MainActor in
                switch action {
                case .region:
                    await service.captureRegion(
                        presentationDelayNanoseconds: ScreenshotCapturePresentationDelay
                            .hotKeyNanoseconds
                    )
                case .scrolling:
                    await service.captureScrolling(
                        presentationDelayNanoseconds: ScreenshotCapturePresentationDelay
                            .hotKeyNanoseconds
                    )
                case .ocr:
                    await service.captureAndRecognizeText(
                        presentationDelayNanoseconds: ScreenshotCapturePresentationDelay
                            .hotKeyNanoseconds
                    )
                case .search:
                    SearchPanelController.shared.toggle(provider: searchProvider)
                }
            }
        }
    }

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(screenshotService)
                .frame(minWidth: 980, minHeight: 640)
        }

        MenuBarExtra(AppBrand.displayName, image: AppBrand.menuBarIconAssetName) {
            MenuBarMenuView(searchProvider: searchProvider)
                .environmentObject(screenshotService)
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class PEEKAppDelegate: NSObject, NSApplicationDelegate {
    private let instanceLock = SingleInstanceLock()
    private var ownsInstanceLock = false
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
        NotificationCenter.default.removeObserver(
            self,
            name: NSApplication.didFinishRestoringWindowsNotification,
            object: NSApp
        )
        FileSearchIndexRuntime.shared.stop()
        SearchPanelController.shared.destroy()
        ScreenshotGlobalHotKeyManager.shared.stop()
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
        for window in NSApp.windows where window.isVisible && window.title != L10n.tr("文件查找") {
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
