import AppKit
import CoreGraphics
import Foundation

enum ScreenshotCaptureError: LocalizedError {
    case alreadyRunning
    case screenRecordingPermissionDenied
    case screenRecordingPermissionRequiresRestart
    case noAvailableDisplays
    case displayCaptureFailed(CGDirectDisplayID)
    case overlayPresentationFailed
    case selectionTimedOut
    case emptySelection
    case imageRenderingFailed

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return L10n.tr("已有截图任务正在进行")
        case .screenRecordingPermissionDenied:
            return L10n.tr("未获得屏幕录制权限，请在系统设置中授权后重试")
        case .screenRecordingPermissionRequiresRestart:
            return L10n.tr("屏幕录制权限已授权，请完全退出并重新启动 PEEK 后再截图")
        case .noAvailableDisplays:
            return L10n.tr("没有检测到可截图的显示器")
        case let .displayCaptureFailed(displayID):
            return L10n.tr("无法读取显示器画面（Display %u）", displayID)
        case .overlayPresentationFailed:
            return L10n.tr("截图选区界面未能显示，请重试")
        case .selectionTimedOut:
            return L10n.tr("截图选区已超时（60 秒），请重新截图")
        case .emptySelection:
            return L10n.tr("截图选区为空")
        case .imageRenderingFailed:
            return L10n.tr("无法合成截图图像")
        }
    }
}

/// A completed region capture. `selectionRect` uses the global AppKit screen
/// coordinate space (origin at the lower-left of the primary display).
struct ScreenshotCaptureResult {
    let image: NSImage
    let selectionRect: CGRect
    let capturedAt: Date
    /// `true` when the user moved, resized, nudged or replaced a supplied
    /// initial selection. Callers must then discard any semantic identity
    /// previously attached to that automatic selection.
    let wasInitialSelectionModified: Bool
}

struct ScreenshotWindowCandidate: Equatable, Sendable {
    let windowID: CGWindowID
    let ownerPID: pid_t
    let frame: CGRect
    let ownerName: String
    let title: String?
}

/// Window candidates preserve the front-to-back order returned by
/// `CGWindowListCopyWindowInfo`, so the first candidate owned by a process is
/// that process's frontmost capturable window.
func frontmostScreenshotWindowCandidate(
    ownerPID: pid_t,
    in candidates: [ScreenshotWindowCandidate]
) -> ScreenshotWindowCandidate? {
    candidates.first { $0.ownerPID == ownerPID }
}

struct ScreenshotFrozenDisplay: @unchecked Sendable {
    let displayID: CGDirectDisplayID
    let screenFrame: CGRect
    let image: CGImage

    var scaleX: CGFloat {
        CGFloat(image.width) / max(screenFrame.width, 1)
    }

    var scaleY: CGFloat {
        CGFloat(image.height) / max(screenFrame.height, 1)
    }
}

/// Geometry used by the selection model. Production sessions derive this from
/// the same immutable desktop snapshot that is displayed by the overlays.
/// Keeping this value-only type also makes selection gestures testable without
/// requesting Screen Recording permission.
struct ScreenshotDisplayGeometry: Equatable, Sendable {
    let displayID: CGDirectDisplayID
    let screenFrame: CGRect
}

/// Value-only desktop geometry shared by selection gestures and tests.
final class ScreenshotDesktopGeometry: @unchecked Sendable {
    let displays: [ScreenshotDisplayGeometry]
    let desktopBounds: CGRect
    let windowCandidates: [ScreenshotWindowCandidate]
    let appKitReferenceTop: CGFloat

    init(
        displays: [ScreenshotDisplayGeometry],
        desktopBounds: CGRect,
        windowCandidates: [ScreenshotWindowCandidate],
        appKitReferenceTop: CGFloat
    ) {
        self.displays = displays
        self.desktopBounds = desktopBounds
        self.windowCandidates = windowCandidates
        self.appKitReferenceTop = appKitReferenceTop
    }

    func windowCandidate(at point: CGPoint) -> ScreenshotWindowCandidate? {
        windowCandidates.first { $0.frame.contains(point) }
    }

    func frontmostWindowCandidate(ownerPID: pid_t) -> ScreenshotWindowCandidate? {
        frontmostScreenshotWindowCandidate(ownerPID: ownerPID, in: windowCandidates)
    }

}

/// Immutable desktop snapshot used by every overlay window in one capture
/// session. Screens are captured before any overlay is displayed.
/// The snapshot is immutable after construction. `CGImage` instances are
/// immutable Core Graphics objects, so it is safe to move a completed frozen
/// desktop from the capture worker back to the main actor.
final class ScreenshotFrozenDesktop: @unchecked Sendable {
    let displays: [ScreenshotFrozenDisplay]
    let desktopBounds: CGRect
    let windowCandidates: [ScreenshotWindowCandidate]

    private let appKitReferenceTop: CGFloat

    private init(
        displays: [ScreenshotFrozenDisplay],
        desktopBounds: CGRect,
        windowCandidates: [ScreenshotWindowCandidate],
        appKitReferenceTop: CGFloat
    ) {
        self.displays = displays
        self.desktopBounds = desktopBounds
        self.windowCandidates = windowCandidates
        self.appKitReferenceTop = appKitReferenceTop
    }

    private struct DisplayCaptureDescriptor: Sendable {
        let index: Int
        let displayID: CGDirectDisplayID
        let screenFrame: CGRect
    }

    private struct CapturePlan: Sendable {
        let displays: [DisplayCaptureDescriptor]
        let desktopBounds: CGRect
        let appKitReferenceTop: CGFloat
    }

    /// AppKit display discovery stays on the main actor, while the expensive
    /// pixel reads and WindowServer snapshot run on user-initiated workers.
    /// This keeps the cursor and the currently focused app responsive while
    /// PEEK freezes a Retina or multi-display desktop.
    @MainActor
    static func capture() async throws -> ScreenshotFrozenDesktop {
        let plan = try makeCapturePlan()
        return try await Task.detached(priority: .userInitiated) {
            try await capture(using: plan)
        }.value
    }

    @MainActor
    private static func makeCapturePlan() throws -> CapturePlan {
        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            throw ScreenshotCaptureError.noAvailableDisplays
        }

        var descriptors: [DisplayCaptureDescriptor] = []
        descriptors.reserveCapacity(screens.count)

        for (index, screen) in screens.enumerated() {
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else {
                continue
            }

            descriptors.append(
                DisplayCaptureDescriptor(
                    index: index,
                    displayID: CGDirectDisplayID(number.uint32Value),
                    screenFrame: screen.frame
                )
            )
        }

        guard !descriptors.isEmpty else {
            throw ScreenshotCaptureError.noAvailableDisplays
        }

        let bounds = descriptors
            .map(\.screenFrame)
            .reduce(CGRect.null) { $0.union($1) }
        let referenceTop = screens.first?.frame.maxY ?? bounds.maxY

        return CapturePlan(
            displays: descriptors,
            desktopBounds: bounds,
            appKitReferenceTop: referenceTop
        )
    }

    private static func capture(
        using plan: CapturePlan
    ) async throws -> ScreenshotFrozenDesktop {
        let screenCapturer = SystemScreenImageCapturer()
        let frozenDisplays = try await withThrowingTaskGroup(
            of: (Int, ScreenshotFrozenDisplay).self,
            returning: [ScreenshotFrozenDisplay].self
        ) { group in
            for descriptor in plan.displays {
                group.addTask(priority: .userInitiated) {
                    let image: CGImage
                    do {
                        image = try await screenCapturer.captureDisplay(
                            displayID: descriptor.displayID,
                            logicalFrame: descriptor.screenFrame
                        )
                    } catch {
                        throw ScreenshotCaptureError.displayCaptureFailed(
                            descriptor.displayID
                        )
                    }
                    return (
                        descriptor.index,
                        ScreenshotFrozenDisplay(
                            displayID: descriptor.displayID,
                            screenFrame: descriptor.screenFrame,
                            image: image
                        )
                    )
                }
            }

            var captures: [(Int, ScreenshotFrozenDisplay)] = []
            captures.reserveCapacity(plan.displays.count)
            for try await capture in group {
                captures.append(capture)
            }
            return captures
                .sorted { $0.0 < $1.0 }
                .map(\.1)
        }

        return ScreenshotFrozenDesktop(
            displays: frozenDisplays,
            desktopBounds: plan.desktopBounds,
            windowCandidates: screenshotWindowCandidates(
                desktopBounds: plan.desktopBounds,
                appKitReferenceTop: plan.appKitReferenceTop
            ),
            appKitReferenceTop: plan.appKitReferenceTop
        )
    }

    func windowCandidate(at point: CGPoint) -> ScreenshotWindowCandidate? {
        // CGWindowListCopyWindowInfo is front-to-back, so the first matching
        // layer-zero window is the visible candidate under the pointer.
        windowCandidates.first { $0.frame.contains(point) }
    }

    func frontmostWindowCandidate(ownerPID: pid_t) -> ScreenshotWindowCandidate? {
        frontmostScreenshotWindowCandidate(
            ownerPID: ownerPID,
            in: windowCandidates
        )
    }

    func selectionGeometry() -> ScreenshotDesktopGeometry {
        ScreenshotDesktopGeometry(
            displays: displays.map {
                ScreenshotDisplayGeometry(
                    displayID: $0.displayID,
                    screenFrame: $0.screenFrame
                )
            },
            desktopBounds: desktopBounds,
            windowCandidates: windowCandidates,
            appKitReferenceTop: appKitReferenceTop
        )
    }

    func render(selection rawSelection: CGRect) throws -> NSImage {
        let selection = rawSelection.standardized.intersection(desktopBounds)
        guard selection.width >= 1, selection.height >= 1 else {
            throw ScreenshotCaptureError.emptySelection
        }

        let intersectingDisplays = displays.filter {
            !$0.screenFrame.intersection(selection).isNull
        }
        guard !intersectingDisplays.isEmpty else {
            throw ScreenshotCaptureError.emptySelection
        }

        let outputScale = intersectingDisplays
            .map { max($0.scaleX, $0.scaleY) }
            .max() ?? 1
        let pixelsWide = max(1, Int(ceil(selection.width * outputScale)))
        let pixelsHigh = max(1, Int(ceil(selection.height * outputScale)))

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw ScreenshotCaptureError.imageRenderingFailed
        }
        bitmap.size = selection.size

        guard let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw ScreenshotCaptureError.imageRenderingFailed
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        graphicsContext.imageInterpolation = .none
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: selection.size).fill()

        for display in intersectingDisplays {
            let intersection = display.screenFrame.intersection(selection)
            guard !intersection.isNull else { continue }

            let sourceRect = pixelCropRect(
                for: intersection,
                in: display
            )
            guard let cropped = display.image.cropping(to: sourceRect) else {
                continue
            }

            let destination = CGRect(
                x: intersection.minX - selection.minX,
                y: intersection.minY - selection.minY,
                width: intersection.width,
                height: intersection.height
            )
            NSImage(cgImage: cropped, size: intersection.size).draw(
                in: destination,
                from: .zero,
                operation: .copy,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.none]
            )
        }

        graphicsContext.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        let result = NSImage(size: selection.size)
        result.addRepresentation(bitmap)
        return result
    }

    private func pixelCropRect(
        for appKitRect: CGRect,
        in display: ScreenshotFrozenDisplay
    ) -> CGRect {
        let localX = appKitRect.minX - display.screenFrame.minX
        let localTop = display.screenFrame.maxY - appKitRect.maxY

        var rect = CGRect(
            x: floor(localX * display.scaleX),
            y: floor(localTop * display.scaleY),
            width: ceil(appKitRect.width * display.scaleX),
            height: ceil(appKitRect.height * display.scaleY)
        )
        rect = rect.intersection(
            CGRect(x: 0, y: 0, width: display.image.width, height: display.image.height)
        )
        return rect.integral
    }

}

private func screenshotWindowCandidates(
    desktopBounds: CGRect,
    appKitReferenceTop: CGFloat
) -> [ScreenshotWindowCandidate] {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let rawWindows = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
        as? [[String: Any]] else {
        return []
    }

    let currentPID = ProcessInfo.processInfo.processIdentifier
    return rawWindows.compactMap { info in
        guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
              let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
              ownerPID != currentPID,
              (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
              let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
              let quartzFrame = CGRect(
                  dictionaryRepresentation: boundsDictionary as CFDictionary
              ),
              quartzFrame.width >= 24,
              quartzFrame.height >= 24 else {
            return nil
        }

        let appKitFrame = CGRect(
            x: quartzFrame.minX,
            y: appKitReferenceTop - quartzFrame.maxY,
            width: quartzFrame.width,
            height: quartzFrame.height
        ).intersection(desktopBounds)
        guard !appKitFrame.isNull, appKitFrame.width >= 24, appKitFrame.height >= 24 else {
            return nil
        }

        return ScreenshotWindowCandidate(
            windowID: CGWindowID(
                (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0
            ),
            ownerPID: ownerPID,
            frame: appKitFrame,
            ownerName: info[kCGWindowOwnerName as String] as? String ?? "",
            title: info[kCGWindowName as String] as? String
        )
    }
}
