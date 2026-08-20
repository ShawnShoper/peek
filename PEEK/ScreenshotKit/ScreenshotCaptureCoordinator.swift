import AppKit
import CoreGraphics
import Foundation

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
    }

    private struct ActiveSession {
        let id: UUID
        let desktop: ScreenshotFrozenDesktop
        let model: ScreenshotSelectionModel
        let panels: [ScreenshotOverlayPanel]
        let continuation: CheckedContinuation<ScreenshotCaptureResult?, Error>
        var watchdog: Task<Void, Never>?
        var inlineEditorStarted: Bool
    }

    private static let sessionTimeoutNanoseconds: UInt64 = 60_000_000_000

    private var activeSession: ActiveSession?
    private let inlineEditorController = ScreenshotEditorController()

    var isCapturing: Bool {
        activeSession != nil
    }

    func captureRegion(
        requestPermissionIfNeeded: Bool = true,
        presentationDelayNanoseconds: UInt64 = ScreenshotCapturePresentationDelay
            .uiDismissalNanoseconds,
        initialSelectionRect: CGRect? = nil,
        initialSelectionHint: String? = nil,
        automaticHoverWindowRect: CGRect? = nil,
        automaticHoverSelectionRects: [CGRect] = []
    ) async throws -> ScreenshotCaptureResult? {
        try await captureRegion(
            requestPermissionIfNeeded: requestPermissionIfNeeded,
            presentationDelayNanoseconds: presentationDelayNanoseconds,
            initialSelectionRect: initialSelectionRect,
            initialSelectionHint: initialSelectionHint,
            automaticHoverWindowRect: automaticHoverWindowRect,
            automaticHoverSelectionRects: automaticHoverSelectionRects,
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
        onAction: ((ScreenshotEditorAction) -> Void)? = nil
    ) async throws -> ScreenshotCaptureResult? {
        try await captureRegion(
            requestPermissionIfNeeded: requestPermissionIfNeeded,
            presentationDelayNanoseconds: presentationDelayNanoseconds,
            initialSelectionRect: nil,
            initialSelectionHint: nil,
            automaticHoverWindowRect: nil,
            automaticHoverSelectionRects: [],
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
        presentation: Presentation
    ) async throws -> ScreenshotCaptureResult? {
        guard activeSession == nil else {
            throw ScreenshotCaptureError.alreadyRunning
        }

        guard CGPreflightScreenCaptureAccess() else {
            if requestPermissionIfNeeded {
                if CGRequestScreenCaptureAccess() {
                    // TCC permission changes are not reliable for a process that
                    // is already running. Never continue into desktop capture
                    // with stale authorization state.
                    throw ScreenshotCaptureError.screenRecordingPermissionRequiresRestart
                }
            }
            throw ScreenshotCaptureError.screenRecordingPermissionDenied
        }

        if presentationDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: presentationDelayNanoseconds)
        }

        let desktop = try await ScreenshotFrozenDesktop.capture()
        let sessionID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                beginSession(
                    id: sessionID,
                    desktop: desktop,
                    initialSelectionRect: initialSelectionRect,
                    initialSelectionHint: initialSelectionHint,
                    automaticHoverWindowRect: automaticHoverWindowRect,
                    automaticHoverSelectionRects: automaticHoverSelectionRects,
                    presentation: presentation,
                    continuation: continuation
                )
                // The cancellation handler may run before `beginSession` has
                // installed `activeSession`. Re-check after installation so a
                // pre-cancelled task cannot leave the overlay alive until the
                // watchdog fires.
                if Task.isCancelled {
                    complete(sessionID: sessionID, with: .success(nil))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.complete(
                    sessionID: sessionID,
                    with: .success(nil)
                )
            }
        }
    }

    func cancelCapture() {
        guard let sessionID = activeSession?.id else { return }
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
        continuation: CheckedContinuation<ScreenshotCaptureResult?, Error>
    ) {
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
            let view = ScreenshotSelectionOverlayView(display: display, model: model)
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
            model.onSelectionReady = beginInlineEditing
            model.onFinish = beginInlineEditing
        }

        activeSession = ActiveSession(
            id: sessionID,
            desktop: desktop,
            model: model,
            panels: panels,
            continuation: continuation,
            watchdog: nil,
            inlineEditorStarted: false
        )

        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
        panels.forEach { $0.orderFrontRegardless() }
        if let firstPanel = panels.first,
           let firstView = firstPanel.contentView {
            firstPanel.makeKeyAndOrderFront(nil)
            firstPanel.makeFirstResponder(firstView)
        }

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
            inlineEditorController.editInline(
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
        session.model.onCancel = nil
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
