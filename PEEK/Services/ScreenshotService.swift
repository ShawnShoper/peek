import AppKit
import Foundation

@MainActor
final class ScreenshotService: ObservableObject {
    private static let capturePreparationTimeoutNanoseconds: UInt64 = 8_000_000_000

    private struct PreparedScrollTarget {
        let canAutomaticallyScroll: Bool
        let recognizedRegion: ScrollCaptureTarget?
        let windowAnchor: ScrollCaptureWindowAnchor?
    }

    private struct ScrollAttemptContext {
        let selectionRect: CGRect
        let captureRect: CGRect
        let modeDescription: String
        let configuredPixelLimit: Int
        /// Pixel delta sent in the wheel event. The target application may
        /// consume less; image overlap remains the source of truth for the
        /// observed content displacement.
        let requestedScrollAmount: Int?
        let targetApplicationName: String?
        let targetWindowID: CGWindowID?
        let automaticTargetValidated: Bool

        func updating(
            captureRect: CGRect? = nil,
            requestedScrollAmount: Int? = nil,
            automaticTargetValidated: Bool? = nil
        ) -> ScrollAttemptContext {
            ScrollAttemptContext(
                selectionRect: selectionRect,
                captureRect: captureRect ?? self.captureRect,
                modeDescription: modeDescription,
                configuredPixelLimit: configuredPixelLimit,
                requestedScrollAmount: requestedScrollAmount ?? self.requestedScrollAmount,
                targetApplicationName: targetApplicationName,
                targetWindowID: targetWindowID,
                automaticTargetValidated: automaticTargetValidated
                    ?? self.automaticTargetValidated
            )
        }
    }

    private enum ScrollRecoveryAction {
        case retryWithReducedStep
        case reselect
        case switchToManual
        case savePartial(ScrollCaptureResult)
        case cancel
    }

    @Published private(set) var isCapturing = false
    @Published private(set) var isScrolling = false
    @Published private(set) var isRecognizingText = false
    @Published private(set) var lastMessage: String?

    private let captureCoordinator: ScreenshotCaptureCoordinator
    private let editorController = ScreenshotEditorController()
    private let ocrService = PEEKOCRService()
    private let qrCodeService = PEEKQRCodeService()
    private let scrollTargetResolver = ScrollCaptureTargetResolver()
    private let indexActivityController: any FileSearchIndexActivityControlling
    private let capturePreparationTimeoutNanoseconds: UInt64
    private var scrollSession: ScrollCaptureSession?
    private var originalFrontmostApplication: NSRunningApplication?
    private var scrollTargetApplication: NSRunningApplication?
    private var scrollCaptureTarget: ScrollCaptureTarget?
    private var scrollWindowAnchor: ScrollCaptureWindowAnchor?
    private var shouldReactivateOriginalApplication = true
    private var activeCaptureRequest: ScreenshotCaptureRequestToken?
    private var capturePreparationWatchdog: Task<Void, Never>?
    /// The eight-second watchdog covers only permission/freeze/overlay setup.
    /// Selection, scrolling, OCR and editing are user work and must never be
    /// cancelled by the preparation timer after their overlay has completed.
    private var capturePreparationCompleted = false
    private var scrollAttemptContext: ScrollAttemptContext?
    private var pendingScrollAmountOverride: Int?
    /// Recovery choices are scoped to the next attempt. They must never
    /// rewrite the user's persistent automatic/manual preference.
    private var pendingScrollAutomaticOverride: Bool?

    init(
        indexActivityController: any FileSearchIndexActivityControlling =
            FileSearchIndexRuntime.shared,
        captureCoordinator: ScreenshotCaptureCoordinator = ScreenshotCaptureCoordinator(),
        capturePreparationTimeoutNanoseconds: UInt64 =
            ScreenshotService.capturePreparationTimeoutNanoseconds
    ) {
        self.indexActivityController = indexActivityController
        self.captureCoordinator = captureCoordinator
        self.capturePreparationTimeoutNanoseconds = max(
            1_000_000,
            capturePreparationTimeoutNanoseconds
        )
    }

    /// 启动时冻结一次桌面；选区与编辑始终引用同一份不可变画面。
    func captureRegion(
        presentationDelayNanoseconds: UInt64 = ScreenshotCapturePresentationDelay
            .uiDismissalNanoseconds
    ) async {
        let scrollRect = await captureWithEditor(
            message: L10n.tr("拖动选择区域；可移动或缩放，双击或 Enter 后截图")
        ) { request in
            await self.captureRegionWithEditor(
                request: request, presentationDelayNanoseconds: presentationDelayNanoseconds
            )
        }
        if let scrollRect {
            await captureScrolling(initialSelectionRect: scrollRect)
        }
    }

    private func captureRegionWithEditor(
        request: ScreenshotCaptureRequestToken,
        presentationDelayNanoseconds: UInt64
    ) async {
        do {
            guard try await captureCoordinator.captureRegionWithInlineEditor(
                presentationDelayNanoseconds: presentationDelayNanoseconds,
                requestToken: request,
                onAction: { [weak self] action in
                    self?.handleEditorAction(action, request: request)
                }
            ) != nil else {
                guard ownsCapture(request) else { return }
                if !request.editorActionOccurred {
                    lastMessage = L10n.tr("已取消截图")
                }
                return
            }
            try checkCaptureCancellation(request)
            completeCapturePreparation()

            // Inline Done/double-click has already written the rendered image
            // to the pasteboard. Default capture never creates a history file;
            // the explicit Save toolbar action remains available when needed.
            lastMessage = L10n.tr("截图已复制到剪贴板")
        } catch {
            guard ownsCapture(request) else { return }
            handleCaptureFailure(error, operation: L10n.tr("截图"))
        }
    }

    /// 先选定滚动容器可见区域，再自动或手动采集并拼接。
    func captureScrolling(
        initialSelectionRect: CGRect? = nil,
        presentationDelayNanoseconds: UInt64 = ScreenshotCapturePresentationDelay
            .uiDismissalNanoseconds
    ) async {
        var selectionRect = initialSelectionRect
        repeat {
            let currentRect = selectionRect
            selectionRect = await captureWithEditor(message: L10n.tr("请选择要连续滚动的内容区域")) { request in
                await self.captureScrollAttempt(
                    initialSelectionRect: currentRect,
                    presentationDelayNanoseconds: presentationDelayNanoseconds,
                    captureRequest: request
                )
            }
        } while selectionRect != nil
    }

    // Consume the editor's next selection after this request's windows close.
    // Both the inline editor and the scroll-result editor use this handoff.
    func captureWithEditor(
        message: String,
        operation: (ScreenshotCaptureRequestToken) async -> Void
    ) async -> CGRect? {
        guard let request = beginCapture(message: message) else { return nil }
        defer { endCapture(request: request) }
        await operation(request)
        guard ownsCapture(request), !Task.isCancelled else { return nil }
        return request.requestedScrollSelection
    }

    private func captureScrollAttempt(
        initialSelectionRect: CGRect?,
        presentationDelayNanoseconds: UInt64,
        captureRequest: ScreenshotCaptureRequestToken
    ) async {
        guard ownsCapture(captureRequest) else { return }
        // A recovery retry can lower the scroll distance for one attempt
        // without rewriting the user's persistent pixel ceiling.
        let automaticAmountOverride = pendingScrollAmountOverride
        pendingScrollAmountOverride = nil
        let automaticModeOverride = pendingScrollAutomaticOverride
        pendingScrollAutomaticOverride = nil

        do {
            if let initialSelectionRect {
                completeCapturePreparation()
                let selectedWindow = scrollTargetResolver.resolveWindow(
                    containingAppKitPoint: CGPoint(
                        x: initialSelectionRect.midX,
                        y: initialSelectionRect.midY
                    )
                )
                scrollWindowAnchor = selectedWindow.flatMap(Self.windowAnchor)
                scrollTargetApplication = selectedWindow.flatMap {
                    NSRunningApplication(processIdentifier: $0.ownerPID)
                }
                try await performScrollCapture(
                    selectionRect: initialSelectionRect,
                    automaticAmountOverride: automaticAmountOverride,
                    automaticModeOverride: automaticModeOverride,
                    request: captureRequest
                )
                return
            }

            // Sample before the selection overlay appears. With a global
            // shortcut the pointer normally remains over the intended content;
            // a menu-bar trigger can fall back to the underlying front window.
            let pointerLocation = NSEvent.mouseLocation
            let detectedWindowTarget = shouldAutoDetectScrollTarget
                ? await scrollTargetResolver.resolve(
                    frontmostApplication: originalFrontmostApplication,
                    pointerAppKitPoint: pointerLocation
                )
                : nil
            let detectedTarget = detectedWindowTarget.flatMap { target in
                target.isVerifiedScrollRegion
                    && target.wasPointerHitTested
                    && target.windowID != 0 ? target : nil
            }
            try checkCaptureCancellation(captureRequest)
            scrollCaptureTarget = detectedTarget
            scrollWindowAnchor = detectedWindowTarget.flatMap(Self.windowAnchor)
            if let detectedTarget {
                scrollTargetApplication = NSRunningApplication(
                    processIdentifier: detectedTarget.ownerPID
                )
                let targetName = scrollTargetDisplayName(detectedTarget)
                lastMessage = detectedTarget.wasClippedToSingleScreen
                    ? L10n.tr("已识别跨屏窗口“%@”，已预选面积最大的一侧；按 Enter 确认或拖动修正", targetName)
                    : L10n.tr("已识别“%@”；按 Enter 确认或拖动修正", targetName)
            } else if let detectedWindowTarget {
                scrollTargetApplication = NSRunningApplication(
                    processIdentifier: detectedWindowTarget.ownerPID
                )
                lastMessage = detectedWindowTarget.wasClippedToSingleScreen
                    ? L10n.tr("鼠标不在可识别滚动区域，已预选窗口面积最大的一侧；可拖动调整")
                    : L10n.tr("鼠标不在可识别滚动区域，已预选当前窗口；可拖动调整")
            } else if shouldAutoDetectScrollTarget {
                lastMessage = L10n.tr("未能识别鼠标所在窗口，请手动框选内容区域")
            }

            guard let capture = try await captureCoordinator.captureRegion(
                presentationDelayNanoseconds: presentationDelayNanoseconds,
                initialSelectionRect: detectedTarget?.captureRect
                    ?? detectedWindowTarget.flatMap {
                        Self.singleScreenWindowRect($0.windowFrame)
                    },
                initialSelectionHint: detectedWindowTarget.map { target in
                    if target.isVerifiedScrollRegion {
                        return L10n.tr("已定位鼠标所在滚动区域 · Enter 开始，拖动可调整")
                    }
                    return L10n.tr("已预选当前窗口 · Enter 开始，拖动可自定义选区")
                },
                automaticHoverWindowRect: detectedWindowTarget.flatMap {
                    Self.singleScreenWindowRect($0.windowFrame)
                },
                automaticHoverSelectionRects: detectedWindowTarget?.hoverSelectionRects ?? [],
                requestToken: captureRequest
            ) else {
                guard ownsCapture(captureRequest) else { return }
                lastMessage = L10n.tr("已取消滚动截图")
                return
            }
            try checkCaptureCancellation(captureRequest)
            completeCapturePreparation()

            if let detectedTarget,
               !capture.wasInitialSelectionModified,
               Self.framesApproximatelyEqual(
                   capture.selectionRect,
                   detectedTarget.captureRect,
                   tolerance: 1
               ) {
                scrollCaptureTarget = detectedTarget
                scrollTargetApplication = NSRunningApplication(
                    processIdentifier: detectedTarget.ownerPID
                )
            } else {
                scrollCaptureTarget = nil
            }
            // AX semantics are only a preselection hint. Bind the final user
            // rectangle to the exact WindowServer window even when the user
            // adjusted it or AX could expose only a window-level fallback.
            let selectedWindow = scrollTargetResolver.resolveWindow(
                containingAppKitPoint: CGPoint(
                    x: capture.selectionRect.midX,
                    y: capture.selectionRect.midY
                )
            )
            scrollWindowAnchor = selectedWindow.flatMap(Self.windowAnchor)
            scrollTargetApplication = selectedWindow.flatMap {
                NSRunningApplication(processIdentifier: $0.ownerPID)
            }
            try await performScrollCapture(
                selectionRect: capture.selectionRect,
                automaticAmountOverride: automaticAmountOverride,
                automaticModeOverride: automaticModeOverride,
                request: captureRequest
            )
        } catch is CancellationError {
            guard ownsCapture(captureRequest) else { return }
            lastMessage = L10n.tr("已取消滚动截图")
        } catch {
            guard ownsCapture(captureRequest) else { return }
            let recoveryAction = handleScrollCaptureFailure(error)
            guard ownsCapture(captureRequest) else { return }
            switch recoveryAction {
            case .savePartial(let result):
                shouldReactivateOriginalApplication = true
                do {
                    guard let captureRect = scrollAttemptContext?.captureRect
                        ?? scrollAttemptContext?.selectionRect else {
                        throw ScrollCaptureError.invalidConfiguration(
                            L10n.tr("无法恢复本次滚动截图选区")
                        )
                    }
                    try await editAndSavePartialScrollResult(
                        result,
                        captureRect: captureRect,
                        request: captureRequest
                    )
                } catch {
                    guard ownsCapture(captureRequest) else { return }
                    handleCaptureFailure(error, operation: L10n.tr("保存部分滚动截图"))
                    presentCaptureAlert(
                        title: L10n.tr("部分滚动截图保存失败"),
                        message: error.localizedDescription
                    )
                }
            case .retryWithReducedStep, .reselect, .switchToManual:
                shouldReactivateOriginalApplication = true
                scheduleScrollRecovery(recoveryAction, request: captureRequest)
            case .cancel:
                return
            }
        }
    }

    /// 选区后直接使用 Vision 在本机识别中英文，不保存或上传图片。
    func captureAndRecognizeText(
        presentationDelayNanoseconds: UInt64 = ScreenshotCapturePresentationDelay
            .uiDismissalNanoseconds
    ) async {
        guard let captureRequest = beginCapture(
            message: L10n.tr("请选择需要 OCR 的区域")
        ) else {
            return
        }
        defer { endCapture(request: captureRequest) }

        do {
            guard let capture = try await captureCoordinator.captureRegion(
                presentationDelayNanoseconds: presentationDelayNanoseconds,
                requestToken: captureRequest
            ) else {
                guard ownsCapture(captureRequest) else { return }
                lastMessage = L10n.tr("已取消 OCR")
                return
            }
            try checkCaptureCancellation(captureRequest)
            completeCapturePreparation()
            shouldReactivateOriginalApplication = false
            await recognizeText(in: capture.image, title: L10n.tr("截图 OCR"))
        } catch {
            guard ownsCapture(captureRequest) else { return }
            handleCaptureFailure(error, operation: L10n.tr("OCR 截图"))
        }
    }

    func stopScrollingCapture() {
        guard let scrollSession else { return }
        Task { await scrollSession.stop() }
    }

    func cancelActiveCapture() {
        let request = activeCaptureRequest
        request?.cancel()
        captureCoordinator.cancelCapture()
        if let scrollSession {
            Task { await scrollSession.cancel() }
        }
        editorController.closeAll()
        if let request {
            endCapture(request: request)
            lastMessage = L10n.tr("已取消截图")
        }
    }

    func openScreenRecordingSettings() {
        openPrivacySettings(anchor: "Privacy_ScreenCapture")
    }

    func openAccessibilitySettings() {
        openPrivacySettings(anchor: "Privacy_Accessibility")
    }

    private func beginCapture(message: String) -> ScreenshotCaptureRequestToken? {
        guard !isCapturing else {
            lastMessage = L10n.tr("已有截图任务正在进行；按 Esc 可取消")
            return nil
        }
        let request = ScreenshotCaptureRequestToken()
        activeCaptureRequest = request
        originalFrontmostApplication = NSWorkspace.shared.frontmostApplication
        scrollTargetApplication = nil
        scrollCaptureTarget = nil
        scrollWindowAnchor = nil
        scrollAttemptContext = nil
        capturePreparationCompleted = false
        shouldReactivateOriginalApplication = true
        isCapturing = true
        lastMessage = message
        // Capture is user-initiated work and must start independently of the
        // background indexer's activity queue. The blocker is delivered in
        // order on a dedicated fire-and-forget path.
        indexActivityController.beginCaptureActivity()
        armCapturePreparationWatchdog(for: request)
        do {
            try request.checkCancellation()
        } catch {
            endCapture(request: request)
            return nil
        }
        return request
    }

    private func endCapture(request: ScreenshotCaptureRequestToken) {
        guard activeCaptureRequest === request else { return }
        let originalApplication = originalFrontmostApplication
        let shouldReactivate = shouldReactivateOriginalApplication
        activeCaptureRequest = nil
        capturePreparationWatchdog?.cancel()
        capturePreparationWatchdog = nil
        capturePreparationCompleted = false
        isCapturing = false
        isScrolling = false
        indexActivityController.endCaptureActivity()
        scrollSession = nil
        originalFrontmostApplication = nil
        scrollTargetApplication = nil
        scrollCaptureTarget = nil
        scrollWindowAnchor = nil
        scrollAttemptContext = nil
        shouldReactivateOriginalApplication = true

        if shouldReactivate,
           let originalApplication,
           !originalApplication.isTerminated {
            originalApplication.activate(options: [.activateIgnoringOtherApps])
        }
    }

    /// The selection watchdog starts only after an overlay exists. This
    /// independent watchdog covers the earlier index-signal, permission and
    /// ScreenCaptureKit freeze phases so the menu can never remain stuck in
    /// “capturing” indefinitely.
    private func armCapturePreparationWatchdog(
        for request: ScreenshotCaptureRequestToken
    ) {
        capturePreparationWatchdog?.cancel()
        let diagnosticSession = ScreenshotCaptureDiagnostics.currentSession
        let timeoutNanoseconds = capturePreparationTimeoutNanoseconds
        capturePreparationWatchdog = Task { @MainActor [weak self, weak request] in
            do {
                try await Task.sleep(
                    nanoseconds: timeoutNanoseconds
                )
            } catch {
                return
            }
            guard let self,
                  let request,
                  self.activeCaptureRequest === request,
                  !self.capturePreparationCompleted,
                  !self.captureCoordinator.hasPresentedOverlay else {
                return
            }
            request.cancel()
            self.captureCoordinator.cancelCapture()
            self.endCapture(request: request)
            self.lastMessage = ScreenshotCaptureError.preparationTimedOut.localizedDescription
            if let diagnosticSession {
                ScreenshotCaptureDiagnostics.record(
                    "capture_preparation_timed_out",
                    session: diagnosticSession
                )
            }
        }
    }

    /// Ends only the pre-overlay watchdog. The capture request itself remains
    /// active until scrolling/editing finishes or the user cancels it.
    private func completeCapturePreparation() {
        guard !capturePreparationCompleted else { return }
        capturePreparationCompleted = true
        capturePreparationWatchdog?.cancel()
        capturePreparationWatchdog = nil
    }

    private func handleCaptureFailure(_ error: Error, operation: String) {
        lastMessage = L10n.tr("%@失败：%@", operation, error.localizedDescription)

        guard let captureError = error as? ScreenshotCaptureError else { return }
        switch captureError {
        case .screenRecordingPermissionDenied:
            shouldReactivateOriginalApplication = false
            presentPermissionAlert(requiresRestart: false)
        case .screenRecordingPermissionRequiresRestart:
            shouldReactivateOriginalApplication = false
            presentPermissionAlert(requiresRestart: true)
        case .overlayPresentationFailed, .selectionTimedOut:
            shouldReactivateOriginalApplication = false
            presentCaptureAlert(
                title: L10n.tr("截图选区未完成"),
                message: captureError.localizedDescription
            )
        default:
            break
        }
    }

    private func presentPermissionAlert(requiresRestart: Bool) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = requiresRestart ? L10n.tr("需要重新启动 PEEK") : L10n.tr("需要屏幕录制权限")
        alert.informativeText = requiresRestart
            ? L10n.tr("macOS 已记录授权，但当前进程仍在使用旧权限状态。请完全退出并重新打开 PEEK。")
            : L10n.tr("PEEK 需要屏幕录制权限才能读取选区。请在“隐私与安全性”中允许 PEEK，随后完全退出并重新打开应用。")
        alert.addButton(withTitle: requiresRestart ? L10n.tr("退出 PEEK") : L10n.tr("打开系统设置"))
        alert.addButton(withTitle: L10n.tr("稍后"))
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        if requiresRestart {
            NSApp.terminate(nil)
        } else {
            openScreenRecordingSettings()
        }
    }

    private func presentCaptureAlert(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: L10n.tr("好"))
        alert.runModal()
    }

    private func openPrivacySettings(anchor: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private func edit(
        _ image: NSImage, sourceSelectionRect: CGRect, request: ScreenshotCaptureRequestToken
    ) async -> NSImage? {
        guard ownsCapture(request) else { return nil }
        return await editorController.edit(image: image) { [weak self] action in
            self?.handleEditorAction(action, request: request, sourceSelectionRect: sourceSelectionRect)
        }
    }

    func handleEditorAction(
        _ action: ScreenshotEditorAction,
        request: ScreenshotCaptureRequestToken,
        sourceSelectionRect: CGRect? = nil
    ) {
        guard ownsCapture(request) else { return }
        request.editorActionOccurred = true
        switch action {
        case .pinRequested(let rendered):
            _ = PEEKPinboard.shared.pin(image: rendered)
            PEEKUsageStore.shared.recordUse()
            lastMessage = L10n.tr("截图已钉在桌面上")
        case .ocrRequested(let rendered):
            shouldReactivateOriginalApplication = false
            Task { @MainActor [weak self] in
                await self?.recognizeText(in: rendered, title: L10n.tr("截图 OCR"))
            }
        case .qrCodeRequested(let rendered):
            shouldReactivateOriginalApplication = false
            Task { @MainActor [weak self] in
                await self?.recognizeQRCode(in: rendered)
            }
        case .scrollCaptureRequested:
            request.requestedScrollSelection = sourceSelectionRect
        case .scrollCaptureRequestedInSelection(_, let selectionRect):
            request.requestedScrollSelection = selectionRect
        case .copied:
            PEEKUsageStore.shared.recordUse()
            lastMessage = L10n.tr("截图已复制到剪贴板")
        case .saved(_, let url):
            PEEKUsageStore.shared.recordUse()
            lastMessage = L10n.tr("截图已保存到 %@", url.lastPathComponent)
        }
    }

    private func performScrollCapture(
        selectionRect: CGRect,
        automaticAmountOverride: Int?,
        automaticModeOverride: Bool?,
        request: ScreenshotCaptureRequestToken
    ) async throws {
        try checkCaptureCancellation(request)
        completeCapturePreparation()
        lastMessage = L10n.tr("正在准备滚动截图…")
        let useAutomatic = ScrollCapturePreferenceResolver.automaticScrollingEnabled(
            defaults: .standard,
            attemptOverride: automaticModeOverride
        )
        let persistedConfiguredAmount = UserDefaults.standard.integer(
            forKey: "screenshot.scrollAmount"
        ).nonZeroOr(700)
        let requestedAmount = automaticAmountOverride.map {
            min(max(1, $0), persistedConfiguredAmount)
        } ?? persistedConfiguredAmount
        scrollAttemptContext = ScrollAttemptContext(
            selectionRect: selectionRect,
            captureRect: selectionRect,
            modeDescription: useAutomatic ? L10n.tr("自动滚动") : L10n.tr("手动滚动"),
            configuredPixelLimit: persistedConfiguredAmount,
            requestedScrollAmount: nil,
            targetApplicationName: scrollTargetApplication?.localizedName,
            targetWindowID: scrollWindowAnchor?.windowID,
            automaticTargetValidated: false
        )
        if useAutomatic, !AccessibilityScrollPermission.isGranted {
            throw ScrollCaptureError.accessibilityPermissionDenied
        }
        let preparedTarget = try await prepareScrollTarget(
            for: selectionRect,
            automaticRequested: useAutomatic,
            request: request
        )
        try checkCaptureCancellation(request)
        // 等选区遮罩或编辑器窗口完全离开 WindowServer，避免首帧残影。
        try await Task.sleep(nanoseconds: 240_000_000)
        try checkCaptureCancellation(request)

        let captureRect = preparedTarget.recognizedRegion?.captureRect ?? selectionRect
        guard Self.containingScreen(for: captureRect) != nil else {
            throw ScrollCaptureError.invalidConfiguration(L10n.tr("滚动截图选区必须完整位于同一显示器内"))
        }

        let mode = try ScrollCaptureModeResolver.resolve(
            automaticRequested: useAutomatic,
            accessibilityGranted: AccessibilityScrollPermission.isGranted,
            hasValidatedWindowAnchor: preparedTarget.canAutomaticallyScroll,
            configuredAmount: requestedAmount,
            captureHeight: captureRect.height
        )
        let requestedScrollAmount: Int? = if case .automatic(let automatic) = mode {
            Int(automatic.amount)
        } else {
            nil
        }
        scrollAttemptContext = scrollAttemptContext?.updating(
            captureRect: captureRect,
            requestedScrollAmount: requestedScrollAmount,
            automaticTargetValidated: preparedTarget.canAutomaticallyScroll
        )

        let maximumFrames = UserDefaults.standard.integer(forKey: "screenshot.scrollMaxFrames")
            .nonZeroOr(30)
        let scrollPoint = preparedTarget.recognizedRegion?.scrollPoint
            ?? Self.quartzPoint(fromAppKitPoint: CGPoint(
                x: captureRect.midX,
                y: captureRect.midY
            ))
        let captureQuartzRect = Self.quartzRect(fromAppKitRect: captureRect)
        let configuration = ScrollCaptureConfiguration(
            captureRect: captureQuartzRect,
            scrollPoint: scrollPoint,
            mode: mode,
            captureInterval: 0.75,
            maximumFrames: min(max(maximumFrames, 2), 100),
            maximumDuration: 300
        )
        let session = ScrollCaptureSession(
            configuration: configuration,
            scrollDriver: QuartzAutomaticScrollDriver(
                anchor: preparedTarget.windowAnchor,
                selectionQuartzRect: captureQuartzRect
            )
        )
        let result = try await runScrollSession(session, for: request)
        try checkCaptureCancellation(request)
        if result.stopReason == .alignmentStopped {
            // A validated prefix is useful, but it is not the bottom of the
            // page. Route it through the existing explicit partial-result
            // choice instead of opening a truncated image as if capture had
            // completed successfully.
            throw ScrollCapturePartialFailure(
                underlying: .unreliableScrollRegion(
                    frame: result.acceptedFrameCount + 1
                ),
                partialResult: result
            )
        }
        let image = NSImage(cgImage: result.image, size: .zero)
        guard let edited = await edit(image, sourceSelectionRect: captureRect, request: request) else {
            if ownsCapture(request) && !request.editorActionOccurred {
                lastMessage = L10n.tr("滚动截图已生成，但已取消保存")
            }
            return
        }
        try checkCaptureCancellation(request)
        guard copyToPasteboard(edited) else {
            throw ScreenshotCaptureError.imageRenderingFailed
        }
        PEEKUsageStore.shared.recordUse()
        lastMessage = L10n.tr("滚动截图已复制到剪贴板")
        if result.warnings.contains(where: { $0.contains(L10n.tr("固定标题栏或侧栏")) }) {
            lastMessage = L10n.tr("滚动截图已复制；已自动排除固定标题栏或侧栏")
        }
    }

    func runScrollSession(
        _ session: ScrollCaptureSession, for request: ScreenshotCaptureRequestToken
    ) async throws -> ScrollCaptureResult {
        try checkCaptureCancellation(request)
        scrollSession = session
        isScrolling = true
        defer {
            if scrollSession === session {
                scrollSession = nil
                isScrolling = false
            }
        }
        return try await session.start { [weak self] progress in
            Task { @MainActor in
                guard let self, self.ownsCapture(request), self.scrollSession === session else { return }
                self.lastMessage = progress.message
            }
        }
    }

    /// A partial result is never saved silently. It reaches this path only
    /// after the recovery alert explicitly offers the already validated prefix
    /// and the user chooses to keep it. The normal long-image editor remains in
    /// the loop so the user can inspect, annotate or cancel before persistence.
    private func editAndSavePartialScrollResult(
        _ result: ScrollCaptureResult,
        captureRect: CGRect,
        request: ScreenshotCaptureRequestToken
    ) async throws {
        let image = NSImage(cgImage: result.image, size: .zero)
        guard let edited = await edit(image, sourceSelectionRect: captureRect, request: request) else {
            if ownsCapture(request) && !request.editorActionOccurred {
                lastMessage = L10n.tr("已放弃保存部分滚动截图")
            }
            return
        }
        try checkCaptureCancellation(request)
        guard copyToPasteboard(edited) else {
            throw ScreenshotCaptureError.imageRenderingFailed
        }
        PEEKUsageStore.shared.recordUse()
        lastMessage = L10n.tr(
            "已复制失败前可靠采集的 %d 帧部分结果",
            result.acceptedFrameCount
        )
    }

    private func recognizeText(in image: NSImage, title: String) async {
        guard !isRecognizingText else {
            lastMessage = L10n.tr("已有 OCR 任务正在运行")
            return
        }
        isRecognizingText = true
        indexActivityController.setOCRActive(true)
        lastMessage = L10n.tr("正在本机识别文字…")
        defer {
            isRecognizingText = false
            indexActivityController.setOCRActive(false)
        }

        do {
            let result = try await ocrService.recognize(image: image)
            _ = PEEKOCRResultPresenter.shared.present(
                result: result,
                image: image,
                title: title
            )
            PEEKUsageStore.shared.recordUse()
            lastMessage = L10n.tr(
                "OCR 完成，识别到 %d 个文本区域",
                result.observations.count
            )
        } catch {
            lastMessage = L10n.tr("OCR 失败：%@", error.localizedDescription)
        }
    }

    private func recognizeQRCode(in image: NSImage) async {
        guard !isRecognizingText else {
            lastMessage = L10n.tr("已有图片识别任务正在运行")
            return
        }
        isRecognizingText = true
        indexActivityController.setOCRActive(true)
        lastMessage = L10n.tr("正在本机识别二维码…")
        defer {
            isRecognizingText = false
            indexActivityController.setOCRActive(false)
        }

        do {
            let result = try await qrCodeService.recognize(image: image)
            _ = PEEKQRCodeResultPresenter.shared.present(
                result: result,
                image: image
            )
            PEEKUsageStore.shared.recordUse()
            lastMessage = L10n.tr(
                "二维码识别完成，共识别到 %d 个结果",
                result.observations.count
            )
        } catch {
            lastMessage = L10n.tr("二维码识别失败：%@", error.localizedDescription)
            presentCaptureAlert(
                title: L10n.tr("未能识别二维码"),
                message: error.localizedDescription
            )
        }
    }

    private func copyToPasteboard(_ image: NSImage) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.writeObjects([image])
    }

    private static func quartzRect(fromAppKitRect rect: CGRect) -> CGRect {
        let referenceTop = NSScreen.screens.first?.frame.maxY ?? rect.maxY
        return CGRect(
            x: rect.minX,
            y: referenceTop - rect.maxY,
            width: rect.width,
            height: rect.height
        ).standardized.integral
    }

    private static func quartzPoint(fromAppKitPoint point: CGPoint) -> CGPoint {
        let referenceTop = NSScreen.screens.first?.frame.maxY ?? point.y
        return CGPoint(x: point.x, y: referenceTop - point.y)
    }

    private static func windowAnchor(
        from target: ScrollCaptureTarget
    ) -> ScrollCaptureWindowAnchor? {
        guard target.windowID != 0 else { return nil }
        return ScrollCaptureWindowAnchor(
            ownerPID: target.ownerPID,
            windowID: target.windowID,
            quartzFrame: quartzRect(fromAppKitRect: target.windowFrame)
        )
    }

    private static func containingScreen(for rect: CGRect) -> NSScreen? {
        let tolerance: CGFloat = 1
        return NSScreen.screens.first { screen in
            screen.frame.insetBy(dx: -tolerance, dy: -tolerance).contains(rect)
        }
    }

    private static func singleScreenWindowRect(_ rect: CGRect) -> CGRect? {
        NSScreen.screens
            .map { rect.standardized.intersection($0.frame) }
            .filter { !$0.isNull && $0.width >= 8 && $0.height >= 8 }
            .max { lhs, rhs in
                lhs.width * lhs.height < rhs.width * rhs.height
            }
    }

    private func prepareScrollTarget(
        for selectionRect: CGRect,
        automaticRequested: Bool,
        request: ScreenshotCaptureRequestToken
    ) async throws -> PreparedScrollTarget {
        let expectedRegion = scrollCaptureTarget
        let expectedAnchor = scrollWindowAnchor
        let target = expectedAnchor.flatMap {
            NSRunningApplication(processIdentifier: $0.ownerPID)
        } ?? scrollTargetApplication
        guard let target,
              !target.isTerminated,
              target.activationPolicy != .prohibited,
              target.activate(options: [.activateIgnoringOtherApps]) else {
            if automaticRequested || expectedRegion != nil {
                throw ScrollCaptureError.invalidConfiguration(
                    L10n.tr("滚动窗口已关闭或无法激活，请重新选择滚动区域")
                )
            }
            return PreparedScrollTarget(
                canAutomaticallyScroll: false,
                recognizedRegion: nil,
                windowAnchor: nil
            )
        }

        try await Task.sleep(nanoseconds: 220_000_000)
        try checkCaptureCancellation(request)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else {
            if automaticRequested || expectedRegion != nil {
                throw ScrollCaptureError.invalidConfiguration(
                    L10n.tr("滚动窗口已发生变化，请重新选择滚动区域")
                )
            }
            return PreparedScrollTarget(
                canAutomaticallyScroll: false,
                recognizedRegion: nil,
                windowAnchor: nil
            )
        }

        var recognizedRegion: ScrollCaptureTarget?
        if let expected = expectedRegion {
            guard expected.isVerifiedScrollRegion,
                  expected.windowID != 0,
                  let live = await scrollTargetResolver.resolve(
                      frontmostApplication: target,
                      pointerAppKitPoint: CGPoint(
                          x: expected.captureRect.midX,
                          y: expected.captureRect.midY
                      )
                  ),
                  live.isVerifiedScrollRegion,
                  live.ownerPID == expected.ownerPID,
                  live.windowID == expected.windowID,
                  live.source == expected.source,
                  Self.framesApproximatelyEqual(live.windowFrame, expected.windowFrame),
                  Self.framesApproximatelyEqual(
                      live.captureRect,
                      expected.captureRect,
                      tolerance: 2
                  ),
                  Self.framesApproximatelyEqual(
                      selectionRect,
                      live.captureRect,
                      tolerance: 1
                  ) else {
                throw ScrollCaptureError.invalidConfiguration(
                    L10n.tr("滚动内容区已发生变化，请重新选择后再开始")
                )
            }
            recognizedRegion = live
        }

        guard automaticRequested else {
            return PreparedScrollTarget(
                canAutomaticallyScroll: false,
                recognizedRegion: recognizedRegion,
                windowAnchor: expectedAnchor
            )
        }
        guard let expectedAnchor else {
            throw ScrollCaptureError.invalidConfiguration(
                L10n.tr("无法确认选区所属窗口，请将选区完整放在一个窗口内后重试")
            )
        }

        let effectiveRect = recognizedRegion?.captureRect ?? selectionRect
        let selectionQuartzRect = Self.quartzRect(fromAppKitRect: effectiveRect)
        let scrollPoint = recognizedRegion?.scrollPoint
            ?? Self.quartzPoint(fromAppKitPoint: CGPoint(
                x: effectiveRect.midX,
                y: effectiveRect.midY
            ))
        try ScrollCaptureWindowAnchorValidator.validate(
            anchor: expectedAnchor,
            selectionQuartzRect: selectionQuartzRect,
            scrollPoint: scrollPoint,
            currentPID: ProcessInfo.processInfo.processIdentifier,
            frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            windowSnapshots: QuartzAutomaticScrollDriver.captureWindowSnapshots()
        )
        return PreparedScrollTarget(
            canAutomaticallyScroll: true,
            recognizedRegion: recognizedRegion,
            windowAnchor: expectedAnchor
        )
    }

    private func ownsCapture(_ request: ScreenshotCaptureRequestToken) -> Bool {
        activeCaptureRequest === request && !request.isCancelled
    }

    private func checkCaptureCancellation(_ request: ScreenshotCaptureRequestToken) throws {
        guard ownsCapture(request) else { throw CancellationError() }
        try request.checkCancellation()
    }

    private var shouldAutoDetectScrollTarget: Bool {
        UserDefaults.standard.object(forKey: "screenshot.scrollAutoDetectTarget") == nil
            || UserDefaults.standard.bool(forKey: "screenshot.scrollAutoDetectTarget")
    }

    private func scrollTargetDisplayName(_ target: ScrollCaptureTarget) -> String {
        let applicationName = NSRunningApplication(processIdentifier: target.ownerPID)?
            .localizedName
            ?? L10n.tr("当前窗口")
        guard let title = target.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty,
              title != applicationName else {
            return applicationName
        }
        let abbreviatedTitle = title.count > 36
            ? String(title.prefix(35)) + "…"
            : title
        return "\(applicationName) · \(abbreviatedTitle)"
    }

    @discardableResult
    private func handleScrollCaptureFailure(_ error: Error) -> ScrollRecoveryAction {
        handleCaptureFailure(error, operation: L10n.tr("滚动截图"))
        let captureError: ScrollCaptureError
        let partialResult: ScrollCaptureResult?
        if let partialFailure = error as? ScrollCapturePartialFailure {
            captureError = partialFailure.underlying
            partialResult = partialFailure.partialResult
        } else if let directError = error as? ScrollCaptureError {
            captureError = directError
            partialResult = nil
        } else {
            return .cancel
        }
        shouldReactivateOriginalApplication = false
        isScrolling = false
        scrollSession = nil
        if partialResult != nil || isRecoverableScrollFailure(captureError) {
            return presentScrollRecoveryAlert(
                error: captureError,
                context: scrollAttemptContext,
                partialResult: partialResult
            )
        }
        presentCaptureAlert(
            title: L10n.tr("滚动截图已停止"),
            message: error.localizedDescription
        )
        return .cancel
    }

    private func isRecoverableScrollFailure(_ error: ScrollCaptureError) -> Bool {
        switch error {
        case .unreliableOverlap,
             .unreliableScrollRegion,
             .targetDidNotScroll,
             .scrollTargetChanged:
            return true
        default:
            return false
        }
    }

    private func presentScrollRecoveryAlert(
        error: ScrollCaptureError,
        context: ScrollAttemptContext?,
        partialResult: ScrollCaptureResult?
    ) -> ScrollRecoveryAction {
        let diagnostics = scrollDiagnostics(error: error, context: context)
        let copyTarget = ScrollDiagnosticsCopyTarget(diagnostics: diagnostics)

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.tr("滚动截图已停止")
        let partialNotice = partialResult.map {
            L10n.tr(
                "\n\n失败前已有 %d 帧通过可靠性校验，可编辑并保存这段已完成内容。",
                $0.acceptedFrameCount
            )
        } ?? ""
        alert.informativeText = L10n.tr(
            "%@%@\n\n新一轮会从目标当前画面开始。为避免缺少前段，请先让页面回到本次截图开始的位置（通常是页面起点）。如果页面尚未复位，请先取消，复位后再发起；如果已经复位，可直接重新框选。",
            error.localizedDescription,
            partialNotice
        )

        var actions: [ScrollRecoveryAction] = []
        if context?.requestedScrollAmount != nil {
            alert.addButton(withTitle: L10n.tr("减小步长并重新框选"))
            actions.append(.retryWithReducedStep)
        }
        alert.addButton(withTitle: L10n.tr("重新框选"))
        actions.append(.reselect)
        if context?.modeDescription != L10n.tr("手动滚动") {
            alert.addButton(withTitle: L10n.tr("切换手动"))
            actions.append(.switchToManual)
        }
        if let partialResult, partialResult.acceptedFrameCount >= 2 {
            alert.addButton(
                withTitle: L10n.tr(
                    "编辑并保存已完成部分（%d 帧）",
                    partialResult.acceptedFrameCount
                )
            )
            actions.append(.savePartial(partialResult))
        }
        alert.addButton(withTitle: L10n.tr("取消"))
        actions.append(.cancel)

        let copyButton = NSButton(
            title: L10n.tr("复制诊断"),
            target: copyTarget,
            action: #selector(ScrollDiagnosticsCopyTarget.copyDiagnostics(_:))
        )
        copyButton.bezelStyle = .rounded
        copyButton.controlSize = .small
        copyButton.sizeToFit()
        copyButton.frame.size.width = max(copyButton.frame.width, 100)
        alert.accessoryView = copyButton

        // NSControl keeps its target weak. Keep the helper alive for the
        // complete modal session so the accessory button also works in
        // optimized Release builds.
        let response = withExtendedLifetime(copyTarget) {
            alert.runModal()
        }
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard actions.indices.contains(index) else { return .cancel }
        return actions[index]
    }

    private func scrollDiagnostics(
        error: ScrollCaptureError,
        context: ScrollAttemptContext?
    ) -> String {
        var lines = [
            L10n.tr("PEEK 滚动截图诊断"),
            L10n.tr("时间：%@", ISO8601DateFormatter().string(from: Date())),
            L10n.tr("错误：%@", error.localizedDescription)
        ]
        if let context {
            lines.append(L10n.tr("模式：%@", context.modeDescription))
            lines.append(L10n.tr("选区：%@", Self.diagnosticDescription(context.selectionRect)))
            if !Self.framesApproximatelyEqual(context.selectionRect, context.captureRect, tolerance: 0) {
                lines.append(L10n.tr("实际采集区：%@", Self.diagnosticDescription(context.captureRect)))
            }
            lines.append(L10n.tr("设置的像素上限：%d", context.configuredPixelLimit))
            lines.append(
                L10n.tr(
                    "本次发送滚动量：%@",
                    context.requestedScrollAmount.map(String.init) ?? L10n.tr("不适用/尚未开始")
                )
            )
            lines.append(
                L10n.tr(
                    "窗口锚点校验：%@",
                    context.automaticTargetValidated ? L10n.tr("通过") : L10n.tr("未通过或不适用")
                )
            )
            if let name = context.targetApplicationName {
                lines.append(L10n.tr("目标应用：%@", name))
            }
            if let windowID = context.targetWindowID {
                lines.append(L10n.tr("目标窗口 ID：%u", windowID))
            }
        }
        lines.append(
            L10n.tr(
                "自动识别：%@",
                shouldAutoDetectScrollTarget ? L10n.tr("开启") : L10n.tr("关闭")
            )
        )
        let capabilities = ScrollCaptureRuntimeCapabilities.current
        let targetInspectionDescription: String
        switch capabilities.targetInspectionMode {
        case .accessibility:
            targetInspectionDescription = L10n.tr("辅助功能滚动区")
        case .visualCompatibility:
            switch capabilities.appSandboxState {
            case .enabled:
                targetInspectionDescription = L10n.tr("视觉兼容模式（App Sandbox）")
            case .disabled:
                targetInspectionDescription = L10n.tr("视觉兼容模式")
            case .unknown:
                targetInspectionDescription = L10n.tr("视觉兼容模式（运行环境未确认）")
            }
        }
        lines.append(L10n.tr("滚动定位方式：%@", targetInspectionDescription))
        lines.append(
            L10n.tr(
                "Post Event 权限：%@",
                AccessibilityScrollPermission.isGranted ? L10n.tr("已授权") : L10n.tr("未授权")
            )
        )
        return lines.joined(separator: "\n")
    }

    private static func diagnosticDescription(_ rect: CGRect) -> String {
        let standardized = rect.standardized
        return "x=\(Int(standardized.minX.rounded())), y=\(Int(standardized.minY.rounded())), "
            + "w=\(Int(standardized.width.rounded())), h=\(Int(standardized.height.rounded()))"
    }

    private func scheduleScrollRecovery(_ action: ScrollRecoveryAction, request: ScreenshotCaptureRequestToken) {
        let reducedAmount: Int?
        if case .retryWithReducedStep = action,
           let currentAmount = scrollAttemptContext?.requestedScrollAmount {
            reducedAmount = max(1, currentAmount / 2)
        } else {
            reducedAmount = nil
        }

        // A new MainActor task cannot enter until this capture method returns
        // and its defer has cleared isCapturing, avoiding recursive re-entry.
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !request.isCancelled, !self.isCapturing else { return }
            switch action {
            case .retryWithReducedStep:
                self.pendingScrollAmountOverride = reducedAmount
                self.lastMessage = L10n.tr("已减小本次滚动步长，请重新框选")
            case .reselect:
                self.lastMessage = L10n.tr("请重新框选纯滚动正文区域")
            case .switchToManual:
                // This is a recovery strategy for one attempt, not a settings
                // change. Persisting it made every later capture appear broken.
                self.pendingScrollAutomaticOverride = false
                self.lastMessage = L10n.tr("已切换为手动滚动，请重新框选")
            case .savePartial(_), .cancel:
                return
            }
            await self.captureScrolling()
        }
    }

    private static func framesApproximatelyEqual(
        _ lhs: CGRect,
        _ rhs: CGRect,
        tolerance: CGFloat = 4
    ) -> Bool {
        return abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }

}

private extension Int {
    func nonZeroOr(_ fallback: Int) -> Int { self == 0 ? fallback : self }
}

private extension Double {
    func nonZeroOr(_ fallback: Double) -> Double { self == 0 ? fallback : self }
}
