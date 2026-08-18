import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

protocol AutomaticScrollDriving: Sendable {
    var hasAccessibilityPermission: Bool { get }
    func scroll(at globalPoint: CGPoint, amount: Int32) async throws
}

/// Stable WindowServer identity used to keep automatic scrolling attached to
/// the exact window selected by the user. Every value uses Quartz global
/// coordinates (origin at the upper-left of the primary display).
struct ScrollCaptureWindowAnchor: Equatable, Sendable {
    let ownerPID: pid_t
    let windowID: CGWindowID
    let quartzFrame: CGRect

    init(ownerPID: pid_t, windowID: CGWindowID, quartzFrame: CGRect) {
        self.ownerPID = ownerPID
        self.windowID = windowID
        self.quartzFrame = quartzFrame.standardized
    }
}

/// Pure validation shared by the service preflight and the guarded live
/// driver. Window snapshots must retain WindowServer front-to-back order.
enum ScrollCaptureWindowAnchorValidator {
    private static let frameTolerance: CGFloat = 2
    private static let minimumSelectionCoverage: CGFloat = 0.98

    static func validate(
        anchor: ScrollCaptureWindowAnchor,
        selectionQuartzRect: CGRect,
        scrollPoint: CGPoint,
        currentPID: pid_t,
        frontmostPID: pid_t?,
        windowSnapshots: [ScrollCaptureWindowSnapshot]
    ) throws {
        let selection = selectionQuartzRect.standardized
        guard anchor.windowID != 0,
              anchor.ownerPID != currentPID,
              isUsable(anchor.quartzFrame),
              isUsable(selection),
              [scrollPoint.x, scrollPoint.y].allSatisfy(\.isFinite),
              frontmostPID == anchor.ownerPID else {
            throw ScrollCaptureError.scrollTargetChanged
        }

        let eligibleWindows = windowSnapshots.filter {
            $0.ownerPID != currentPID
                && $0.windowID != 0
                && $0.layer == 0
                && $0.alpha > 0.01
                && $0.isActivatable
                && isUsable($0.quartzFrame)
        }
        guard let live = eligibleWindows.first(where: {
            $0.ownerPID == anchor.ownerPID && $0.windowID == anchor.windowID
        }), framesApproximatelyEqual(live.quartzFrame, anchor.quartzFrame),
        live.quartzFrame.standardized.contains(scrollPoint) else {
            throw ScrollCaptureError.scrollTargetChanged
        }

        let selectionArea = area(selection)
        let coveredArea = area(selection.intersection(live.quartzFrame.standardized))
        guard selectionArea > 0,
              coveredArea / selectionArea >= minimumSelectionCoverage,
              let topWindowAtPoint = eligibleWindows.first(where: {
                  $0.quartzFrame.standardized.contains(scrollPoint)
              }),
              topWindowAtPoint.ownerPID == anchor.ownerPID,
              topWindowAtPoint.windowID == anchor.windowID else {
            throw ScrollCaptureError.scrollTargetChanged
        }
    }

    private static func framesApproximatelyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        let lhs = lhs.standardized
        let rhs = rhs.standardized
        return abs(lhs.minX - rhs.minX) <= frameTolerance
            && abs(lhs.minY - rhs.minY) <= frameTolerance
            && abs(lhs.width - rhs.width) <= frameTolerance
            && abs(lhs.height - rhs.height) <= frameTolerance
    }

    private static func isUsable(_ rect: CGRect) -> Bool {
        [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite)
            && !rect.isNull
            && rect.width >= 1
            && rect.height >= 1
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        guard !rect.isNull else { return 0 }
        return max(0, rect.width) * max(0, rect.height)
    }
}

enum AccessibilityScrollPermission {
    static var isGranted: Bool {
        CGPreflightPostEventAccess()
    }

    /// Requests the public Post Event privilege used by CGEvent. This remains
    /// available to App Sandbox builds and is intentionally separate from
    /// cross-app AX hierarchy inspection, which may be unavailable there.
    @discardableResult
    static func request() -> Bool {
        CGRequestPostEventAccess()
    }
}

struct QuartzAutomaticScrollDriver: AutomaticScrollDriving {
    private let anchor: ScrollCaptureWindowAnchor?
    private let selectionQuartzRect: CGRect?
    private let currentPID: pid_t

    init(
        anchor: ScrollCaptureWindowAnchor? = nil,
        selectionQuartzRect: CGRect? = nil,
        currentPID: pid_t = ProcessInfo.processInfo.processIdentifier
    ) {
        self.anchor = anchor
        self.selectionQuartzRect = selectionQuartzRect?.standardized
        self.currentPID = currentPID
    }

    var hasAccessibilityPermission: Bool {
        AccessibilityScrollPermission.isGranted
    }

    func scroll(at globalPoint: CGPoint, amount: Int32) async throws {
        try await MainActor.run {
            guard hasAccessibilityPermission else {
                throw ScrollCaptureError.accessibilityPermissionDenied
            }
            guard amount > 0,
                  let anchor,
                  let selectionQuartzRect else {
                throw ScrollCaptureError.invalidConfiguration(L10n.tr("无法确认自动滚动目标窗口"))
            }

            try ScrollCaptureWindowAnchorValidator.validate(
                anchor: anchor,
                selectionQuartzRect: selectionQuartzRect,
                scrollPoint: globalPoint,
                currentPID: currentPID,
                frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                windowSnapshots: Self.captureWindowSnapshots()
            )

            guard let source = CGEventSource(stateID: .combinedSessionState),
                  let event = CGEvent(
                      scrollWheelEvent2Source: source,
                      units: .pixel,
                      wheelCount: 1,
                      wheel1: -amount,
                      wheel2: 0,
                      wheel3: 0
                  ) else {
                throw ScrollCaptureError.captureFailed
            }

            event.location = globalPoint
            event.post(tap: .cghidEventTap)
        }
    }

    @MainActor
    static func captureWindowSnapshots() -> [ScrollCaptureWindowSnapshot] {
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
            return ScrollCaptureWindowSnapshot(
                ownerPID: ownerPID,
                windowID: CGWindowID(windowNumber.uint32Value),
                quartzFrame: frame,
                layer: (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
                alpha: (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1,
                title: info[kCGWindowName as String] as? String,
                isActivatable: application?.isTerminated == false
                    && application?.activationPolicy != .prohibited
            )
        }
    }
}
