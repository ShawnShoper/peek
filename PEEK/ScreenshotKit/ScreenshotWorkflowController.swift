import AppKit
import Foundation

struct ScreenshotWorkflowOutput {
    let capture: ScreenshotCaptureResult
    let editedImage: NSImage
}

enum ScreenshotWorkflowStage {
    case selection
    case editing
}

enum ScreenshotWorkflowEvent {
    case rawCaptured(ScreenshotCaptureResult)
    case pinRequested(NSImage)
    case ocrRequested(NSImage)
    case qrCodeRequested(NSImage)
    case scrollCaptureRequested(NSImage)
    case copied(NSImage)
    case saved(NSImage, URL)
    case completed(ScreenshotWorkflowOutput)
    case cancelled(ScreenshotWorkflowStage)
}

/// Convenience facade for ScreenshotService. It emits the untouched capture
/// immediately, then returns the composited editor output when the user taps
/// Done. Pin/OCR/scroll remain decoupled actions for their dedicated services.
@MainActor
final class ScreenshotWorkflowController {
    let captureCoordinator: ScreenshotCaptureCoordinator
    let editorController: ScreenshotEditorController

    init() {
        captureCoordinator = ScreenshotCaptureCoordinator()
        editorController = ScreenshotEditorController()
    }

    init(
        captureCoordinator: ScreenshotCaptureCoordinator,
        editorController: ScreenshotEditorController
    ) {
        self.captureCoordinator = captureCoordinator
        self.editorController = editorController
    }

    func run(
        onEvent: ((ScreenshotWorkflowEvent) -> Void)? = nil
    ) async throws -> ScreenshotWorkflowOutput? {
        guard let capture = try await captureCoordinator.captureRegion() else {
            onEvent?(.cancelled(.selection))
            return nil
        }
        onEvent?(.rawCaptured(capture))

        var handedOffToScrollCapture = false
        let edited = await editorController.edit(image: capture.image) { action in
            switch action {
            case let .pinRequested(image):
                onEvent?(.pinRequested(image))
            case let .ocrRequested(image):
                onEvent?(.ocrRequested(image))
            case let .qrCodeRequested(image):
                onEvent?(.qrCodeRequested(image))
            case let .scrollCaptureRequested(image):
                handedOffToScrollCapture = true
                onEvent?(.scrollCaptureRequested(image))
            case let .scrollCaptureRequestedInSelection(image, _):
                handedOffToScrollCapture = true
                onEvent?(.scrollCaptureRequested(image))
            case let .copied(image):
                onEvent?(.copied(image))
            case let .saved(image, url):
                onEvent?(.saved(image, url))
            }
        }
        guard let edited else {
            if !handedOffToScrollCapture {
                onEvent?(.cancelled(.editing))
            }
            return nil
        }

        let output = ScreenshotWorkflowOutput(capture: capture, editedImage: edited)
        onEvent?(.completed(output))
        return output
    }

    func run(
        onEvent: ((ScreenshotWorkflowEvent) -> Void)? = nil,
        completion: @escaping (Result<ScreenshotWorkflowOutput?, Error>) -> Void
    ) {
        Task { @MainActor in
            do {
                completion(.success(try await run(onEvent: onEvent)))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func cancel() {
        captureCoordinator.cancelCapture()
        editorController.closeAll()
    }
}
