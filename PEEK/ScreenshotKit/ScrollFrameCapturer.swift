import CoreGraphics
import Foundation
import ScreenCaptureKit

protocol ScreenImageCapturing: Sendable {
    func captureDisplay(
        displayID: CGDirectDisplayID,
        logicalFrame: CGRect
    ) async throws -> CGImage
    func capture(rect: CGRect) async throws -> CGImage
}

enum ScreenImageCaptureError: LocalizedError {
    case displayUnavailable(CGDirectDisplayID)
    case rectOutsideSingleDisplay
    case captureReturnedNoImage

    var errorDescription: String? {
        switch self {
        case .displayUnavailable(let displayID):
            return L10n.tr("ScreenCaptureKit 找不到显示器 %u", displayID)
        case .rectOutsideSingleDisplay:
            return L10n.tr("截图区域必须完整位于同一显示器内")
        case .captureReturnedNoImage:
            return L10n.tr("系统截图服务没有返回图像")
        }
    }
}

struct ScreenCapturePixelDimensions: Equatable, Sendable {
    let width: Int
    let height: Int
}

/// Converts ScreenCaptureKit's logical point dimensions into output pixels.
/// `pointPixelScale` belongs to the content filter for the selected display,
/// so Retina, non-Retina, scaled and mixed-display setups are handled without
/// device-specific constants.
func screenCapturePixelDimensions(
    logicalSize: CGSize,
    pointPixelScale: CGFloat
) -> ScreenCapturePixelDimensions {
    let scale = pointPixelScale.isFinite && pointPixelScale > 0
        ? pointPixelScale
        : 1
    return ScreenCapturePixelDimensions(
        width: max(1, Int(ceil(logicalSize.width * scale))),
        height: max(1, Int(ceil(logicalSize.height * scale)))
    )
}

/// Modern system screenshot backend. macOS 14+ uses ScreenCaptureKit; the
/// legacy Core Graphics calls exist only inside the macOS 13 availability
/// branch and can be removed when the deployment target advances.
struct SystemScreenImageCapturer: ScreenImageCapturing {
    func captureDisplay(
        displayID: CGDirectDisplayID,
        logicalFrame: CGRect
    ) async throws -> CGImage {
        if #available(macOS 14.0, *) {
            return try await captureWithScreenCaptureKit(
                displayID: displayID,
                sourceRect: nil
            )
        } else {
            return try await legacyCaptureDisplay(displayID)
        }
    }

    func capture(rect: CGRect) async throws -> CGImage {
        try await capture(rect: rect, excludingCurrentApplication: false)
    }

    /// Captures a Quartz-global rectangle while optionally excluding PEEK's
    /// own transparent selection windows. This is used by the live pixel
    /// inspector; the final region capture hides the overlays before reading.
    func capture(
        rect: CGRect,
        excludingCurrentApplication: Bool
    ) async throws -> CGImage {
        let captureRect = rect.standardized.integral
        guard captureRect.width >= 1, captureRect.height >= 1 else {
            throw ScrollCaptureError.invalidCaptureRect
        }
        if #available(macOS 14.0, *) {
            let content = try await SCShareableContent.current
            guard let display = content.displays.first(where: {
                $0.frame.standardized.contains(captureRect)
            }) else {
                throw ScreenImageCaptureError.rectOutsideSingleDisplay
            }
            return try await captureWithScreenCaptureKit(
                display: display,
                sourceRect: captureRect,
                excludingCurrentApplication: excludingCurrentApplication,
                content: content
            )
        } else {
            return try await legacyCaptureRect(captureRect)
        }
    }

    @available(macOS 14.0, *)
    private func captureWithScreenCaptureKit(
        displayID: CGDirectDisplayID,
        sourceRect: CGRect?
    ) async throws -> CGImage {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first(where: {
            $0.displayID == displayID
        }) else {
            throw ScreenImageCaptureError.displayUnavailable(displayID)
        }
        return try await captureWithScreenCaptureKit(
            display: display,
            sourceRect: sourceRect,
            excludingCurrentApplication: false,
            content: content
        )
    }

    @available(macOS 14.0, *)
    private func captureWithScreenCaptureKit(
        display: SCDisplay,
        sourceRect: CGRect?,
        excludingCurrentApplication: Bool,
        content: SCShareableContent
    ) async throws -> CGImage {
        let excludedApplications: [SCRunningApplication]
        if excludingCurrentApplication,
           let bundleIdentifier = Bundle.main.bundleIdentifier {
            excludedApplications = content.applications.filter {
                $0.bundleIdentifier == bundleIdentifier
            }
        } else {
            excludedApplications = []
        }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: excludedApplications,
            exceptingWindows: []
        )
        let configuration = SCStreamConfiguration()
        configuration.showsCursor = false
        configuration.queueDepth = 1
        configuration.captureResolution = .best

        let displayFrame = display.frame.standardized
        let globalSourceRect = sourceRect?.standardized ?? displayFrame
        let localSourceRect = CGRect(
            x: globalSourceRect.minX - displayFrame.minX,
            y: globalSourceRect.minY - displayFrame.minY,
            width: globalSourceRect.width,
            height: globalSourceRect.height
        ).integral
        configuration.sourceRect = localSourceRect

        let pixelDimensions = screenCapturePixelDimensions(
            logicalSize: localSourceRect.size,
            pointPixelScale: CGFloat(filter.pointPixelScale)
        )
        configuration.width = pixelDimensions.width
        configuration.height = pixelDimensions.height

        return try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
    }

    @available(macOS, introduced: 13.0, obsoleted: 14.0)
    private func legacyCaptureDisplay(
        _ displayID: CGDirectDisplayID
    ) async throws -> CGImage {
        try await Task.detached(priority: .userInitiated) {
            guard let image = CGDisplayCreateImage(displayID) else {
                throw ScreenImageCaptureError.captureReturnedNoImage
            }
            return image
        }.value
    }

    @available(macOS, introduced: 13.0, obsoleted: 14.0)
    private func legacyCaptureRect(_ rect: CGRect) async throws -> CGImage {
        try await Task.detached(priority: .userInitiated) {
            guard let image = CGWindowListCreateImage(
                rect,
                .optionOnScreenOnly,
                kCGNullWindowID,
                [.bestResolution, .boundsIgnoreFraming]
            ) else {
                throw ScreenImageCaptureError.captureReturnedNoImage
            }
            return image
        }.value
    }
}

protocol ScrollFrameCapturing: Sendable {
    func capture(rect: CGRect) async throws -> CGImage
}

enum ScreenRecordingPermission {
    static var isGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// 该方法可能触发系统权限弹窗，应由明确的用户操作调用。
    @discardableResult
    static func request() -> Bool {
        CGRequestScreenCaptureAccess()
    }
}

/// 使用系统截图服务捕获 Quartz 全局坐标中的同一区域。
struct QuartzScrollFrameCapturer: ScrollFrameCapturing {
    private let screenCapturer: any ScreenImageCapturing
    private let permissionGranted: @Sendable () -> Bool

    init(
        screenCapturer: any ScreenImageCapturing = SystemScreenImageCapturer(),
        permissionGranted: @escaping @Sendable () -> Bool = {
            ScreenRecordingPermission.isGranted
        }
    ) {
        self.screenCapturer = screenCapturer
        self.permissionGranted = permissionGranted
    }

    func capture(rect: CGRect) async throws -> CGImage {
        guard permissionGranted() else {
            throw ScrollCaptureError.screenRecordingPermissionDenied
        }
        do {
            return try await screenCapturer.capture(rect: rect)
        } catch let error as ScrollCaptureError {
            throw error
        } catch {
            throw ScrollCaptureError.captureFailed
        }
    }
}
