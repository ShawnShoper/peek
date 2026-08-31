import ApplicationServices
import CoreGraphics
import Foundation

/// A normalized, read-only view of a native vertical scrollbar. Values are
/// deliberately kept independent of AXUIElement so they can cross actor and
/// test boundaries safely.
struct ScrollPositionSnapshot: Equatable, Sendable {
    enum Source: String, Equatable, Sendable {
        case accessibilityScrollBar
    }

    let value: Double
    let minimum: Double
    let maximum: Double
    let source: Source

    init?(
        value: Double,
        minimum: Double,
        maximum: Double,
        source: Source = .accessibilityScrollBar
    ) {
        guard value.isFinite,
              minimum.isFinite,
              maximum.isFinite,
              maximum > minimum else {
            return nil
        }
        self.value = min(max(value, minimum), maximum)
        self.minimum = minimum
        self.maximum = maximum
        self.source = source
    }

    var progress: Double {
        (value - minimum) / (maximum - minimum)
    }

    var remainingProgress: Double {
        max(0, 1 - progress)
    }

    /// AX scrollbar values are commonly normalized to 0...1, but some native
    /// controls use a different range. A range-relative tolerance works for
    /// both and avoids waiting forever on floating-point rounding at the end.
    var isAtEnd: Bool {
        let tolerance = max((maximum - minimum) * 0.002, 0.000_1)
        return maximum - value <= tolerance
    }
}

protocol ScrollPositionProbing: Sendable {
    func snapshot() async -> ScrollPositionSnapshot?
}

/// Chooses a conservative wheel transaction size. The configured amount is a
/// ceiling, never a promise that the target will consume that many pixels.
/// Without an authoritative position, consecutive no-movement transactions
/// are retried at 1/2 then 1/4 size before the session declares the end.
enum AdaptiveScrollStepPlanner {
    static func amount(
        configuredAmount: Int32,
        viewportHeight _: CGFloat,
        position: ScrollPositionSnapshot?,
        consecutiveNoMovementTransactions: Int
    ) -> Int32 {
        guard configuredAmount > 0 else { return 0 }
        if position?.isAtEnd == true { return 0 }

        // The service has already bounded the configured amount to the safe
        // viewport ratio. Preserve that public configuration contract here;
        // this planner only contracts a transaction when end evidence grows.
        let base = configuredAmount
        var divisor: Int32 = 1

        if let position {
            if position.remainingProgress <= 0.02 {
                divisor = 4
            } else if position.remainingProgress <= 0.08 {
                divisor = 2
            }
        } else if consecutiveNoMovementTransactions >= 2 {
            divisor = 4
        } else if consecutiveNoMovementTransactions == 1 {
            divisor = 2
        }

        return max(1, base / divisor)
    }
}

/// Best-effort native position probe. It is intentionally read-only: changing
/// AXValue directly is not portable because apps expose different units and
/// write semantics. PEEK still delivers the public wheel event, then uses this
/// snapshot as authoritative progress/end evidence when the target exposes it.
///
/// Cross-process AX inspection is unavailable to an App Sandbox build. In that
/// distribution mode this probe returns nil immediately and the capture
/// session uses its bounded visual fallback instead of requesting a private or
/// temporary entitlement.
struct AXScrollPositionProbe: ScrollPositionProbing {
    private let ownerPID: pid_t
    private let quartzPoint: CGPoint
    private let timeoutNanoseconds: UInt64

    init(
        ownerPID: pid_t,
        quartzPoint: CGPoint,
        timeoutNanoseconds: UInt64 = 350_000_000
    ) {
        self.ownerPID = ownerPID
        self.quartzPoint = quartzPoint
        self.timeoutNanoseconds = max(50_000_000, timeoutNanoseconds)
    }

    func snapshot() async -> ScrollPositionSnapshot? {
        guard ScrollCaptureRuntimeCapabilities.current
              .supportsCrossProcessAccessibilityInspection,
              ownerPID > 0,
              quartzPoint.x.isFinite,
              quartzPoint.y.isFinite else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            let race = ScrollPositionProbeRace(continuation: continuation)
            Task.detached(priority: .utility) {
                let result = Self.readSnapshot(
                    ownerPID: ownerPID,
                    quartzPoint: quartzPoint
                )
                await race.finish(result)
            }
            Task.detached(priority: .utility) {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                await race.finish(nil)
            }
        }
    }

    private static func readSnapshot(
        ownerPID: pid_t,
        quartzPoint: CGPoint
    ) -> ScrollPositionSnapshot? {
        let application = configured(AXUIElementCreateApplication(ownerPID))
        var rawHit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            application,
            Float(quartzPoint.x),
            Float(quartzPoint.y),
            &rawHit
        ) == .success,
        let rawHit else {
            return nil
        }

        var current: AXUIElement? = configured(rawHit)
        for _ in 0 ..< 16 {
            guard let element = current else { break }
            if let scrollbar = verticalScrollBar(for: element),
               let snapshot = scrollBarSnapshot(scrollbar) {
                return snapshot
            }
            current = axElement(element, attribute: kAXParentAttribute as CFString)
        }
        return nil
    }

    private static func verticalScrollBar(for element: AXUIElement) -> AXUIElement? {
        if axString(element, attribute: kAXRoleAttribute as CFString)
            == String(kAXScrollBarRole),
           isVertical(element) {
            return element
        }

        if let direct = axElement(
            element,
            attribute: kAXVerticalScrollBarAttribute as CFString
        ) {
            return direct
        }

        // A few custom views expose their scrollbar only as a child. Keep the
        // search shallow and bounded so a slow target can never stall capture.
        for child in axChildren(element).prefix(24) {
            if axString(child, attribute: kAXRoleAttribute as CFString)
                == String(kAXScrollBarRole),
               isVertical(child) {
                return child
            }
        }
        return nil
    }

    private static func scrollBarSnapshot(
        _ scrollBar: AXUIElement
    ) -> ScrollPositionSnapshot? {
        guard axBoolean(scrollBar, attribute: kAXEnabledAttribute as CFString) != false,
              let value = axNumber(scrollBar, attribute: kAXValueAttribute as CFString) else {
            return nil
        }
        let minimum = axNumber(scrollBar, attribute: kAXMinValueAttribute as CFString) ?? 0
        let maximum = axNumber(scrollBar, attribute: kAXMaxValueAttribute as CFString) ?? 1
        return ScrollPositionSnapshot(
            value: value,
            minimum: minimum,
            maximum: maximum
        )
    }

    private static func isVertical(_ element: AXUIElement) -> Bool {
        guard let orientation = axString(
            element,
            attribute: kAXOrientationAttribute as CFString
        ) else {
            return true
        }
        return orientation == String(kAXVerticalOrientationValue)
    }

    private static func axElement(
        _ element: AXUIElement,
        attribute: CFString
    ) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return configured(unsafeBitCast(value, to: AXUIElement.self))
    }

    private static func axChildren(_ element: AXUIElement) -> [AXUIElement] {
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
            let raw = value as CFTypeRef
            guard CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
            return configured(unsafeBitCast(raw, to: AXUIElement.self))
        }
    }

    private static func axString(
        _ element: AXUIElement,
        attribute: CFString
    ) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private static func axNumber(
        _ element: AXUIElement,
        attribute: CFString
    ) -> Double? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return (value as? NSNumber)?.doubleValue
    }

    private static func axBoolean(
        _ element: AXUIElement,
        attribute: CFString
    ) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return (value as? NSNumber)?.boolValue
    }

    private static func configured(_ element: AXUIElement) -> AXUIElement {
        AXUIElementSetMessagingTimeout(element, 0.15)
        return element
    }

}

private actor ScrollPositionProbeRace {
    private var continuation: CheckedContinuation<ScrollPositionSnapshot?, Never>?

    init(continuation: CheckedContinuation<ScrollPositionSnapshot?, Never>) {
        self.continuation = continuation
    }

    func finish(_ value: ScrollPositionSnapshot?) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: value)
    }
}
