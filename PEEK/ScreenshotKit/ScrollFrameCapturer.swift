import CoreGraphics
import Foundation
import OSLog
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
    case displayGeometryChanged(CGDirectDisplayID)
    case rectOutsideSingleDisplay
    case captureReturnedNoImage

    var errorDescription: String? {
        switch self {
        case .displayUnavailable(let displayID):
            return L10n.tr("ScreenCaptureKit 找不到显示器 %u", displayID)
        case .displayGeometryChanged(let displayID):
            return L10n.tr("显示器 %u 的分辨率或布局已变化", displayID)
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

/// Geometry carried by a ScreenCaptureKit metadata snapshot or read from the
/// live Core Graphics display state. Desktop pixels are never retained here.
struct ScreenCaptureDisplayGeometry: Equatable, Sendable {
    let displayID: CGDirectDisplayID
    let frame: CGRect
    let logicalSize: CGSize
    let pointPixelScale: CGFloat?
}

/// Exact reason a cached ScreenCaptureKit display no longer represents the
/// live Quartz display. Keeping this structured makes a real display change
/// distinguishable from a coordinate-space or scale-reading bug in logs and
/// regression tests.
enum ScreenCaptureDisplayGeometryMismatch: String, Equatable, Sendable {
    case displayID = "display_id"
    case frameOrigin = "frame_origin"
    case frameSize = "frame_size"
    case logicalSize = "logical_size"
    case pointPixelScale = "point_pixel_scale"
    case expectedLogicalSize = "expected_logical_size"
}

/// Rejects a cached display even when its ID still exists if its layout,
/// logical dimensions or backing scale no longer match the live display.
/// `expectedLogicalFrame` comes from AppKit, whose global Y axis differs from
/// Core Graphics, so only its logical size is compared.
func screenCaptureDisplayGeometryMatches(
    cached: ScreenCaptureDisplayGeometry,
    current: ScreenCaptureDisplayGeometry,
    expectedLogicalFrame: CGRect? = nil
) -> Bool {
    screenCaptureDisplayGeometryMismatch(
        cached: cached,
        current: current,
        expectedLogicalFrame: expectedLogicalFrame
    ) == nil
}

func screenCaptureDisplayGeometryMismatch(
    cached: ScreenCaptureDisplayGeometry,
    current: ScreenCaptureDisplayGeometry,
    expectedLogicalFrame: CGRect? = nil
) -> ScreenCaptureDisplayGeometryMismatch? {
    guard cached.displayID == current.displayID else { return .displayID }

    let cachedFrame = cached.frame.standardized
    let currentFrame = current.frame.standardized
    guard screenCapturePointApproximatelyEqual(
        cachedFrame.origin,
        currentFrame.origin
    ) else {
        return .frameOrigin
    }
    guard screenCaptureSizeApproximatelyEqual(
        cachedFrame.size,
        currentFrame.size
    ) else {
        return .frameSize
    }
    guard screenCaptureSizeApproximatelyEqual(
        cached.logicalSize,
        current.logicalSize
    ) else {
        return .logicalSize
    }
    if let cachedScale = cached.pointPixelScale,
       let currentScale = current.pointPixelScale,
       !screenCaptureScalarApproximatelyEqual(cachedScale, currentScale) {
        return .pointPixelScale
    }

    if let expectedLogicalFrame,
       !screenCaptureSizeApproximatelyEqual(
           expectedLogicalFrame.standardized.size,
           current.logicalSize
       ) {
        return .expectedLogicalSize
    }
    return nil
}

private func screenCaptureScalarApproximatelyEqual(
    _ lhs: CGFloat,
    _ rhs: CGFloat,
    tolerance: CGFloat = 0.01
) -> Bool {
    lhs.isFinite && rhs.isFinite && abs(lhs - rhs) <= tolerance
}

private func screenCaptureSizeApproximatelyEqual(_ lhs: CGSize, _ rhs: CGSize) -> Bool {
    screenCaptureScalarApproximatelyEqual(lhs.width, rhs.width)
        && screenCaptureScalarApproximatelyEqual(lhs.height, rhs.height)
}

private func screenCapturePointApproximatelyEqual(_ lhs: CGPoint, _ rhs: CGPoint) -> Bool {
    screenCaptureScalarApproximatelyEqual(lhs.x, rhs.x)
        && screenCaptureScalarApproximatelyEqual(lhs.y, rhs.y)
}

/// Derives ScreenCaptureKit's pixels-per-point value from the live Quartz
/// display mode. `CGDisplayBounds` and `SCDisplay.frame` are global logical
/// coordinates, while `CGDisplayMode.pixelWidth/pixelHeight` are backing
/// pixels. `CGDisplayPixelsWide/High` is retained only as a fallback because
/// on a Retina display it may report the logical framebuffer dimensions.
func screenCapturePointPixelScale(
    logicalSize: CGSize,
    modePixelSize: CGSize?,
    fallbackPixelSize: CGSize?
) -> CGFloat? {
    if let modePixelSize,
       let scale = screenCaptureUniformPointPixelScale(
           logicalSize: logicalSize,
           pixelSize: modePixelSize
       ) {
        return scale
    }
    // A display rotated by 90/270 degrees can expose the mode's native pixel
    // orientation while its global bounds are already rotated. Compare the
    // transposed mode before falling back to the less reliable legacy values.
    if let modePixelSize,
       let scale = screenCaptureUniformPointPixelScale(
           logicalSize: logicalSize,
           pixelSize: CGSize(
               width: modePixelSize.height,
               height: modePixelSize.width
           )
       ) {
        return scale
    }
    if let fallbackPixelSize {
        return screenCaptureUniformPointPixelScale(
            logicalSize: logicalSize,
            pixelSize: fallbackPixelSize
        )
    }
    return nil
}

private func screenCaptureUniformPointPixelScale(
    logicalSize: CGSize,
    pixelSize: CGSize
) -> CGFloat? {
    guard logicalSize.width.isFinite,
          logicalSize.height.isFinite,
          logicalSize.width > 0,
          logicalSize.height > 0,
          pixelSize.width.isFinite,
          pixelSize.height.isFinite,
          pixelSize.width > 0,
          pixelSize.height > 0 else {
        return nil
    }

    let horizontalScale = pixelSize.width / logicalSize.width
    let verticalScale = pixelSize.height / logicalSize.height
    guard screenCaptureScalarApproximatelyEqual(horizontalScale, verticalScale),
          horizontalScale > 0 else {
        return nil
    }
    return (horizontalScale + verticalScale) / 2
}

/// One immutable metadata value returned by `ScreenCaptureMetadataCache`.
/// The generation lets a caller invalidate and retry only the stale value it
/// actually used, without making concurrent display captures start duplicate
/// `SCShareableContent` requests.
struct ScreenCaptureMetadataSnapshot<Value: Sendable>: Sendable {
    let value: Value
    let generation: UInt64
    fileprivate let loadedAt: TimeInterval
}

/// Small generic single-flight cache used for ScreenCaptureKit metadata only.
/// Desktop pixels are deliberately never stored here. A refresh requested by
/// several failed display captures is coalesced into one loader task.
actor ScreenCaptureMetadataCache<Value: Sendable> {
    typealias Loader = @Sendable () async throws -> Value

    private struct InFlight {
        let generation: UInt64
        let task: Task<ScreenCaptureMetadataSnapshot<Value>, Error>
    }

    private let maximumAge: TimeInterval
    private let now: @Sendable () -> TimeInterval
    private let loader: Loader
    private var cached: ScreenCaptureMetadataSnapshot<Value>?
    private var inFlight: InFlight?
    private var nextGeneration: UInt64 = 1
    private var latestLifecycleGeneration: UInt64 = 0

    init(
        maximumAge: TimeInterval,
        now: @escaping @Sendable () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        },
        loader: @escaping Loader
    ) {
        self.maximumAge = max(0, maximumAge)
        self.now = now
        self.loader = loader
    }

    func snapshot() async throws -> ScreenCaptureMetadataSnapshot<Value> {
        while true {
            try Task.checkCancellation()
            if let cached, isFresh(cached) {
                return cached
            }

            let flight: InFlight
            if let inFlight {
                flight = inFlight
            } else {
                let generation = allocateGeneration()
                let loader = loader
                let now = now
                let task = Task {
                    ScreenCaptureMetadataSnapshot(
                        value: try await loader(),
                        generation: generation,
                        loadedAt: now()
                    )
                }
                flight = InFlight(generation: generation, task: task)
                inFlight = flight
            }

            do {
                let loaded = try await flight.task.value
                // A lifecycle transition may have replaced this task while its
                // underlying framework request was still completing. Ignore
                // that late result and join the replacement flight instead.
                guard inFlight?.generation == flight.generation else {
                    continue
                }
                cached = loaded
                inFlight = nil
                return loaded
            } catch {
                guard inFlight?.generation == flight.generation else {
                    continue
                }
                inFlight = nil
                throw error
            }
        }
    }

    func refreshed(
        after staleGeneration: UInt64
    ) async throws -> ScreenCaptureMetadataSnapshot<Value> {
        if let cached,
           cached.generation != staleGeneration,
           isFresh(cached) {
            return cached
        }
        if cached?.generation == staleGeneration {
            cached = nil
        }
        // If another caller already started the replacement, `snapshot()`
        // joins that task. Otherwise this caller creates the single new flight.
        return try await snapshot()
    }

    /// Applies app lifecycle work in notification order, not detached-task
    /// arrival order. A cancelled older task can therefore never invalidate a
    /// snapshot already prewarmed by a newer display/wake notification.
    @discardableResult
    func applyLifecycleTransition(
        generation: UInt64,
        invalidateCachedValue: Bool
    ) -> Bool {
        guard generation > latestLifecycleGeneration else { return false }
        latestLifecycleGeneration = generation
        if invalidateCachedValue {
            invalidateCachedValueNow()
        }
        return true
    }

    private func isFresh(_ snapshot: ScreenCaptureMetadataSnapshot<Value>) -> Bool {
        let age = now() - snapshot.loadedAt
        return age >= 0 && age <= maximumAge
    }

    private func allocateGeneration() -> UInt64 {
        let generation = nextGeneration
        nextGeneration &+= 1
        if nextGeneration == 0 {
            nextGeneration = 1
        }
        return generation
    }

    private func invalidateCachedValueNow() {
        cached = nil
        inFlight?.task.cancel()
        inFlight = nil
        // Ensure a late result from the cancelled flight cannot share a future
        // generation even when UInt64 eventually wraps.
        _ = allocateGeneration()
    }
}

/// `SCShareableContent` is an immutable framework snapshot. ScreenCaptureKit
/// does not currently declare it `Sendable`, so isolate the audited crossing in
/// this wrapper while the cache actor owns its lifecycle.
private struct ScreenCaptureShareableContentValue: @unchecked Sendable {
    let content: SCShareableContent
}

private enum ScreenCaptureShareableContentStore {
    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.shawnshoper.peek",
        category: "ScreenshotCapture"
    )

    /// Display metadata remains valid until the environment tells us otherwise.
    /// Display changes, wake events and app lifecycle changes proactively apply
    /// a generation-ordered transition. Missing displays, changed geometry and
    /// transient SCK failures also invalidate and retry automatically.
    static let cache = ScreenCaptureMetadataCache<ScreenCaptureShareableContentValue>(
        maximumAge: .infinity
    ) {
        let startedAt = ProcessInfo.processInfo.systemUptime
        do {
            let content = try await SCShareableContent.current
            let elapsedMilliseconds = Int(
                ((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000).rounded()
            )
            logger.info(
                "stage=shareable_content result=success elapsed_ms=\(elapsedMilliseconds, privacy: .public) displays=\(content.displays.count, privacy: .public)"
            )
            return ScreenCaptureShareableContentValue(content: content)
        } catch {
            let elapsedMilliseconds = Int(
                ((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000).rounded()
            )
            logger.error(
                "stage=shareable_content result=failure elapsed_ms=\(elapsedMilliseconds, privacy: .public) error=\(error.localizedDescription, privacy: .private)"
            )
            throw error
        }
    }
}

struct SystemScreenImageCaptureSession: @unchecked Sendable {
    fileprivate let shareableContent: ScreenCaptureMetadataSnapshot<
        ScreenCaptureShareableContentValue
    >?
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
    /// Warms only ScreenCaptureKit's display/application metadata after the app
    /// already has Screen Recording permission. It never requests permission
    /// and never captures or caches desktop pixels.
    static func prewarmIfAuthorized() async {
        guard CGPreflightScreenCaptureAccess() else { return }
        guard #available(macOS 14.0, *) else { return }
        _ = try? await ScreenCaptureShareableContentStore.cache.snapshot()
    }

    /// Registers one app lifecycle operation in notification generation order.
    /// Detached tasks may arrive out of order after cancellation, so stale
    /// generations are rejected before they can invalidate a newer prewarm.
    @discardableResult
    static func applyMetadataLifecycleTransition(
        generation: UInt64,
        invalidateCachedMetadata: Bool
    ) async -> Bool {
        await ScreenCaptureShareableContentStore.cache.applyLifecycleTransition(
            generation: generation,
            invalidateCachedValue: invalidateCachedMetadata
        )
    }

    /// Prepares one immutable metadata snapshot for a complete frozen-desktop
    /// capture. Every display in that session reuses this value.
    func prepareCaptureSession(
        expectedDisplayIDs: [CGDirectDisplayID]
    ) async throws -> SystemScreenImageCaptureSession {
        guard #available(macOS 14.0, *) else {
            return SystemScreenImageCaptureSession(shareableContent: nil)
        }

        var snapshot = try await ScreenCaptureShareableContentStore.cache.snapshot()
        do {
            try validateDisplayMetadata(
                content: snapshot.value.content,
                expectedDisplayIDs: expectedDisplayIDs
            )
        } catch {
            guard shouldRefreshMetadata(after: error) else { throw error }
            ScreenCaptureShareableContentStore.logger.warning(
                "stage=shareable_content result=stale reason=display_geometry_changed"
            )
            snapshot = try await ScreenCaptureShareableContentStore.cache.refreshed(
                after: snapshot.generation
            )
            // The retry is deliberately bounded. If live display state changes
            // again, reject the session instead of starting another cold load.
            try validateDisplayMetadata(
                content: snapshot.value.content,
                expectedDisplayIDs: expectedDisplayIDs
            )
        }
        return SystemScreenImageCaptureSession(shareableContent: snapshot)
    }

    func captureDisplay(
        displayID: CGDirectDisplayID,
        logicalFrame: CGRect
    ) async throws -> CGImage {
        let session = try await prepareCaptureSession(expectedDisplayIDs: [displayID])
        return try await captureDisplay(
            displayID: displayID,
            logicalFrame: logicalFrame,
            session: session
        )
    }

    func captureDisplay(
        displayID: CGDirectDisplayID,
        logicalFrame: CGRect,
        session: SystemScreenImageCaptureSession
    ) async throws -> CGImage {
        if #available(macOS 14.0, *) {
            guard let initialSnapshot = session.shareableContent else {
                throw ScreenImageCaptureError.displayUnavailable(displayID)
            }
            return try await captureDisplayWithMetadataRetry(
                displayID: displayID,
                sourceRect: nil,
                expectedLogicalFrame: logicalFrame,
                initialSnapshot: initialSnapshot
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
            let initialSnapshot = try await ScreenCaptureShareableContentStore.cache.snapshot()
            return try await captureRectWithMetadataRetry(
                captureRect,
                excludingCurrentApplication: excludingCurrentApplication,
                initialSnapshot: initialSnapshot
            )
        } else {
            return try await legacyCaptureRect(captureRect)
        }
    }

    @available(macOS 14.0, *)
    private func captureDisplayWithMetadataRetry(
        displayID: CGDirectDisplayID,
        sourceRect: CGRect?,
        expectedLogicalFrame: CGRect,
        initialSnapshot: ScreenCaptureMetadataSnapshot<ScreenCaptureShareableContentValue>
    ) async throws -> CGImage {
        do {
            return try await captureWithScreenCaptureKit(
                displayID: displayID,
                sourceRect: sourceRect,
                expectedLogicalFrame: expectedLogicalFrame,
                content: initialSnapshot.value.content
            )
        } catch {
            guard shouldRefreshMetadata(after: error) else { throw error }
            ScreenCaptureShareableContentStore.logger.warning(
                "stage=capture_display result=retry display_id=\(displayID, privacy: .public)"
            )
            let refreshed = try await ScreenCaptureShareableContentStore.cache.refreshed(
                after: initialSnapshot.generation
            )
            return try await captureWithScreenCaptureKit(
                displayID: displayID,
                sourceRect: sourceRect,
                expectedLogicalFrame: expectedLogicalFrame,
                content: refreshed.value.content
            )
        }
    }

    @available(macOS 14.0, *)
    private func captureWithScreenCaptureKit(
        displayID: CGDirectDisplayID,
        sourceRect: CGRect?,
        expectedLogicalFrame: CGRect,
        content: SCShareableContent
    ) async throws -> CGImage {
        let display = try validatedDisplay(
            displayID: displayID,
            expectedLogicalFrame: expectedLogicalFrame,
            content: content
        )
        return try await captureWithScreenCaptureKit(
            display: display,
            sourceRect: sourceRect,
            excludingCurrentApplication: false,
            content: content
        )
    }

    @available(macOS 14.0, *)
    private func captureRectWithMetadataRetry(
        _ captureRect: CGRect,
        excludingCurrentApplication: Bool,
        initialSnapshot: ScreenCaptureMetadataSnapshot<ScreenCaptureShareableContentValue>
    ) async throws -> CGImage {
        do {
            return try await captureRectWithScreenCaptureKit(
                captureRect,
                excludingCurrentApplication: excludingCurrentApplication,
                content: initialSnapshot.value.content
            )
        } catch {
            guard shouldRefreshMetadata(after: error) else { throw error }
            ScreenCaptureShareableContentStore.logger.warning(
                "stage=capture_rect result=retry reason=stale_metadata"
            )
            let refreshed = try await ScreenCaptureShareableContentStore.cache.refreshed(
                after: initialSnapshot.generation
            )
            return try await captureRectWithScreenCaptureKit(
                captureRect,
                excludingCurrentApplication: excludingCurrentApplication,
                content: refreshed.value.content
            )
        }
    }

    @available(macOS 14.0, *)
    private func captureRectWithScreenCaptureKit(
        _ captureRect: CGRect,
        excludingCurrentApplication: Bool,
        content: SCShareableContent
    ) async throws -> CGImage {
        guard let display = content.displays.first(where: {
            $0.frame.standardized.contains(captureRect)
        }) else {
            throw ScreenImageCaptureError.rectOutsideSingleDisplay
        }
        try validateDisplayGeometry(display, expectedLogicalFrame: nil)
        return try await captureWithScreenCaptureKit(
            display: display,
            sourceRect: captureRect,
            excludingCurrentApplication: excludingCurrentApplication,
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

        let startedAt = ProcessInfo.processInfo.systemUptime
        do {
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            let elapsedMilliseconds = Int(
                ((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000).rounded()
            )
            ScreenCaptureShareableContentStore.logger.info(
                "stage=capture_frame result=success elapsed_ms=\(elapsedMilliseconds, privacy: .public) display_id=\(display.displayID, privacy: .public) pixels=\(image.width, privacy: .public)x\(image.height, privacy: .public)"
            )
            return image
        } catch {
            let elapsedMilliseconds = Int(
                ((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000).rounded()
            )
            ScreenCaptureShareableContentStore.logger.error(
                "stage=capture_frame result=failure elapsed_ms=\(elapsedMilliseconds, privacy: .public) display_id=\(display.displayID, privacy: .public) error=\(error.localizedDescription, privacy: .private)"
            )
            throw error
        }
    }

    @available(macOS 14.0, *)
    private func validateDisplayMetadata(
        content: SCShareableContent,
        expectedDisplayIDs: [CGDirectDisplayID]
    ) throws {
        for displayID in expectedDisplayIDs {
            _ = try validatedDisplay(
                displayID: displayID,
                expectedLogicalFrame: nil,
                content: content
            )
        }
    }

    @available(macOS 14.0, *)
    private func validatedDisplay(
        displayID: CGDirectDisplayID,
        expectedLogicalFrame: CGRect?,
        content: SCShareableContent
    ) throws -> SCDisplay {
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ScreenImageCaptureError.displayUnavailable(displayID)
        }
        try validateDisplayGeometry(display, expectedLogicalFrame: expectedLogicalFrame)
        return display
    }

    @available(macOS 14.0, *)
    private func validateDisplayGeometry(
        _ display: SCDisplay,
        expectedLogicalFrame: CGRect?
    ) throws {
        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: []
        )
        let cached = ScreenCaptureDisplayGeometry(
            displayID: display.displayID,
            frame: display.frame,
            logicalSize: CGSize(width: display.width, height: display.height),
            pointPixelScale: validPointPixelScale(CGFloat(filter.pointPixelScale))
        )
        guard let current = currentDisplayGeometry(displayID: display.displayID) else {
            ScreenCaptureShareableContentStore.logger.warning(
                "stage=display_geometry_validation result=mismatch reason=current_display_unavailable display_id=\(display.displayID, privacy: .public)"
            )
            throw ScreenImageCaptureError.displayGeometryChanged(display.displayID)
        }
        guard let mismatch = screenCaptureDisplayGeometryMismatch(
            cached: cached,
            current: current,
            expectedLogicalFrame: expectedLogicalFrame
        ) else { return }

        let expectedSize = expectedLogicalFrame?.standardized.size ?? .zero
        ScreenCaptureShareableContentStore.logger.warning(
            "stage=display_geometry_validation result=mismatch reason=\(mismatch.rawValue, privacy: .public) display_id=\(display.displayID, privacy: .public) cached_x=\(Double(cached.frame.minX), privacy: .public) cached_y=\(Double(cached.frame.minY), privacy: .public) cached_width=\(Double(cached.frame.width), privacy: .public) cached_height=\(Double(cached.frame.height), privacy: .public) current_x=\(Double(current.frame.minX), privacy: .public) current_y=\(Double(current.frame.minY), privacy: .public) current_width=\(Double(current.frame.width), privacy: .public) current_height=\(Double(current.frame.height), privacy: .public) cached_scale=\(Double(cached.pointPixelScale ?? -1), privacy: .public) current_scale=\(Double(current.pointPixelScale ?? -1), privacy: .public) expected_width=\(Double(expectedSize.width), privacy: .public) expected_height=\(Double(expectedSize.height), privacy: .public)"
        )
        throw ScreenImageCaptureError.displayGeometryChanged(display.displayID)
    }

    private func currentDisplayGeometry(
        displayID: CGDirectDisplayID
    ) -> ScreenCaptureDisplayGeometry? {
        guard CGDisplayIsActive(displayID) != 0 else { return nil }
        let frame = CGDisplayBounds(displayID).standardized
        guard frame.width > 0, frame.height > 0 else { return nil }

        // The current display mode is the authoritative source for backing
        // pixels. In particular, CGDisplayPixelsWide/High can equal the
        // logical bounds on Retina displays and would incorrectly produce 1x.
        let modePixelSize = CGDisplayCopyDisplayMode(displayID).map {
            CGSize(
                width: CGFloat($0.pixelWidth),
                height: CGFloat($0.pixelHeight)
            )
        }
        let fallbackPixelSize = CGSize(
            width: CGDisplayPixelsWide(displayID),
            height: CGDisplayPixelsHigh(displayID)
        )
        let pointPixelScale = validPointPixelScale(
            screenCapturePointPixelScale(
                logicalSize: frame.size,
                modePixelSize: modePixelSize,
                fallbackPixelSize: fallbackPixelSize
            )
        )
        return ScreenCaptureDisplayGeometry(
            displayID: displayID,
            frame: frame,
            logicalSize: frame.size,
            pointPixelScale: pointPixelScale
        )
    }

    private func validPointPixelScale(_ scale: CGFloat?) -> CGFloat? {
        guard let scale else { return nil }
        return scale.isFinite && scale > 0 ? scale : nil
    }

    @available(macOS 14.0, *)
    private func shouldRefreshMetadata(after error: Error) -> Bool {
        if let captureError = error as? ScreenImageCaptureError {
            switch captureError {
            case .displayUnavailable, .displayGeometryChanged, .rectOutsideSingleDisplay:
                return true
            case .captureReturnedNoImage:
                return false
            }
        }

        let nsError = error as NSError
        guard nsError.domain == SCStreamErrorDomain else { return false }
        // Permission, entitlement and invalid-parameter failures cannot be
        // repaired by refreshing metadata. Connection, list/source and
        // framework-internal failures can result from a stale SCK snapshot.
        return ![-3801, -3803, -3812].contains(nsError.code)
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
