import AppKit
import CoreGraphics
import Foundation
import OSLog

/// One monotonic, privacy-safe trace shared by the Carbon callback, capture
/// coordinator and the first overlay frame. The UUID is the only correlation
/// value written to unified logging; no window title or captured content is
/// recorded.
final class ScreenshotCaptureDiagnosticSession: @unchecked Sendable {
    let id: UUID
    let source: String
    let action: String
    let startedAtNanoseconds: UInt64

    private let lock = NSLock()
    private var didRecordFirstFrame = false

    init(
        id: UUID = UUID(),
        source: String,
        action: String,
        startedAtNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        self.id = id
        self.source = source
        self.action = action
        self.startedAtNanoseconds = startedAtNanoseconds
    }

    func elapsedMilliseconds(
        at nowNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> Double {
        guard nowNanoseconds >= startedAtNanoseconds else { return 0 }
        return Double(nowNanoseconds - startedAtNanoseconds) / 1_000_000
    }

    /// Multi-display overlays may draw concurrently in the same display
    /// cycle. Only the first completed draw represents user-perceived latency.
    func claimFirstFrame() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didRecordFirstFrame else { return false }
        didRecordFirstFrame = true
        return true
    }
}

enum ScreenshotCaptureDiagnostics {
    @TaskLocal static var currentSession: ScreenshotCaptureDiagnosticSession?

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.shawnshoper.peek",
        category: "ScreenshotLatency"
    )

    static func makeUISession(action: String) -> ScreenshotCaptureDiagnosticSession {
        ScreenshotCaptureDiagnosticSession(source: "ui", action: action)
    }

    nonisolated static func nowNanoseconds() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    nonisolated static func milliseconds(
        from startNanoseconds: UInt64,
        to endNanoseconds: UInt64
    ) -> Double {
        guard endNanoseconds >= startNanoseconds else { return 0 }
        return Double(endNanoseconds - startNanoseconds) / 1_000_000
    }

    nonisolated static func carbonEventAgeMilliseconds(
        eventTime: TimeInterval,
        systemUptime: TimeInterval
    ) -> Double {
        guard eventTime.isFinite, systemUptime.isFinite, systemUptime >= eventTime else {
            return 0
        }
        return (systemUptime - eventTime) * 1_000
    }

    nonisolated static func recordCarbonCallback(
        sessionID: UUID,
        eventID: UInt32,
        eventAgeMilliseconds: Double
    ) {
        let age = formattedMilliseconds(eventAgeMilliseconds)
        logger.notice(
            "session=\(sessionID.uuidString, privacy: .public) stage=carbon_callback event_id=\(eventID) event_age_ms=\(age, privacy: .public)"
        )
    }

    nonisolated static func record(
        _ stage: String,
        session: ScreenshotCaptureDiagnosticSession,
        phaseStartedAtNanoseconds: UInt64? = nil,
        detail: String = ""
    ) {
        let now = nowNanoseconds()
        let total = formattedMilliseconds(session.elapsedMilliseconds(at: now))
        let phase = phaseStartedAtNanoseconds.map {
            formattedMilliseconds(milliseconds(from: $0, to: now))
        } ?? "-"
        logger.notice(
            "session=\(session.id.uuidString, privacy: .public) source=\(session.source, privacy: .public) action=\(session.action, privacy: .public) stage=\(stage, privacy: .public) total_ms=\(total, privacy: .public) phase_ms=\(phase, privacy: .public) detail=\(detail, privacy: .public)"
        )
    }

    private nonisolated static func formattedMilliseconds(_ value: Double) -> String {
        String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

/// Cancellation belongs to one capture request, including the preparation
/// work that happens before an overlay session exists. A fresh token is used
/// for every request so a delayed cancellation can never close the next one.
@MainActor
final class ScreenshotCaptureRequestToken {
    let id: UUID
    private(set) var isCancelled = false

    init(id: UUID = UUID()) {
        self.id = id
    }

    func cancel() {
        isCancelled = true
    }

    func checkCancellation() throws {
        try Task.checkCancellation()
        if isCancelled {
            throw CancellationError()
        }
    }
}

enum ScreenshotCapturePresentationDelay {
    /// A Carbon hotkey is delivered only after the key event has completed;
    /// there is no menu or transient button state to wait for.
    static let hotKeyNanoseconds: UInt64 = 0

    /// UI buttons may still be dismissing a menu when capture begins. Keep the
    /// existing delay on those paths so the menu is not frozen into the image.
    static let uiDismissalNanoseconds: UInt64 = 160_000_000
}

/// Native multi-display region capture entry point.
///
/// Keep one coordinator alive for the lifetime of `ScreenshotService` and call
/// `captureRegion()`. The method returns `nil` when the user presses Escape.
@MainActor
final class ScreenshotCaptureCoordinator {
    private enum Presentation {
        case selectionOnly
        case inlineEditor(onAction: ((ScreenshotEditorAction) -> Void)?)

        var diagnosticActionName: String {
            switch self {
            case .selectionOnly: return "selection"
            case .inlineEditor: return "region"
            }
        }
    }

    private struct ActiveSession {
        let id: UUID
        let desktop: ScreenshotFrozenDesktop
        let model: ScreenshotSelectionModel
        let panels: [ScreenshotOverlayPanel]
        let continuation: CheckedContinuation<ScreenshotCaptureResult?, Error>
        var watchdog: Task<Void, Never>?
        var inlineEditorStarted: Bool
        var inlineEditorSessionID: UUID?
    }

    private static let sessionTimeoutNanoseconds: UInt64 = 60_000_000_000

    private var activeSession: ActiveSession?
    private var activeRequestToken: ScreenshotCaptureRequestToken?
    private let inlineEditorController = ScreenshotEditorController()
    private let captureDesktop: @MainActor @Sendable () async throws -> ScreenshotFrozenDesktop
    private let hasScreenRecordingPermission: @MainActor @Sendable () -> Bool
    private let requestScreenRecordingPermission: @MainActor @Sendable () -> Bool

    init(
        captureDesktop: @escaping @MainActor @Sendable () async throws -> ScreenshotFrozenDesktop = {
            try await ScreenshotFrozenDesktop.capture()
        },
        hasScreenRecordingPermission: @escaping @MainActor @Sendable () -> Bool = {
            CGPreflightScreenCaptureAccess()
        },
        requestScreenRecordingPermission: @escaping @MainActor @Sendable () -> Bool = {
            CGRequestScreenCaptureAccess()
        }
    ) {
        self.captureDesktop = captureDesktop
        self.hasScreenRecordingPermission = hasScreenRecordingPermission
        self.requestScreenRecordingPermission = requestScreenRecordingPermission
    }

    var isCapturing: Bool {
        activeRequestToken != nil || activeSession != nil
    }

    var hasPresentedOverlay: Bool {
        activeSession != nil
    }

    func captureRegion(
        requestPermissionIfNeeded: Bool = true,
        presentationDelayNanoseconds: UInt64 = ScreenshotCapturePresentationDelay
            .uiDismissalNanoseconds,
        initialSelectionRect: CGRect? = nil,
        initialSelectionHint: String? = nil,
        automaticHoverWindowRect: CGRect? = nil,
        automaticHoverSelectionRects: [CGRect] = [],
        requestToken: ScreenshotCaptureRequestToken? = nil
    ) async throws -> ScreenshotCaptureResult? {
        try await captureRegion(
            requestPermissionIfNeeded: requestPermissionIfNeeded,
            presentationDelayNanoseconds: presentationDelayNanoseconds,
            initialSelectionRect: initialSelectionRect,
            initialSelectionHint: initialSelectionHint,
            automaticHoverWindowRect: automaticHoverWindowRect,
            automaticHoverSelectionRects: automaticHoverSelectionRects,
            requestToken: requestToken,
            presentation: .selectionOnly
        )
    }

    /// Region capture with a frozen-desktop inline editor. The desktop is read
    /// exactly once before overlays appear; selection and editing always use
    /// that immutable source.
    func captureRegionWithInlineEditor(
        requestPermissionIfNeeded: Bool = true,
        presentationDelayNanoseconds: UInt64 = ScreenshotCapturePresentationDelay
            .uiDismissalNanoseconds,
        initialSelectionRect: CGRect? = nil,
        initialSelectionHint: String? = nil,
        requestToken: ScreenshotCaptureRequestToken? = nil,
        onAction: ((ScreenshotEditorAction) -> Void)? = nil
    ) async throws -> ScreenshotCaptureResult? {
        try await captureRegion(
            requestPermissionIfNeeded: requestPermissionIfNeeded,
            presentationDelayNanoseconds: presentationDelayNanoseconds,
            initialSelectionRect: initialSelectionRect,
            initialSelectionHint: initialSelectionHint,
            automaticHoverWindowRect: nil,
            automaticHoverSelectionRects: [],
            requestToken: requestToken,
            presentation: .inlineEditor(onAction: onAction)
        )
    }

    private func captureRegion(
        requestPermissionIfNeeded: Bool,
        presentationDelayNanoseconds: UInt64,
        initialSelectionRect: CGRect?,
        initialSelectionHint: String?,
        automaticHoverWindowRect: CGRect?,
        automaticHoverSelectionRects: [CGRect],
        requestToken suppliedRequestToken: ScreenshotCaptureRequestToken?,
        presentation: Presentation
    ) async throws -> ScreenshotCaptureResult? {
        let diagnosticSession = ScreenshotCaptureDiagnostics.currentSession
            ?? ScreenshotCaptureDiagnostics.makeUISession(
                action: presentation.diagnosticActionName
            )
        ScreenshotCaptureDiagnostics.record(
            "capture_requested",
            session: diagnosticSession
        )

        guard activeSession == nil, activeRequestToken == nil else {
            ScreenshotCaptureDiagnostics.record(
                "capture_rejected_already_running",
                session: diagnosticSession
            )
            throw ScreenshotCaptureError.alreadyRunning
        }

        let requestToken = suppliedRequestToken ?? ScreenshotCaptureRequestToken()
        activeRequestToken = requestToken
        defer {
            if activeRequestToken === requestToken {
                activeRequestToken = nil
            }
        }

        do {
            try requestToken.checkCancellation()

            let permissionStartedAt = ScreenshotCaptureDiagnostics.nowNanoseconds()
            let hasPermission = hasScreenRecordingPermission()
            ScreenshotCaptureDiagnostics.record(
                hasPermission ? "permission_granted" : "permission_missing",
                session: diagnosticSession,
                phaseStartedAtNanoseconds: permissionStartedAt
            )
            try requestToken.checkCancellation()
            guard hasPermission else {
                if requestPermissionIfNeeded {
                    let permissionWasGranted = requestScreenRecordingPermission()
                    try requestToken.checkCancellation()
                    if permissionWasGranted {
                        // TCC permission changes are not reliable for a process that
                        // is already running. Never continue into desktop capture
                        // with stale authorization state.
                        throw ScreenshotCaptureError.screenRecordingPermissionRequiresRestart
                    }
                }
                throw ScreenshotCaptureError.screenRecordingPermissionDenied
            }

            if presentationDelayNanoseconds > 0 {
                let delayStartedAt = ScreenshotCaptureDiagnostics.nowNanoseconds()
                try await Task.sleep(nanoseconds: presentationDelayNanoseconds)
                try requestToken.checkCancellation()
                ScreenshotCaptureDiagnostics.record(
                    "presentation_delay_finished",
                    session: diagnosticSession,
                    phaseStartedAtNanoseconds: delayStartedAt
                )
            }

            let freezeStartedAt = ScreenshotCaptureDiagnostics.nowNanoseconds()
            ScreenshotCaptureDiagnostics.record(
                "desktop_freeze_started",
                session: diagnosticSession
            )
            let desktop: ScreenshotFrozenDesktop
            do {
                desktop = try await captureDesktop()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                ScreenshotCaptureDiagnostics.record(
                    "desktop_freeze_failed",
                    session: diagnosticSession,
                    phaseStartedAtNanoseconds: freezeStartedAt,
                    detail: String(describing: type(of: error))
                )
                throw error
            }
            try requestToken.checkCancellation()
            ScreenshotCaptureDiagnostics.record(
                "desktop_freeze_finished",
                session: diagnosticSession,
                phaseStartedAtNanoseconds: freezeStartedAt,
                detail: "displays=\(desktop.displays.count)"
            )
            let sessionID = requestToken.id
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    do {
                        try requestToken.checkCancellation()
                    } catch {
                        continuation.resume(returning: nil)
                        return
                    }
                    beginSession(
                        id: sessionID,
                        desktop: desktop,
                        initialSelectionRect: initialSelectionRect,
                        initialSelectionHint: initialSelectionHint,
                        automaticHoverWindowRect: automaticHoverWindowRect,
                        automaticHoverSelectionRects: automaticHoverSelectionRects,
                        presentation: presentation,
                        diagnosticSession: diagnosticSession,
                        continuation: continuation
                    )
                    // The cancellation handler may run before `beginSession` has
                    // installed `activeSession`. Re-check after installation so a
                    // pre-cancelled task cannot leave the overlay alive until the
                    // watchdog fires.
                    if Task.isCancelled || requestToken.isCancelled {
                        complete(sessionID: sessionID, with: .success(nil))
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    requestToken.cancel()
                    self?.complete(
                        sessionID: sessionID,
                        with: .success(nil)
                    )
                }
            }
        } catch is CancellationError {
            ScreenshotCaptureDiagnostics.record(
                "capture_cancelled_before_overlay",
                session: diagnosticSession
            )
            return nil
        }
    }

    func cancelCapture() {
        activeRequestToken?.cancel()
        guard let sessionID = activeSession?.id else {
            // ScreenCaptureKit preparation is outside our control and may not
            // return promptly. Release coordinator ownership immediately so a
            // cancelled preparation can never block every later screenshot.
            activeRequestToken = nil
            return
        }
        complete(sessionID: sessionID, with: .success(nil))
    }

    private func beginSession(
        id sessionID: UUID,
        desktop: ScreenshotFrozenDesktop,
        initialSelectionRect: CGRect?,
        initialSelectionHint: String?,
        automaticHoverWindowRect: CGRect?,
        automaticHoverSelectionRects: [CGRect],
        presentation: Presentation,
        diagnosticSession: ScreenshotCaptureDiagnosticSession,
        continuation: CheckedContinuation<ScreenshotCaptureResult?, Error>
    ) {
        let overlayPreparationStartedAt = ScreenshotCaptureDiagnostics.nowNanoseconds()
        let model = ScreenshotSelectionModel(
            desktop: desktop.selectionGeometry(),
            initialSelectionRect: initialSelectionRect,
            initialSelectionHint: initialSelectionHint,
            automaticHoverWindowRect: automaticHoverWindowRect,
            automaticHoverSelectionRects: automaticHoverSelectionRects
        )
        var views: [ScreenshotSelectionOverlayView] = []
        let panels: [ScreenshotOverlayPanel] = desktop.displays.map { display in
            let panel = ScreenshotOverlayPanel(
                contentRect: display.screenFrame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            let view = ScreenshotSelectionOverlayView(
                display: display,
                model: model,
                diagnosticSession: diagnosticSession
            )
            views.append(view)

            panel.contentView = view
            panel.setFrame(display.screenFrame, display: false)
            panel.level = .screenSaver
            panel.backgroundColor = .clear
            panel.isOpaque = true
            panel.ignoresMouseEvents = false
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.acceptsMouseMovedEvents = true
            panel.collectionBehavior = [
                .canJoinAllSpaces,
                .fullScreenAuxiliary,
                .stationary,
                .ignoresCycle
            ]
            return panel
        }

        model.onChange = { [views] in
            views.forEach { $0.needsDisplay = true }
        }
        model.onCursorChange = { [views] in
            views.forEach { view in
                view.window?.invalidateCursorRects(for: view)
            }
        }
        model.onCancel = { [weak self] in
            self?.complete(sessionID: sessionID, with: .success(nil))
        }
        switch presentation {
        case .selectionOnly:
            model.onFinish = { [weak self] selection in
                self?.finishSelectionOnly(
                    sessionID: sessionID,
                    desktop: desktop,
                    model: model,
                    selection: selection
                )
            }
        case let .inlineEditor(onAction):
            let beginInlineEditing: (CGRect) -> Void = { [weak self] selection in
                self?.beginInlineEditing(
                    sessionID: sessionID,
                    desktop: desktop,
                    model: model,
                    selection: selection,
                    onAction: onAction
                )
            }
            model.onSelectionPreview = { [weak self] selection in
                guard let self,
                      let editorID = self.activeSession?.inlineEditorSessionID else {
                    return
                }
                self.inlineEditorController.previewInlineSelection(
                    sessionID: editorID,
                    rect: selection
                )
            }
            let acceptSelection: (CGRect) -> Void = { [weak self] selection in
                guard let self else { return }
                if let editorID = self.activeSession?.inlineEditorSessionID {
                    self.inlineEditorController.commitInlineSelection(
                        sessionID: editorID,
                        rect: selection
                    )
                } else {
                    beginInlineEditing(selection)
                }
            }
            model.onSelectionReady = acceptSelection
            model.onFinish = acceptSelection
        }

        activeSession = ActiveSession(
            id: sessionID,
            desktop: desktop,
            model: model,
            panels: panels,
            continuation: continuation,
            watchdog: nil,
            inlineEditorStarted: false,
            inlineEditorSessionID: nil
        )

        ScreenshotCaptureDiagnostics.record(
            "overlay_prepared",
            session: diagnosticSession,
            phaseStartedAtNanoseconds: overlayPreparationStartedAt,
            detail: "panels=\(panels.count)"
        )
        let orderFrontStartedAt = ScreenshotCaptureDiagnostics.nowNanoseconds()
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
        panels.forEach { $0.orderFrontRegardless() }
        if let firstPanel = panels.first,
           let firstView = firstPanel.contentView {
            firstPanel.makeKeyAndOrderFront(nil)
            firstPanel.makeFirstResponder(firstView)
        }
        ScreenshotCaptureDiagnostics.record(
            "overlay_ordered_front",
            session: diagnosticSession,
            phaseStartedAtNanoseconds: orderFrontStartedAt,
            detail: "panels=\(panels.count)"
        )

        guard !panels.isEmpty,
              panels.allSatisfy({ $0.contentView != nil && $0.isVisible }) else {
            complete(
                sessionID: sessionID,
                with: .failure(ScreenshotCaptureError.overlayPresentationFailed)
            )
            return
        }

        let watchdog = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.sessionTimeoutNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.complete(
                sessionID: sessionID,
                with: .failure(ScreenshotCaptureError.selectionTimedOut)
            )
        }
        guard activeSession?.id == sessionID else {
            watchdog.cancel()
            return
        }
        activeSession?.watchdog = watchdog
    }

    private func finishSelectionOnly(
        sessionID: UUID,
        desktop: ScreenshotFrozenDesktop,
        model: ScreenshotSelectionModel,
        selection: CGRect
    ) {
        do {
            let image = try desktop.render(selection: selection)
            complete(
                sessionID: sessionID,
                with: .success(
                    ScreenshotCaptureResult(
                        image: image,
                        selectionRect: selection,
                        capturedAt: Date(),
                        wasInitialSelectionModified: model.didModifyInitialSelection
                    )
                )
            )
        } catch {
            NSSound.beep()
            complete(sessionID: sessionID, with: .failure(error))
        }
    }

    private func beginInlineEditing(
        sessionID: UUID,
        desktop: ScreenshotFrozenDesktop,
        model: ScreenshotSelectionModel,
        selection: CGRect,
        onAction: ((ScreenshotEditorAction) -> Void)?
    ) {
        guard var session = activeSession,
              session.id == sessionID,
              !session.inlineEditorStarted else {
            return
        }

        do {
            let image = try desktop.render(selection: selection)
            session.inlineEditorStarted = true
            session.watchdog?.cancel()
            session.watchdog = nil
            activeSession = session
            model.beginEditing()

            let owningDisplay = desktop.displays.max { lhs, rhs in
                let leftIntersection = lhs.screenFrame.intersection(selection)
                let rightIntersection = rhs.screenFrame.intersection(selection)
                let leftArea = leftIntersection.isNull
                    ? 0
                    : leftIntersection.width * leftIntersection.height
                let rightArea = rightIntersection.isNull
                    ? 0
                    : rightIntersection.width * rightIntersection.height
                return leftArea < rightArea
            }
            let screenFrame = owningDisplay?.screenFrame ?? desktop.desktopBounds
            let editorID = inlineEditorController.editInline(
                image: image,
                selectionRect: selection,
                screenFrame: screenFrame,
                previewDisplay: owningDisplay,
                renderSelection: { rect in
                    try desktop.render(selection: rect)
                },
                onSelectionPreviewChanged: { rect in
                    model.previewSelectionDuringEditing(rect)
                },
                onSelectionChanged: { rect in
                    model.updateSelectionDuringEditing(rect)
                },
                onSelectionInteractionChanged: { enabled in
                    model.setSelectionInteractionEnabled(enabled)
                },
                onAction: onAction
            ) { [weak self] editedImage, finalSelectionRect in
                guard let self,
                      self.activeSession?.id == sessionID else {
                    return
                }
                guard let editedImage else {
                    self.complete(sessionID: sessionID, with: .success(nil))
                    return
                }
                self.complete(
                    sessionID: sessionID,
                    with: .success(
                        ScreenshotCaptureResult(
                            image: editedImage,
                            selectionRect: finalSelectionRect,
                            capturedAt: Date(),
                            wasInitialSelectionModified: model.didModifyInitialSelection
                        )
                    )
                )
            }
            guard activeSession?.id == sessionID else { return }
            activeSession?.inlineEditorSessionID = editorID
        } catch {
            NSSound.beep()
            complete(sessionID: sessionID, with: .failure(error))
        }
    }

    private func complete(
        sessionID: UUID,
        with result: Result<ScreenshotCaptureResult?, Error>
    ) {
        guard let session = activeSession, session.id == sessionID else { return }
        activeSession = nil

        session.watchdog?.cancel()
        session.model.onChange = nil
        session.model.onCursorChange = nil
        session.model.onCancel = nil
        session.model.onSelectionPreview = nil
        session.model.onSelectionReady = nil
        session.model.onFinish = nil
        inlineEditorController.closeAll()
        session.panels.forEach {
            $0.orderOut(nil)
            $0.close()
        }
        session.continuation.resume(with: result)
    }
}
