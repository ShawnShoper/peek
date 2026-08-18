import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Security

/// The coordinate source used to resolve a scrolling-capture target.
enum ScrollCaptureTargetSource: String, Equatable, Sendable {
    case accessibilityScrollArea
    case accessibilityWebArea
    /// Window-level AX fallback used to preselect/locate a window. This does
    /// not prove that the selected rectangle itself scrolls.
    case accessibilityFocusedWindow
    /// WindowServer fallback used to preselect/locate a window. This does not
    /// prove that the selected rectangle itself scrolls.
    case quartzWindow
}

/// A resolved target for scrolling capture.
///
/// `windowFrame` and `captureRect` use the global AppKit screen coordinate
/// space (origin at the lower-left of the primary display). `scrollPoint`
/// uses Quartz global coordinates (origin at the upper-left of the primary
/// display), which is the coordinate space expected by `CGEvent.location`.
struct ScrollCaptureTarget: Equatable, Sendable {
    let ownerPID: pid_t
    let windowID: CGWindowID
    let windowFrame: CGRect
    let captureRect: CGRect
    let scrollPoint: CGPoint
    let source: ScrollCaptureTargetSource
    let title: String?
    let wasClippedToSingleScreen: Bool
    /// AppKit rectangles for every visible AXScrollArea/AXWebArea exposed by
    /// the anchored window. The selection overlay uses this frozen map to
    /// follow the pointer without issuing synchronous AX calls on mouseMoved.
    let hoverSelectionRects: [CGRect]

    /// `true` only when Accessibility exposed a credible scroll container.
    /// Window-level fallbacks remain useful for target identification and UI
    /// preselection, but callers must not treat them as safe auto-scroll areas.
    var isVerifiedScrollRegion: Bool {
        switch source {
        case .accessibilityScrollArea, .accessibilityWebArea:
            return true
        case .accessibilityFocusedWindow, .quartzWindow:
            return false
        }
    }

    /// True only for a scrolling ancestor found directly below the pointer.
    /// Area-scan targets remain useful as a compatibility fallback, but the
    /// hover workflow can distinguish them for messaging and future policy.
    let wasPointerHitTested: Bool
}

/// Injectable representation of one WindowServer entry. The array supplied
/// to the resolver must preserve WindowServer's front-to-back ordering.
struct ScrollCaptureWindowSnapshot: Equatable, Sendable {
    let ownerPID: pid_t
    let windowID: CGWindowID
    let quartzFrame: CGRect
    let layer: Int
    let alpha: Double
    let title: String?
    let isActivatable: Bool

    init(
        ownerPID: pid_t,
        windowID: CGWindowID,
        quartzFrame: CGRect,
        layer: Int = 0,
        alpha: Double = 1,
        title: String? = nil,
        isActivatable: Bool = true
    ) {
        self.ownerPID = ownerPID
        self.windowID = windowID
        self.quartzFrame = quartzFrame
        self.layer = layer
        self.alpha = alpha
        self.title = title
        self.isActivatable = isActivatable
    }
}

enum ScrollCaptureAccessibilityRole: String, Equatable, Sendable {
    case scrollArea
    case webArea
}

struct ScrollCaptureAccessibilityRegion: Equatable, Sendable {
    let quartzFrame: CGRect
    let role: ScrollCaptureAccessibilityRole
    let depth: Int
    let isVisible: Bool
    /// A pointer hit-test may legitimately expose a root web area that nearly
    /// fills the window. It is safe as a preselection because the user pointed
    /// inside this exact ancestor chain; broad tree scans do not get this
    /// exemption.
    let wasPointerHitTested: Bool

    init(
        quartzFrame: CGRect,
        role: ScrollCaptureAccessibilityRole,
        depth: Int,
        isVisible: Bool = true,
        wasPointerHitTested: Bool = false
    ) {
        self.quartzFrame = quartzFrame
        self.role = role
        self.depth = depth
        self.isVisible = isVisible
        self.wasPointerHitTested = wasPointerHitTested
    }
}

/// Testable snapshot of the front application's AX focused window. AX frames
/// use Quartz's top-left global coordinate space.
struct ScrollCaptureAccessibilitySnapshot: Equatable, Sendable {
    let ownerPID: pid_t
    let focusedWindowQuartzFrame: CGRect
    let focusedWindowTitle: String?
    let scrollRegions: [ScrollCaptureAccessibilityRegion]
    /// The innermost AXScrollArea/AXWebArea found by hit-testing the mouse
    /// position and then walking toward the focused window. `nil` together
    /// with `didHitTestFocusedWindow == true` means that the pointer is inside
    /// the window, but not inside an exposed scrolling container.
    let hoveredScrollRegion: ScrollCaptureAccessibilityRegion?
    let didHitTestFocusedWindow: Bool

    init(
        ownerPID: pid_t,
        focusedWindowQuartzFrame: CGRect,
        focusedWindowTitle: String? = nil,
        scrollRegions: [ScrollCaptureAccessibilityRegion] = [],
        hoveredScrollRegion: ScrollCaptureAccessibilityRegion? = nil,
        didHitTestFocusedWindow: Bool = false
    ) {
        self.ownerPID = ownerPID
        self.focusedWindowQuartzFrame = focusedWindowQuartzFrame
        self.focusedWindowTitle = focusedWindowTitle
        self.scrollRegions = scrollRegions
        self.hoveredScrollRegion = hoveredScrollRegion
        self.didHitTestFocusedWindow = didHitTestFocusedWindow
    }
}

/// Resolves exactly once. The AX worker is intentionally detached because AX
/// calls are synchronous and a hung target process must never block AppKit's
/// main actor. A timeout wins the race without waiting for the blocked worker;
/// late results are discarded.
private actor ScrollCaptureAccessibilityRace {
    private var continuation: CheckedContinuation<ScrollCaptureAccessibilitySnapshot?, Never>?

    init(
        continuation: CheckedContinuation<ScrollCaptureAccessibilitySnapshot?, Never>
    ) {
        self.continuation = continuation
    }

    func finish(_ value: ScrollCaptureAccessibilitySnapshot?) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: value)
    }
}

@MainActor
struct ScrollCaptureTargetResolver {
    typealias AccessibilitySnapshotProvider = @Sendable (pid_t, Int, CGPoint?) ->
        ScrollCaptureAccessibilitySnapshot?
    typealias WindowSnapshotProvider = @MainActor () -> [ScrollCaptureWindowSnapshot]

    private let maximumAccessibilityDepth: Int
    private let accessibilityTimeoutNanoseconds: UInt64
    private let accessibilitySnapshotProvider: AccessibilitySnapshotProvider
    private let windowSnapshotProvider: WindowSnapshotProvider

    init(
        maximumAccessibilityDepth: Int = 6,
        accessibilityTimeoutNanoseconds: UInt64 = 700_000_000,
        accessibilitySnapshotProvider: AccessibilitySnapshotProvider? = nil,
        windowSnapshotProvider: WindowSnapshotProvider? = nil
    ) {
        self.maximumAccessibilityDepth = max(0, maximumAccessibilityDepth)
        self.accessibilityTimeoutNanoseconds = max(1_000_000, accessibilityTimeoutNanoseconds)
        let defaultAccessibilityProvider: AccessibilitySnapshotProvider = {
            ownerPID,
            maximumDepth,
            hitTestQuartzPoint in
            Self.captureAccessibilitySnapshot(
                ownerPID: ownerPID,
                maximumDepth: maximumDepth,
                hitTestQuartzPoint: hitTestQuartzPoint
            )
        }
        self.accessibilitySnapshotProvider = accessibilitySnapshotProvider
            ?? defaultAccessibilityProvider
        self.windowSnapshotProvider = windowSnapshotProvider
            ?? Self.captureWindowSnapshots
    }

    /// Resolves the target that was frontmost when capture was triggered.
    /// When a menu-bar application is frontmost (or no frontmost application
    /// is reported), the WindowServer fallback selects the first eligible
    /// non-PEEK window instead.
    func resolve(
        frontmostApplication: NSRunningApplication?,
        pointerAppKitPoint: CGPoint? = nil,
        screens: [NSScreen] = NSScreen.screens
    ) async -> ScrollCaptureTarget? {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let frontmostPID = frontmostApplication?.processIdentifier
        let screenFrames = screens.map(\.frame)
        guard let referenceTop = screenFrames.first?.maxY else { return nil }
        let pointerQuartzPoint = pointerAppKitPoint.map {
            CGPoint(x: $0.x, y: referenceTop - $0.y)
        }
        return await resolve(
            frontmostPID: frontmostPID,
            currentPID: currentPID,
            screenFrames: screenFrames,
            pointerQuartzPoint: pointerQuartzPoint
        )
    }

    /// Injectable live-resolution seam for deterministic tests. Both pointer
    /// and window frames use Quartz coordinates; unlike the pure static
    /// resolver, this path exercises the asynchronous AX timeout policy.
    func resolve(
        frontmostPID: pid_t?,
        currentPID: pid_t,
        screenFrames: [CGRect],
        pointerQuartzPoint: CGPoint? = nil
    ) async -> ScrollCaptureTarget? {
        guard !screenFrames.isEmpty else { return nil }
        let windowSnapshots = windowSnapshotProvider()

        // Opening PEEK's main window or menu makes PEEK frontmost before
        // capture starts. Resolve the underlying WindowServer entry first, then
        // query AX for that exact external process. AX remains an optional
        // source of a credible inner scroll-region preselection; the Quartz
        // entry is always the stable PID/window-ID anchor.
        guard let window = Self.preferredExternalWindow(
            frontmostPID: frontmostPID,
            currentPID: currentPID,
            pointerQuartzPoint: pointerQuartzPoint,
            windowSnapshots: windowSnapshots
        ) else {
            return nil
        }
        let hitTestPoint = pointerQuartzPoint.flatMap {
            window.quartzFrame.standardized.contains($0) ? $0 : nil
        }
        let accessibilitySnapshot = await Self.accessibilitySnapshot(
            provider: accessibilitySnapshotProvider,
            ownerPID: window.ownerPID,
            maximumDepth: maximumAccessibilityDepth,
            hitTestQuartzPoint: hitTestPoint,
            timeoutNanoseconds: accessibilityTimeoutNanoseconds
        )

        return Self.resolveAnchoredWindow(
            window: window,
            screenFrames: screenFrames,
            maximumAccessibilityDepth: maximumAccessibilityDepth,
            accessibilitySnapshot: accessibilitySnapshot
        )
    }

    /// AX exposes only synchronous APIs. Run the complete snapshot off the
    /// main actor and impose a real wall-clock ceiling for the user-facing
    /// preselection. Individual element timeouts still bound the detached
    /// worker, while this outer race guarantees the overlay can appear.
    private nonisolated static func accessibilitySnapshot(
        provider: @escaping AccessibilitySnapshotProvider,
        ownerPID: pid_t,
        maximumDepth: Int,
        hitTestQuartzPoint: CGPoint?,
        timeoutNanoseconds: UInt64 = 700_000_000
    ) async -> ScrollCaptureAccessibilitySnapshot? {
        await withCheckedContinuation { continuation in
            let race = ScrollCaptureAccessibilityRace(continuation: continuation)
            Task.detached(priority: .userInitiated) {
                let snapshot = provider(
                    ownerPID,
                    maximumDepth,
                    hitTestQuartzPoint
                )
                await race.finish(snapshot)
            }
            Task.detached(priority: .userInitiated) {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                await race.finish(nil)
            }
        }
    }

    /// Resolves the topmost external layer-zero window containing an AppKit
    /// global point. This is intentionally Quartz-only: callers can bind a
    /// manually adjusted capture rectangle to a precise PID/window-ID without
    /// claiming that the whole window is a verified AX scroll region.
    func resolveWindow(
        containingAppKitPoint point: CGPoint,
        screens: [NSScreen] = NSScreen.screens
    ) -> ScrollCaptureTarget? {
        Self.resolveWindow(
            containingAppKitPoint: point,
            currentPID: ProcessInfo.processInfo.processIdentifier,
            screenFrames: screens.map(\.frame),
            windowSnapshots: windowSnapshotProvider()
        )
    }

    /// Pure resolution entry point used by unit tests and deterministic
    /// callers. `screenFrames` are global AppKit frames, with the primary
    /// display first. Window and accessibility frames use Quartz coordinates.
    nonisolated static func resolve(
        frontmostPID: pid_t?,
        currentPID: pid_t,
        screenFrames: [CGRect],
        maximumAccessibilityDepth: Int = 6,
        accessibilitySnapshot: ScrollCaptureAccessibilitySnapshot?,
        pointerQuartzPoint: CGPoint? = nil,
        windowSnapshots: [ScrollCaptureWindowSnapshot]
    ) -> ScrollCaptureTarget? {
        guard let primaryFrame = screenFrames.first else { return nil }

        let depthLimit = max(0, maximumAccessibilityDepth)
        let externalFrontmostPID = frontmostPID.flatMap { pid in
            pid == currentPID ? nil : pid
        }

        if let window = preferredExternalWindow(
            frontmostPID: frontmostPID,
            currentPID: currentPID,
            pointerQuartzPoint: pointerQuartzPoint,
            windowSnapshots: windowSnapshots
        ) {
            return resolveAnchoredWindow(
                window: window,
                screenFrames: screenFrames,
                maximumAccessibilityDepth: depthLimit,
                accessibilitySnapshot: accessibilitySnapshot
            )
        }

        // Preserve the deterministic AX-only fallback for callers that cannot
        // supply WindowServer data. Live resolution always supplies a Quartz
        // anchor and therefore never reaches this path.
        guard let externalFrontmostPID,
              let accessibilitySnapshot,
              accessibilitySnapshot.ownerPID == externalFrontmostPID,
              isUsable(accessibilitySnapshot.focusedWindowQuartzFrame) else {
            return nil
        }
        return resolveAccessibilityTarget(
            snapshot: accessibilitySnapshot,
            matchingWindows: [],
            screenFrames: screenFrames,
            referenceTop: primaryFrame.maxY,
            maximumDepth: depthLimit
        )
    }

    /// Pure point-resolution entry point used by selection workflows and
    /// deterministic tests. WindowServer order must be front-to-back.
    nonisolated static func resolveWindow(
        containingAppKitPoint point: CGPoint,
        currentPID: pid_t,
        screenFrames: [CGRect],
        windowSnapshots: [ScrollCaptureWindowSnapshot]
    ) -> ScrollCaptureTarget? {
        guard let primaryFrame = screenFrames.first else { return nil }
        let quartzPoint = CGPoint(x: point.x, y: primaryFrame.maxY - point.y)
        guard let window = eligibleWindows(
            currentPID: currentPID,
            windowSnapshots: windowSnapshots
        ).first(where: { $0.quartzFrame.standardized.contains(quartzPoint) }) else {
            return nil
        }

        return makeTarget(
            ownerPID: window.ownerPID,
            windowID: window.windowID,
            windowQuartzFrame: window.quartzFrame,
            captureQuartzFrame: window.quartzFrame,
            source: .quartzWindow,
            title: window.title,
            screenFrames: screenFrames,
            referenceTop: primaryFrame.maxY
        )
    }

    private nonisolated static func resolveAnchoredWindow(
        window: ScrollCaptureWindowSnapshot,
        screenFrames: [CGRect],
        maximumAccessibilityDepth: Int,
        accessibilitySnapshot: ScrollCaptureAccessibilitySnapshot?
    ) -> ScrollCaptureTarget? {
        guard let primaryFrame = screenFrames.first else { return nil }

        if let accessibilitySnapshot,
           accessibilitySnapshot.ownerPID == window.ownerPID,
           isUsable(accessibilitySnapshot.focusedWindowQuartzFrame),
           matchingScore(
               accessibilitySnapshot.focusedWindowQuartzFrame,
               window.quartzFrame
           ) >= 0.5,
           let target = resolveAccessibilityTarget(
               snapshot: accessibilitySnapshot,
               matchingWindows: [window],
               screenFrames: screenFrames,
               referenceTop: primaryFrame.maxY,
               maximumDepth: max(0, maximumAccessibilityDepth)
           ) {
            return target
        }

        return makeTarget(
            ownerPID: window.ownerPID,
            windowID: window.windowID,
            windowQuartzFrame: window.quartzFrame,
            captureQuartzFrame: window.quartzFrame,
            source: .quartzWindow,
            title: window.title,
            screenFrames: screenFrames,
            referenceTop: primaryFrame.maxY
        )
    }

    private nonisolated static func preferredExternalWindow(
        frontmostPID: pid_t?,
        currentPID: pid_t,
        pointerQuartzPoint: CGPoint? = nil,
        windowSnapshots: [ScrollCaptureWindowSnapshot]
    ) -> ScrollCaptureWindowSnapshot? {
        let windows = eligibleWindows(
            currentPID: currentPID,
            windowSnapshots: windowSnapshots
        )
        if let frontmostPID, frontmostPID != currentPID {
            if let pointerQuartzPoint,
               let pointedWindow = windows.first(where: {
                   $0.ownerPID == frontmostPID
                       && $0.quartzFrame.standardized.contains(pointerQuartzPoint)
               }) {
                return pointedWindow
            }
            return windows.first { $0.ownerPID == frontmostPID }
        }

        // A menu-bar or main-window trigger can make PEEK frontmost. Keep
        // WindowServer's front-to-back order to select the underlying window.
        if let pointerQuartzPoint,
           let pointedWindow = windows.first(where: {
               $0.quartzFrame.standardized.contains(pointerQuartzPoint)
           }) {
            return pointedWindow
        }
        return windows.first
    }

    private nonisolated static func eligibleWindows(
        currentPID: pid_t,
        windowSnapshots: [ScrollCaptureWindowSnapshot]
    ) -> [ScrollCaptureWindowSnapshot] {
        windowSnapshots.filter {
            $0.ownerPID != currentPID
                && $0.windowID != 0
                && $0.layer == 0
                && $0.alpha > 0.01
                && $0.isActivatable
                && isUsable($0.quartzFrame)
        }
    }

    private nonisolated static func resolveAccessibilityTarget(
        snapshot: ScrollCaptureAccessibilitySnapshot,
        matchingWindows: [ScrollCaptureWindowSnapshot],
        screenFrames: [CGRect],
        referenceTop: CGFloat,
        maximumDepth: Int
    ) -> ScrollCaptureTarget? {
        let focusedFrame = snapshot.focusedWindowQuartzFrame.standardized
        let matchedWindow = bestMatchingWindow(
            focusedFrame: focusedFrame,
            windows: matchingWindows
        )

        let regionCandidates = snapshot.scrollRegions
            .filter {
                $0.isVisible
                    && $0.depth >= 0
                    && $0.depth <= maximumDepth
                    && isUsable($0.quartzFrame)
            }
            .compactMap { region -> (ScrollCaptureAccessibilityRegion, CGRect)? in
                let clipped = region.quartzFrame.standardized.intersection(focusedFrame)
                guard isUsable(clipped) else { return nil }
                return (region, clipped)
            }

        // A root AXScrollArea/AXWebArea can cover the entire focused window
        // while fixed chrome and sidebars inside it remain static. Treat every
        // near-whole-window node as ambiguous and require a manual content
        // selection instead of risking another malformed stitched image.
        let credibleCandidates = regionCandidates.filter { candidate in
            !isNearWholeWindow(candidate.1, focusedFrame: focusedFrame)
        }

        // A point hit-test is stronger than an area heuristic: start at the
        // element directly below the pointer and choose its nearest scrolling
        // ancestor. When the hit-test succeeds but exposes no scrolling
        // ancestor, deliberately fall back to the whole focused window rather
        // than selecting an unrelated scroll area elsewhere in the app.
        let hoveredRegion = snapshot.hoveredScrollRegion.flatMap {
            clippedRegion(
                $0,
                to: focusedFrame,
                maximumDepth: max(maximumDepth, $0.depth)
            )
        }
        let bestHeuristicRegion = credibleCandidates
            .max { lhs, rhs in
                let lhsArea = area(lhs.1)
                let rhsArea = area(rhs.1)
                if lhsArea == rhsArea {
                    // `max(by:)` treats `true` as lhs being ordered before
                    // rhs, so the shallower candidate must compare smaller.
                    return lhs.0.depth < rhs.0.depth
                }
                return lhsArea < rhsArea
            }
        let bestRegion = hoveredRegion
            ?? (snapshot.didHitTestFocusedWindow ? nil : bestHeuristicRegion)

        let captureFrame = bestRegion?.1 ?? focusedFrame
        let source: ScrollCaptureTargetSource
        switch bestRegion?.0.role {
        case .scrollArea:
            source = .accessibilityScrollArea
        case .webArea:
            source = .accessibilityWebArea
        case nil:
            source = .accessibilityFocusedWindow
        }

        // Only expose the exact region returned by the pointer hit-test. A
        // flattened list of every AXScrollArea/AXWebArea in the window loses
        // element identity and makes embedded iframes or preview panes win by
        // merely being the smallest rectangle under a later mouse position.
        // Outside this one trusted region the overlay falls back to the whole
        // WindowServer window, while the user can always draw a custom rect.
        let hoverSelectionRects = hoveredRegion.flatMap { candidate in
            makeTarget(
                ownerPID: snapshot.ownerPID,
                windowID: matchedWindow?.windowID ?? 0,
                windowQuartzFrame: matchedWindow?.quartzFrame ?? focusedFrame,
                captureQuartzFrame: candidate.1,
                source: candidate.0.role == .scrollArea
                    ? .accessibilityScrollArea
                    : .accessibilityWebArea,
                title: nil,
                screenFrames: screenFrames,
                referenceTop: referenceTop
            )?.captureRect
        }.map { [$0] } ?? []

        return makeTarget(
            ownerPID: snapshot.ownerPID,
            windowID: matchedWindow?.windowID ?? 0,
            windowQuartzFrame: matchedWindow?.quartzFrame ?? focusedFrame,
            captureQuartzFrame: captureFrame,
            source: source,
            title: snapshot.focusedWindowTitle ?? matchedWindow?.title,
            wasPointerHitTested: bestRegion?.0.wasPointerHitTested ?? false,
            hoverSelectionRects: hoverSelectionRects,
            screenFrames: screenFrames,
            referenceTop: referenceTop
        )
    }

    private nonisolated static func clippedRegion(
        _ region: ScrollCaptureAccessibilityRegion,
        to focusedFrame: CGRect,
        maximumDepth: Int
    ) -> (ScrollCaptureAccessibilityRegion, CGRect)? {
        guard region.isVisible,
              region.depth >= 0,
              region.depth <= maximumDepth,
              isUsable(region.quartzFrame) else {
            return nil
        }
        let clipped = region.quartzFrame.standardized.intersection(
            focusedFrame.standardized
        )
        guard isUsable(clipped) else { return nil }
        return (region, clipped)
    }

    private nonisolated static func bestMatchingWindow(
        focusedFrame: CGRect,
        windows: [ScrollCaptureWindowSnapshot]
    ) -> ScrollCaptureWindowSnapshot? {
        guard let match = windows.max(by: { lhs, rhs in
            matchingScore(focusedFrame, lhs.quartzFrame)
                < matchingScore(focusedFrame, rhs.quartzFrame)
        }), matchingScore(focusedFrame, match.quartzFrame) > 0 else {
            return nil
        }
        return match
    }

    private nonisolated static func matchingScore(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.standardized.intersection(rhs.standardized)
        guard !intersection.isNull else { return 0 }
        return area(intersection) / max(area(lhs), area(rhs), 1)
    }

    private nonisolated static func makeTarget(
        ownerPID: pid_t,
        windowID: CGWindowID,
        windowQuartzFrame: CGRect,
        captureQuartzFrame: CGRect,
        source: ScrollCaptureTargetSource,
        title: String?,
        wasPointerHitTested: Bool = false,
        hoverSelectionRects: [CGRect] = [],
        screenFrames: [CGRect],
        referenceTop: CGFloat
    ) -> ScrollCaptureTarget? {
        let desktopBounds = screenFrames.reduce(CGRect.null) { $0.union($1) }
        let windowFrame = appKitRect(
            fromQuartzRect: windowQuartzFrame,
            referenceTop: referenceTop
        ).intersection(desktopBounds)
        let rawCapture = appKitRect(
            fromQuartzRect: captureQuartzFrame,
            referenceTop: referenceTop
        ).intersection(windowFrame)
        guard isUsable(windowFrame), isUsable(rawCapture) else { return nil }

        let intersections = screenFrames.compactMap { screen -> CGRect? in
            let intersection = rawCapture.intersection(screen)
            return isUsable(intersection) ? intersection : nil
        }
        guard let captureRect = intersections.max(by: { area($0) < area($1) }) else {
            return nil
        }

        let clipped = !approximatelyEqual(captureRect, rawCapture)
        let scrollPoint = CGPoint(
            x: captureRect.midX,
            y: referenceTop - captureRect.midY
        )
        return ScrollCaptureTarget(
            ownerPID: ownerPID,
            windowID: windowID,
            windowFrame: windowFrame,
            captureRect: captureRect,
            scrollPoint: scrollPoint,
            source: source,
            title: title,
            wasClippedToSingleScreen: clipped,
            hoverSelectionRects: deduplicatedRects(hoverSelectionRects),
            wasPointerHitTested: wasPointerHitTested
        )
    }

    private nonisolated static func deduplicatedRects(_ rects: [CGRect]) -> [CGRect] {
        var output: [CGRect] = []
        for rect in rects.map({ $0.standardized }) where isUsable(rect) {
            if !output.contains(where: { approximatelyEqual($0, rect) }) {
                output.append(rect)
            }
        }
        return output
    }

    private nonisolated static func appKitRect(
        fromQuartzRect rect: CGRect,
        referenceTop: CGFloat
    ) -> CGRect {
        let rect = rect.standardized
        return CGRect(
            x: rect.minX,
            y: referenceTop - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    private nonisolated static func isUsable(_ rect: CGRect) -> Bool {
        [rect.origin.x, rect.origin.y, rect.width, rect.height].allSatisfy(\.isFinite)
            && !rect.isNull
            && rect.width >= 24
            && rect.height >= 24
    }

    private nonisolated static func area(_ rect: CGRect) -> CGFloat {
        max(0, rect.width) * max(0, rect.height)
    }

    /// Returns `true` only when the candidate covers virtually the entire
    /// focused-window frame and all four edges align. The edge check keeps a
    /// legitimate web viewport that merely occupies most of a window from
    /// being mistaken for a window-level pseudo region.
    private nonisolated static func isNearWholeWindow(
        _ candidate: CGRect,
        focusedFrame: CGRect
    ) -> Bool {
        let candidate = candidate.standardized
        let focusedFrame = focusedFrame.standardized
        let focusedArea = area(focusedFrame)
        guard focusedArea > 0,
              area(candidate) / focusedArea >= 0.985 else {
            return false
        }

        let horizontalTolerance = max(4, focusedFrame.width * 0.005)
        let verticalTolerance = max(4, focusedFrame.height * 0.005)
        return abs(candidate.minX - focusedFrame.minX) <= horizontalTolerance
            && abs(candidate.maxX - focusedFrame.maxX) <= horizontalTolerance
            && abs(candidate.minY - focusedFrame.minY) <= verticalTolerance
            && abs(candidate.maxY - focusedFrame.maxY) <= verticalTolerance
    }

    private nonisolated static func approximatelyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        let tolerance: CGFloat = 0.5
        return abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }

    // MARK: - Live providers

    private static func captureWindowSnapshots() -> [ScrollCaptureWindowSnapshot] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let rawWindows = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
            as? [[String: Any]] else {
            return []
        }

        return rawWindows.compactMap { info in
            guard let ownerNumber = info[kCGWindowOwnerPID as String] as? NSNumber,
                  let windowNumber = info[kCGWindowNumber as String] as? NSNumber,
                  let rawBounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(
                      dictionaryRepresentation: rawBounds as CFDictionary
                  ) else {
                return nil
            }

            let ownerPID = ownerNumber.int32Value
            let application = NSRunningApplication(processIdentifier: ownerPID)
            let isActivatable = application?.isTerminated == false
                && application?.activationPolicy != .prohibited
            return ScrollCaptureWindowSnapshot(
                ownerPID: ownerPID,
                windowID: CGWindowID(windowNumber.uint32Value),
                quartzFrame: frame,
                layer: (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
                alpha: (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1,
                title: info[kCGWindowName as String] as? String,
                isActivatable: isActivatable
            )
        }
    }

    private nonisolated static func captureAccessibilitySnapshot(
        ownerPID: pid_t,
        maximumDepth: Int,
        hitTestQuartzPoint: CGPoint?
    ) -> ScrollCaptureAccessibilitySnapshot? {
        // Cross-app AX hierarchy inspection is not an App Sandbox capability.
        // A signed Mac App Store build therefore fails closed to the existing
        // WindowServer whole-window preselection instead of attempting a
        // restricted API or requesting a temporary exception.
        guard !isAppSandboxEnabled else { return nil }
        // Read the current TCC state only. Never request or prompt from an
        // automatic capture path.
        guard AXIsProcessTrusted() else { return nil }

        let application = AXUIElementCreateApplication(ownerPID)
        // AX calls are synchronous. Bound every request and the traversal so
        // an unresponsive target process cannot freeze PEEK's main actor
        // indefinitely. This only configures the ephemeral client element and
        // never changes the target app or its permissions.
        AXUIElementSetMessagingTimeout(application, 0.20)
        guard let focusedWindow = axElement(
            application,
            attribute: kAXFocusedWindowAttribute as CFString
        ), let windowFrame = axFrame(focusedWindow) else {
            return nil
        }

        let resolvedHitTestPoint = hitTestQuartzPoint.flatMap {
            windowFrame.standardized.contains($0) ? $0 : nil
        }
        let hoveredRegion = resolvedHitTestPoint.flatMap {
            hoveredScrollRegion(
                application: application,
                at: $0,
                focusedWindowFrame: windowFrame,
                maximumDepth: max(0, maximumDepth)
            )
        }

        var regions: [ScrollCaptureAccessibilityRegion] = []
        var visitedNodes = 0
        let traversalDeadline = ProcessInfo.processInfo.systemUptime + 0.45
        collectScrollRegions(
            in: focusedWindow,
            depth: 0,
            maximumDepth: max(0, maximumDepth),
            maximumNodes: 240,
            deadline: traversalDeadline,
            visitedNodes: &visitedNodes,
            output: &regions
        )

        return ScrollCaptureAccessibilitySnapshot(
            ownerPID: ownerPID,
            focusedWindowQuartzFrame: windowFrame,
            focusedWindowTitle: axString(
                focusedWindow,
                attribute: kAXTitleAttribute as CFString
            ),
            scrollRegions: regions,
            hoveredScrollRegion: hoveredRegion,
            // Once the pointer is known to be inside this focused window, a
            // failed/empty AX hit must fall back to the whole window. Letting
            // the area heuristic run here can select an unrelated iframe or
            // scroll view elsewhere in the same app.
            didHitTestFocusedWindow: resolvedHitTestPoint != nil
        )
    }

    private nonisolated static let isAppSandboxEnabled: Bool = {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(
                task,
                "com.apple.security.app-sandbox" as CFString,
                nil
              ) else {
            return false
        }
        return (value as? Bool) == true
    }()

    /// Directly hit-tests the pointer in the target process and walks the AX
    /// parent chain from the deepest element outward. The first scrolling role
    /// is the visual preselection the user most likely intended.
    private nonisolated static func hoveredScrollRegion(
        application: AXUIElement,
        at quartzPoint: CGPoint,
        focusedWindowFrame: CGRect,
        maximumDepth: Int
    ) -> ScrollCaptureAccessibilityRegion? {
        var applicationPID: pid_t = 0
        guard AXUIElementGetPid(application, &applicationPID) == .success else {
            return nil
        }
        var rawElement: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            application,
            Float(quartzPoint.x),
            Float(quartzPoint.y),
            &rawElement
        ) == .success,
        let rawElement else {
            return nil
        }

        var element: AXUIElement? = configuredAXElement(rawElement)
        let parentLimit = max(8, maximumDepth + 8)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.45
        for depthFromHit in 0 ..< parentLimit {
            guard ProcessInfo.processInfo.systemUptime < deadline,
                  let current = element else { break }
            var elementPID: pid_t = 0
            guard AXUIElementGetPid(current, &elementPID) == .success,
                  elementPID == applicationPID else {
                break
            }
            if let role = axString(current, attribute: kAXRoleAttribute as CFString),
               let frame = axFrame(current),
               focusedWindowFrame.standardized.intersects(frame.standardized),
               frame.standardized.contains(quartzPoint) {
                let regionRole: ScrollCaptureAccessibilityRole?
                switch role {
                case String(kAXScrollAreaRole):
                    regionRole = .scrollArea
                case "AXWebArea":
                    regionRole = .webArea
                default:
                    regionRole = nil
                }
                if let regionRole {
                    return ScrollCaptureAccessibilityRegion(
                        quartzFrame: frame,
                        role: regionRole,
                        depth: depthFromHit,
                        isVisible: !(axBoolean(
                            current,
                            attribute: kAXHiddenAttribute as CFString
                        ) ?? false),
                        wasPointerHitTested: true
                    )
                }
            }
            element = axElement(current, attribute: kAXParentAttribute as CFString)
        }
        return nil
    }

    private nonisolated static func collectScrollRegions(
        in element: AXUIElement,
        depth: Int,
        maximumDepth: Int,
        maximumNodes: Int,
        deadline: TimeInterval,
        visitedNodes: inout Int,
        output: inout [ScrollCaptureAccessibilityRegion]
    ) {
        guard depth <= maximumDepth,
              visitedNodes < maximumNodes,
              ProcessInfo.processInfo.systemUptime < deadline else {
            return
        }
        visitedNodes += 1

        let hidden = axBoolean(element, attribute: kAXHiddenAttribute as CFString) ?? false
        if !hidden,
           let role = axString(element, attribute: kAXRoleAttribute as CFString),
           let frame = axFrame(element) {
            let regionRole: ScrollCaptureAccessibilityRole?
            switch role {
            case String(kAXScrollAreaRole):
                regionRole = .scrollArea
            case "AXWebArea":
                regionRole = .webArea
            default:
                regionRole = nil
            }
            if let regionRole {
                output.append(
                    ScrollCaptureAccessibilityRegion(
                        quartzFrame: frame,
                        role: regionRole,
                        depth: depth,
                        isVisible: true
                    )
                )
            }
        }

        guard depth < maximumDepth else { return }
        for child in axChildren(element).prefix(60) {
            guard ProcessInfo.processInfo.systemUptime < deadline else { break }
            collectScrollRegions(
                in: child,
                depth: depth + 1,
                maximumDepth: maximumDepth,
                maximumNodes: maximumNodes,
                deadline: deadline,
                visitedNodes: &visitedNodes,
                output: &output
            )
            if visitedNodes >= maximumNodes { break }
        }
    }

    private nonisolated static func axElement(
        _ element: AXUIElement,
        attribute: CFString
    ) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return configuredAXElement(value)
    }

    private nonisolated static func axChildren(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &value
        ) == .success,
        let values = value as? [Any] else {
            return []
        }
        return values.compactMap { value in
            guard CFGetTypeID(value as CFTypeRef) == AXUIElementGetTypeID() else {
                return nil
            }
            return configuredAXElement(value as CFTypeRef)
        }
    }

    /// AX messaging timeouts are scoped to the exact element object and are
    /// not inherited by focused windows or descendants returned from another
    /// query. Configure every element before issuing any follow-up reads.
    private nonisolated static func configuredAXElement(_ value: CFTypeRef) -> AXUIElement {
        let element = unsafeBitCast(value, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, 0.20)
        return element
    }

    private nonisolated static func axFrame(_ element: AXUIElement) -> CGRect? {
        guard let position: CGPoint = axValue(
            element,
            attribute: kAXPositionAttribute as CFString,
            type: .cgPoint
        ), let size: CGSize = axValue(
            element,
            attribute: kAXSizeAttribute as CFString,
            type: .cgSize
        ) else {
            return nil
        }
        let frame = CGRect(origin: position, size: size).standardized
        return [frame.origin.x, frame.origin.y, frame.width, frame.height]
            .allSatisfy(\.isFinite) ? frame : nil
    }

    private nonisolated static func axValue<T>(
        _ element: AXUIElement,
        attribute: CFString,
        type: AXValueType
    ) -> T? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &rawValue) == .success,
              let rawValue,
              CFGetTypeID(rawValue) == AXValueGetTypeID() else {
            return nil
        }
        let value = unsafeBitCast(rawValue, to: AXValue.self)
        let result = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { result.deallocate() }
        guard AXValueGetValue(value, type, result) else { return nil }
        return result.move()
    }

    private nonisolated static func axString(
        _ element: AXUIElement,
        attribute: CFString
    ) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private nonisolated static func axBoolean(
        _ element: AXUIElement,
        attribute: CFString
    ) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return (value as? NSNumber)?.boolValue
    }
}
