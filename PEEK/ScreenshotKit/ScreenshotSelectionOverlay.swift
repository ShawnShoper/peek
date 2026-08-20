import AppKit
import Foundation

struct ScreenshotPixelColor: Equatable, Sendable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8

    var hexString: String {
        String(format: "#%02X%02X%02X", red, green, blue)
    }

    var rgbString: String {
        "RGB(\(red), \(green), \(blue))"
    }

    var clipboardString: String {
        "\(rgbString)  \(hexString)"
    }

    init?(color: NSColor) {
        guard let converted = color.usingColorSpace(.sRGB) else { return nil }
        red = UInt8(clamping: Int((converted.redComponent * 255).rounded()))
        green = UInt8(clamping: Int((converted.greenComponent * 255).rounded()))
        blue = UInt8(clamping: Int((converted.blueComponent * 255).rounded()))
    }
}

struct ScreenshotPixelCoordinate: Equatable, Sendable {
    let x: Int
    let y: Int
}

func screenshotPixelCoordinate(
    at appKitPoint: CGPoint,
    screenFrame: CGRect,
    pixelWidth: Int,
    pixelHeight: Int
) -> ScreenshotPixelCoordinate? {
    guard pixelWidth > 0,
          pixelHeight > 0,
          screenFrame.width > 0,
          screenFrame.height > 0,
          appKitPoint.x >= screenFrame.minX,
          appKitPoint.x <= screenFrame.maxX,
          appKitPoint.y >= screenFrame.minY,
          appKitPoint.y <= screenFrame.maxY else {
        return nil
    }

    let scaleX = CGFloat(pixelWidth) / screenFrame.width
    let scaleY = CGFloat(pixelHeight) / screenFrame.height
    let x = Int(floor((appKitPoint.x - screenFrame.minX) * scaleX))
    // CGDisplayCreateImage stores its first row at the visual top of the
    // display, while AppKit's global screen coordinates start at the bottom.
    let y = Int(floor((screenFrame.maxY - appKitPoint.y) * scaleY))
    return ScreenshotPixelCoordinate(
        x: min(max(0, x), pixelWidth - 1),
        y: min(max(0, y), pixelHeight - 1)
    )
}

func screenshotSelectionGestureIsDrag(
    from start: CGPoint,
    to current: CGPoint,
    threshold: CGFloat = 4
) -> Bool {
    hypot(current.x - start.x, current.y - start.y) >= threshold
}

func screenshotConstrainedSelectionMove(
    original: CGRect,
    translation: CGSize,
    screenFrame: CGRect
) -> CGRect {
    let original = original.standardized
    let screenFrame = screenFrame.standardized
    var origin = CGPoint(
        x: original.minX + translation.width,
        y: original.minY + translation.height
    )
    if original.width <= screenFrame.width {
        origin.x = min(
            max(origin.x, screenFrame.minX),
            screenFrame.maxX - original.width
        )
    }
    if original.height <= screenFrame.height {
        origin.y = min(
            max(origin.y, screenFrame.minY),
            screenFrame.maxY - original.height
        )
    }
    return CGRect(origin: origin, size: original.size)
}

enum ScreenshotResizeHandle: CaseIterable {
    case northWest
    case north
    case northEast
    case east
    case southEast
    case south
    case southWest
    case west
}

/// Validates an optional initial selection without requiring a live desktop
/// capture. A valid selection must be finite, large enough to confirm, fully
/// inside the desktop, and fully contained by one physical display.
func validatedInitialScreenshotSelection(
    _ rawRect: CGRect?,
    desktopBounds: CGRect,
    screenFrames: [CGRect]
) -> CGRect? {
    guard let rawRect else { return nil }

    let coordinates = [
        rawRect.origin.x,
        rawRect.origin.y,
        rawRect.size.width,
        rawRect.size.height
    ]
    guard coordinates.allSatisfy(\.isFinite) else { return nil }

    let rect = rawRect.standardized
    let minimumSize = CGSize(width: 8, height: 8)
    guard rect.width >= minimumSize.width,
          rect.height >= minimumSize.height,
          desktopBounds.contains(rect),
          screenFrames.contains(where: { $0.contains(rect) }) else {
        return nil
    }
    return rect
}

/// Resolves the frozen hover map without touching TCC or Accessibility. The
/// smallest containing scrolling rectangle represents the innermost exposed
/// AX container; a point elsewhere in the anchored window selects the window.
func automaticHoverScreenshotSelection(
    at point: CGPoint,
    windowRect: CGRect?,
    regionRects: [CGRect]
) -> CGRect? {
    guard let windowRect = windowRect?.standardized,
          windowRect.contains(point) else {
        return nil
    }
    return regionRects
        .map(\.standardized)
        .filter { $0.contains(point) }
        .min { lhs, rhs in
            let lhsArea = lhs.width * lhs.height
            let rhsArea = rhs.width * rhs.height
            return lhsArea == rhsArea ? lhs.width < rhs.width : lhsArea < rhsArea
        }
        ?? windowRect
}

@MainActor
final class ScreenshotSelectionModel {
    private enum DragOperation {
        case pendingCreate(start: CGPoint, candidate: CGRect?)
        case create(start: CGPoint, candidate: CGRect?)
        case move(start: CGPoint, original: CGRect)
        case resize(handle: ScreenshotResizeHandle, original: CGRect)
    }

    let desktop: ScreenshotDesktopGeometry
    var onChange: (() -> Void)?
    var onSelectionReady: ((CGRect) -> Void)?
    var onFinish: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private(set) var selectionRect: CGRect?
    private(set) var selectionHint: String?
    private(set) var hoveredWindowRect: CGRect?
    private(set) var pointerLocation: CGPoint?
    private(set) var didModifyInitialSelection = false
    private(set) var isEditing = false
    private let hadInitialSelection: Bool
    private let automaticHoverWindowRect: CGRect?
    private let automaticHoverSelectionRects: [CGRect]
    private var automaticHoverSelectionEnabled: Bool
    private var dragOperation: DragOperation?

    private static let minimumSelectionSize = CGSize(width: 8, height: 8)
    private let handleHitRadius: CGFloat = 9

    init(
        desktop: ScreenshotDesktopGeometry,
        initialSelectionRect: CGRect? = nil,
        initialSelectionHint: String? = nil,
        automaticHoverWindowRect: CGRect? = nil,
        automaticHoverSelectionRects: [CGRect] = []
    ) {
        self.desktop = desktop
        let validatedInitialSelection = validatedInitialScreenshotSelection(
            initialSelectionRect,
            desktopBounds: desktop.desktopBounds,
            screenFrames: desktop.displays.map(\.screenFrame)
        )
        selectionRect = validatedInitialSelection
        hadInitialSelection = validatedInitialSelection != nil
        self.automaticHoverWindowRect = validatedInitialScreenshotSelection(
            automaticHoverWindowRect,
            desktopBounds: desktop.desktopBounds,
            screenFrames: desktop.displays.map(\.screenFrame)
        )
        self.automaticHoverSelectionRects = automaticHoverSelectionRects.compactMap {
            validatedInitialScreenshotSelection(
                $0,
                desktopBounds: desktop.desktopBounds,
                screenFrames: desktop.displays.map(\.screenFrame)
            )
        }
        automaticHoverSelectionEnabled = self.automaticHoverWindowRect != nil
        if selectionRect != nil,
           let hint = initialSelectionHint?.trimmingCharacters(in: .whitespacesAndNewlines),
           !hint.isEmpty {
            selectionHint = hint
        }
    }

    func updatePointer(_ point: CGPoint) {
        guard !isEditing else { return }
        pointerLocation = point
        guard dragOperation == nil else {
            onChange?()
            return
        }

        if automaticHoverSelectionEnabled,
           let automaticHoverWindowRect {
            if let hoverSelection = automaticHoverScreenshotSelection(
                at: point,
                windowRect: automaticHoverWindowRect,
                regionRects: automaticHoverSelectionRects
            ) {
                selectionRect = hoverSelection
                selectionHint = hoverSelection == automaticHoverWindowRect
                    ? L10n.tr("已预选当前窗口 · 拖动可自定义选区")
                    : L10n.tr("已定位鼠标所在滚动区域 · 拖动可自定义选区")
                hoveredWindowRect = nil
                onChange?()
                return
            }

            // Outside the anchored window, return to the ordinary frozen
            // desktop window hover behavior. Moving back into the window will
            // resume AX region/whole-window following until the user edits.
            selectionRect = nil
            selectionHint = nil
        }

        if let selectionRect, selectionRect.contains(point) {
            hoveredWindowRect = nil
        } else {
            hoveredWindowRect = desktop.windowCandidate(at: point)?.frame
        }
        onChange?()
    }

    func pointerExited() {
        guard !isEditing else { return }
        guard dragOperation == nil else { return }
        pointerLocation = nil
        hoveredWindowRect = nil
        onChange?()
    }

    func mouseDown(at point: CGPoint, clickCount: Int) {
        guard !isEditing else { return }
        pointerLocation = point

        if clickCount >= 2 {
            if let selectionRect {
                finish(selectionRect)
            } else if let hoveredWindowRect {
                selectionRect = hoveredWindowRect
                finish(hoveredWindowRect)
            }
            return
        }

        if let selectionRect {
            if let handle = resizeHandle(at: point, in: selectionRect) {
                disableAutomaticHoverSelection()
                selectionHint = nil
                dragOperation = .resize(handle: handle, original: selectionRect)
                onChange?()
                return
            }
            // An automatic window/AX preselection is only a suggestion. A
            // normal drag anywhere else must immediately draw the user's own
            // rectangle, including when the suggested rect fills the window.
            // Handles remain directly resizable; after the first custom edit,
            // dragging inside the resulting rect moves it as usual.
            if automaticHoverSelectionEnabled {
                let candidate = selectionRect
                dragOperation = .pendingCreate(start: point, candidate: candidate)
                onChange?()
                return
            }
            if selectionRect.contains(point) {
                disableAutomaticHoverSelection()
                selectionHint = nil
                dragOperation = .move(start: point, original: selectionRect)
                onChange?()
                return
            }
        }

        dragOperation = .pendingCreate(start: point, candidate: hoveredWindowRect)
        onChange?()
    }

    func mouseDragged(to point: CGPoint) {
        guard !isEditing else { return }
        pointerLocation = point
        guard let dragOperation else { return }
        switch dragOperation {
        case let .pendingCreate(start, candidate):
            guard screenshotSelectionGestureIsDrag(from: start, to: point) else {
                onChange?()
                return
            }
            disableAutomaticHoverSelection()
            selectionHint = nil
            if hadInitialSelection {
                didModifyInitialSelection = true
            }
            self.dragOperation = .create(start: start, candidate: candidate)
            selectionRect = normalizedRect(from: start, to: point)
                .intersection(desktop.desktopBounds)
            hoveredWindowRect = nil

        case let .create(start, _):
            selectionHint = nil
            if hadInitialSelection {
                didModifyInitialSelection = true
            }
            selectionRect = normalizedRect(from: start, to: point)
                .intersection(desktop.desktopBounds)

        case let .move(start, original):
            selectionHint = nil
            if hadInitialSelection {
                didModifyInitialSelection = true
            }
            let proposed = original.offsetBy(
                dx: point.x - start.x,
                dy: point.y - start.y
            )
            selectionRect = constrainedMove(proposed)

        case let .resize(handle, original):
            selectionHint = nil
            if hadInitialSelection {
                didModifyInitialSelection = true
            }
            selectionRect = resizedRect(original, handle: handle, to: point)
        }
        onChange?()
    }

    @discardableResult
    func mouseUp(at point: CGPoint) -> CGPoint? {
        guard !isEditing else { return nil }
        pointerLocation = point
        guard let dragOperation else { return nil }

        if case .pendingCreate = dragOperation {
            self.dragOperation = nil
            onChange?()
            return point
        }

        if case let .create(_, candidate) = dragOperation,
           let selectionRect,
           selectionRect.width < Self.minimumSelectionSize.width,
           selectionRect.height < Self.minimumSelectionSize.height {
            self.selectionRect = candidate
        }

        self.dragOperation = nil
        if let selectionRect,
           selectionRect.width < Self.minimumSelectionSize.width
            || selectionRect.height < Self.minimumSelectionSize.height {
            self.selectionRect = nil
        }
        if self.selectionRect != nil {
            selectionHint = L10n.tr(
                "拖动选区可移动，拖动边角可缩放"
            )
        }
        onChange?()
        if let selectionRect = self.selectionRect {
            onSelectionReady?(selectionRect)
        }
        return nil
    }

    func nudgeSelection(dx: CGFloat, dy: CGFloat) {
        guard !isEditing else { return }
        guard let selectionRect else { return }
        disableAutomaticHoverSelection()
        selectionHint = L10n.tr(
            "拖动选区可移动，拖动边角可缩放"
        )
        if hadInitialSelection {
            didModifyInitialSelection = true
        }
        self.selectionRect = constrainedMove(selectionRect.offsetBy(dx: dx, dy: dy))
        onChange?()
    }

    func finishCurrentSelection() {
        guard !isEditing else { return }
        if let selectionRect {
            finish(selectionRect)
        } else if let hoveredWindowRect {
            self.selectionRect = hoveredWindowRect
            finish(hoveredWindowRect)
        }
    }

    func cancel() {
        onCancel?()
    }

    func beginEditing() {
        guard selectionRect != nil else { return }
        isEditing = true
        pointerLocation = nil
        hoveredWindowRect = nil
        dragOperation = nil
        onChange?()
    }

    func updateSelectionDuringEditing(_ rect: CGRect) {
        guard applySelectionDuringEditing(rect) else { return }
        didModifyInitialSelection = true
    }

    /// Updates the frozen-desktop cutout while the inline editor is dragging.
    /// This is deliberately not a commit: an unsuccessful final Retina render
    /// can restore the original rectangle without reporting a completed edit.
    func previewSelectionDuringEditing(_ rect: CGRect) {
        _ = applySelectionDuringEditing(rect)
    }

    @discardableResult
    private func applySelectionDuringEditing(_ rect: CGRect) -> Bool {
        guard isEditing else { return false }
        let normalized = rect.standardized.intersection(desktop.desktopBounds)
        guard normalized.width >= Self.minimumSelectionSize.width,
              normalized.height >= Self.minimumSelectionSize.height else {
            return false
        }
        selectionRect = normalized
        onChange?()
        return true
    }

    func resizeHandle(at point: CGPoint, in rect: CGRect) -> ScreenshotResizeHandle? {
        let points: [(ScreenshotResizeHandle, CGPoint)] = [
            (.northWest, CGPoint(x: rect.minX, y: rect.maxY)),
            (.north, CGPoint(x: rect.midX, y: rect.maxY)),
            (.northEast, CGPoint(x: rect.maxX, y: rect.maxY)),
            (.east, CGPoint(x: rect.maxX, y: rect.midY)),
            (.southEast, CGPoint(x: rect.maxX, y: rect.minY)),
            (.south, CGPoint(x: rect.midX, y: rect.minY)),
            (.southWest, CGPoint(x: rect.minX, y: rect.minY)),
            (.west, CGPoint(x: rect.minX, y: rect.midY))
        ]
        return points.first {
            hypot($0.1.x - point.x, $0.1.y - point.y) <= handleHitRadius
        }?.0
    }

    private func finish(_ rect: CGRect) {
        let normalized = rect.standardized.intersection(desktop.desktopBounds)
        guard normalized.width >= Self.minimumSelectionSize.width,
              normalized.height >= Self.minimumSelectionSize.height else {
            return
        }
        onFinish?(normalized)
    }

    private func disableAutomaticHoverSelection() {
        guard automaticHoverSelectionEnabled else { return }
        automaticHoverSelectionEnabled = false
        if hadInitialSelection {
            didModifyInitialSelection = true
        }
    }

    private func normalizedRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    private func constrainedMove(_ proposed: CGRect) -> CGRect {
        var origin = proposed.origin
        let bounds = desktop.desktopBounds

        if proposed.width <= bounds.width {
            origin.x = min(max(origin.x, bounds.minX), bounds.maxX - proposed.width)
        }
        if proposed.height <= bounds.height {
            origin.y = min(max(origin.y, bounds.minY), bounds.maxY - proposed.height)
        }
        return CGRect(origin: origin, size: proposed.size)
    }

    private func resizedRect(
        _ original: CGRect,
        handle: ScreenshotResizeHandle,
        to point: CGPoint
    ) -> CGRect {
        var minX = original.minX
        var maxX = original.maxX
        var minY = original.minY
        var maxY = original.maxY

        switch handle {
        case .northWest:
            minX = point.x
            maxY = point.y
        case .north:
            maxY = point.y
        case .northEast:
            maxX = point.x
            maxY = point.y
        case .east:
            maxX = point.x
        case .southEast:
            maxX = point.x
            minY = point.y
        case .south:
            minY = point.y
        case .southWest:
            minX = point.x
            minY = point.y
        case .west:
            minX = point.x
        }

        let horizontalAnchor = handle == .west || handle == .northWest || handle == .southWest
            ? original.maxX
            : original.minX
        let verticalAnchor = handle == .south || handle == .southEast || handle == .southWest
            ? original.maxY
            : original.minY

        if abs(maxX - minX) < Self.minimumSelectionSize.width {
            if horizontalAnchor == original.maxX {
                minX = maxX - Self.minimumSelectionSize.width
            } else {
                maxX = minX + Self.minimumSelectionSize.width
            }
        }
        if abs(maxY - minY) < Self.minimumSelectionSize.height {
            if verticalAnchor == original.maxY {
                minY = maxY - Self.minimumSelectionSize.height
            } else {
                maxY = minY + Self.minimumSelectionSize.height
            }
        }

        let resized = CGRect(
            x: min(minX, maxX),
            y: min(minY, maxY),
            width: abs(maxX - minX),
            height: abs(maxY - minY)
        )
        return resized.intersection(desktop.desktopBounds)
    }

}

@MainActor
final class ScreenshotSelectionOverlayView: NSView {
    private let display: ScreenshotFrozenDisplay
    private let frozenImage: NSImage
    private let model: ScreenshotSelectionModel
    private var trackingAreaReference: NSTrackingArea?
    private var colorCopyFeedback: String?
    private var colorFeedbackTask: Task<Void, Never>?
    private var cachedPixelSample: PixelSample?

    init(display: ScreenshotFrozenDisplay, model: ScreenshotSelectionModel) {
        self.display = display
        frozenImage = NSImage(
            cgImage: display.image,
            size: display.screenFrame.size
        )
        self.model = model
        super.init(frame: CGRect(origin: .zero, size: display.screenFrame.size))
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaReference = area
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        frozenImage.draw(
            in: bounds,
            from: .zero,
            operation: .copy,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )

        let focusRect = model.selectionRect ?? model.hoveredWindowRect
        drawMask(cutout: focusRect)

        if let selection = model.selectionRect {
            drawSelection(selection)
            if !model.isEditing {
                drawSelectionHint(for: selection)
            }
        } else if let candidate = model.hoveredWindowRect {
            drawCandidate(candidate)
        }
        drawCrosshair()
        drawPixelInspector()
    }

    override func mouseMoved(with event: NSEvent) {
        guard !model.isEditing else { return }
        model.updatePointer(globalPoint(for: event))
    }

    override func mouseExited(with event: NSEvent) {
        guard !model.isEditing else { return }
        model.pointerExited()
    }

    override func mouseDown(with event: NSEvent) {
        guard !model.isEditing else { return }
        window?.makeFirstResponder(self)
        model.mouseDown(at: globalPoint(for: event), clickCount: event.clickCount)
    }

    override func mouseDragged(with event: NSEvent) {
        guard !model.isEditing else { return }
        model.mouseDragged(to: globalPoint(for: event))
    }

    override func mouseUp(with event: NSEvent) {
        guard !model.isEditing else { return }
        if let colorPoint = model.mouseUp(at: globalPoint(for: event)) {
            copyPixelColor(at: colorPoint)
        }
    }

    override func keyDown(with event: NSEvent) {
        if model.isEditing {
            if event.keyCode == 53 {
                model.cancel()
            } else {
                super.keyDown(with: event)
            }
            return
        }
        switch event.keyCode {
        case 53:
            model.cancel()
        case 36, 76:
            model.finishCurrentSelection()
        case 123, 124, 125, 126:
            let distance: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            switch event.keyCode {
            case 123: model.nudgeSelection(dx: -distance, dy: 0)
            case 124: model.nudgeSelection(dx: distance, dy: 0)
            case 125: model.nudgeSelection(dx: 0, dy: -distance)
            default: model.nudgeSelection(dx: 0, dy: distance)
            }
        default:
            super.keyDown(with: event)
        }
    }

    private func globalPoint(for event: NSEvent) -> CGPoint {
        guard let window else { return .zero }
        return window.convertPoint(toScreen: event.locationInWindow)
    }

    private func localRect(for globalRect: CGRect) -> CGRect {
        CGRect(
            x: globalRect.minX - display.screenFrame.minX,
            y: globalRect.minY - display.screenFrame.minY,
            width: globalRect.width,
            height: globalRect.height
        )
    }

    private func localPoint(for globalPoint: CGPoint) -> CGPoint {
        CGPoint(
            x: globalPoint.x - display.screenFrame.minX,
            y: globalPoint.y - display.screenFrame.minY
        )
    }

    private func drawMask(cutout globalRect: CGRect?) {
        let path = NSBezierPath(rect: bounds)
        if let globalRect {
            let intersection = globalRect.intersection(display.screenFrame)
            if !intersection.isNull {
                path.appendRect(localRect(for: intersection))
            }
        }
        path.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.43).setFill()
        path.fill()
    }

    private func drawCandidate(_ globalRect: CGRect) {
        let intersection = globalRect.intersection(display.screenFrame)
        guard !intersection.isNull else { return }
        let path = NSBezierPath(rect: localRect(for: intersection).insetBy(dx: 1, dy: 1))
        path.lineWidth = 2
        NSColor.systemBlue.withAlphaComponent(0.9).setStroke()
        path.stroke()
    }

    private func drawSelection(_ globalRect: CGRect) {
        let intersection = globalRect.intersection(display.screenFrame)
        guard !intersection.isNull else { return }
        let rect = localRect(for: intersection).insetBy(dx: 0.75, dy: 0.75)
        let border = NSBezierPath(rect: rect)
        border.lineWidth = 1.5
        NSColor.systemBlue.setStroke()
        border.stroke()

        if !model.isEditing {
            drawHandles(for: globalRect)
            drawDimensionLabel(for: globalRect)
        }
    }

    private func drawSelectionHint(for globalRect: CGRect) {
        guard let hint = model.selectionHint,
              display.screenFrame.contains(CGPoint(x: globalRect.midX, y: globalRect.midY)) else {
            return
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let measured = hint.size(withAttributes: attributes)
        let bubbleWidth = min(measured.width + 24, max(180, min(bounds.width - 24, 520)))
        let localSelection = localRect(for: globalRect)
        var bubble = CGRect(
            x: localSelection.midX - bubbleWidth / 2,
            y: localSelection.maxY + 10,
            width: bubbleWidth,
            height: measured.height + 12
        )
        if bubble.maxY > bounds.maxY - 8 {
            bubble.origin.y = localSelection.maxY - bubble.height - 10
        }
        bubble.origin.x = min(max(8, bubble.origin.x), max(8, bounds.maxX - bubble.width - 8))

        NSColor.systemBlue.withAlphaComponent(0.94).setFill()
        NSBezierPath(roundedRect: bubble, xRadius: 7, yRadius: 7).fill()
        hint.draw(in: bubble.insetBy(dx: 12, dy: 6), withAttributes: attributes)
    }

    private func drawHandles(for rect: CGRect) {
        let globalPoints = [
            CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.midX, y: rect.maxY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.maxX, y: rect.midY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.midX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.midY)
        ]

        for point in globalPoints where display.screenFrame.insetBy(dx: -3, dy: -3).contains(point) {
            let local = localPoint(for: point)
            let handleRect = CGRect(x: local.x - 3.5, y: local.y - 3.5, width: 7, height: 7)
            NSColor.white.setFill()
            handleRect.fill()
            let border = NSBezierPath(rect: handleRect)
            border.lineWidth = 1
            NSColor.systemBlue.setStroke()
            border.stroke()
        }
    }

    private func drawDimensionLabel(for rect: CGRect) {
        let anchor = CGPoint(x: rect.minX, y: rect.minY)
        guard display.screenFrame.insetBy(dx: -1, dy: -1).contains(anchor) else { return }

        let text = "\(Int(round(rect.width))) × \(Int(round(rect.height)))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = text.size(withAttributes: attributes)
        let localAnchor = localPoint(for: anchor)
        var bubble = CGRect(
            x: localAnchor.x,
            y: localAnchor.y - size.height - 13,
            width: size.width + 14,
            height: size.height + 8
        )
        if bubble.minY < 4 {
            bubble.origin.y = localAnchor.y + 7
        }
        bubble.origin.x = min(max(4, bubble.origin.x), max(4, bounds.maxX - bubble.width - 4))

        NSColor.black.withAlphaComponent(0.78).setFill()
        NSBezierPath(roundedRect: bubble, xRadius: 5, yRadius: 5).fill()
        text.draw(
            at: CGPoint(x: bubble.minX + 7, y: bubble.minY + 4),
            withAttributes: attributes
        )
    }

    private func drawCrosshair() {
        guard model.selectionRect == nil,
              let globalPoint = model.pointerLocation,
              display.screenFrame.contains(globalPoint) else {
            return
        }

        let point = localPoint(for: globalPoint)
        let path = NSBezierPath()
        path.move(to: CGPoint(x: 0, y: point.y))
        path.line(to: CGPoint(x: bounds.maxX, y: point.y))
        path.move(to: CGPoint(x: point.x, y: 0))
        path.line(to: CGPoint(x: point.x, y: bounds.maxY))
        path.lineWidth = 0.75
        path.setLineDash([4, 3], count: 2, phase: 0)
        NSColor.white.withAlphaComponent(0.82).setStroke()
        path.stroke()
    }

    private func drawPixelInspector() {
        guard model.selectionRect == nil,
              let globalPoint = model.pointerLocation,
              display.screenFrame.contains(globalPoint),
              let sample = pixelSample(at: globalPoint) else {
            return
        }

        let localPointer = localPoint(for: globalPoint)
        let panelSize = CGSize(width: 138, height: 166)
        var origin = CGPoint(x: localPointer.x + 18, y: localPointer.y + 18)
        if origin.x + panelSize.width > bounds.maxX - 8 {
            origin.x = localPointer.x - panelSize.width - 18
        }
        if origin.y + panelSize.height > bounds.maxY - 8 {
            origin.y = localPointer.y - panelSize.height - 18
        }
        origin.x = min(max(8, origin.x), max(8, bounds.maxX - panelSize.width - 8))
        origin.y = min(max(8, origin.y), max(8, bounds.maxY - panelSize.height - 8))

        let panelRect = CGRect(origin: origin, size: panelSize)
        NSColor.black.withAlphaComponent(0.90).setFill()
        let background = NSBezierPath(roundedRect: panelRect, xRadius: 10, yRadius: 10)
        background.fill()
        background.lineWidth = 1
        NSColor.white.withAlphaComponent(0.18).setStroke()
        background.stroke()

        let previewRect = CGRect(
            x: panelRect.minX + 9,
            y: panelRect.minY + 41,
            width: panelRect.width - 18,
            height: panelRect.width - 18
        )
        drawMagnifiedPixels(sample: sample, in: previewRect)

        let primaryText = colorCopyFeedback ?? sample.color.hexString
        let primaryAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: colorCopyFeedback == nil
                ? NSColor.white
                : NSColor.systemGreen
        ]
        let secondaryAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.72)
        ]
        let primarySize = primaryText.size(withAttributes: primaryAttributes)
        primaryText.draw(
            at: CGPoint(
                x: panelRect.midX - primarySize.width / 2,
                y: panelRect.minY + 23
            ),
            withAttributes: primaryAttributes
        )
        let rgbSize = sample.color.rgbString.size(withAttributes: secondaryAttributes)
        sample.color.rgbString.draw(
            at: CGPoint(
                x: panelRect.midX - rgbSize.width / 2,
                y: panelRect.minY + 8
            ),
            withAttributes: secondaryAttributes
        )
    }

    private struct PixelSample {
        let coordinate: ScreenshotPixelCoordinate
        let color: ScreenshotPixelColor
    }

    private func pixelSample(at globalPoint: CGPoint) -> PixelSample? {
        guard let coordinate = screenshotPixelCoordinate(
            at: globalPoint,
            screenFrame: display.screenFrame,
            pixelWidth: display.image.width,
            pixelHeight: display.image.height
        ) else {
            return nil
        }
        if let cachedPixelSample,
           cachedPixelSample.coordinate == coordinate {
            return cachedPixelSample
        }
        guard let onePixel = display.image.cropping(
            to: CGRect(x: coordinate.x, y: coordinate.y, width: 1, height: 1)
        ),
        let color = NSBitmapImageRep(cgImage: onePixel).colorAt(x: 0, y: 0),
        let value = ScreenshotPixelColor(color: color) else {
            return nil
        }
        let sample = PixelSample(coordinate: coordinate, color: value)
        cachedPixelSample = sample
        return sample
    }

    private func drawMagnifiedPixels(sample: PixelSample, in rect: CGRect) {
        let radius = 7
        let cropX = max(0, sample.coordinate.x - radius)
        let cropY = max(0, sample.coordinate.y - radius)
        let cropWidth = min(display.image.width - cropX, radius * 2 + 1)
        let cropHeight = min(display.image.height - cropY, radius * 2 + 1)
        guard cropWidth > 0,
              cropHeight > 0,
              let cropped = display.image.cropping(
                to: CGRect(x: cropX, y: cropY, width: cropWidth, height: cropHeight)
              ) else {
            return
        }

        let image = NSImage(
            cgImage: cropped,
            size: CGSize(width: cropWidth, height: cropHeight)
        )
        image.draw(
            in: rect,
            from: .zero,
            operation: .copy,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.none]
        )

        let cellWidth = rect.width / CGFloat(cropWidth)
        let cellHeight = rect.height / CGFloat(cropHeight)
        let selectedColumn = CGFloat(sample.coordinate.x - cropX)
        let selectedRow = CGFloat(sample.coordinate.y - cropY)
        let selectedPixelRect = CGRect(
            x: rect.minX + selectedColumn * cellWidth,
            y: rect.maxY - (selectedRow + 1) * cellHeight,
            width: cellWidth,
            height: cellHeight
        )
        NSColor.white.setStroke()
        let selectedBorder = NSBezierPath(rect: selectedPixelRect.insetBy(dx: 0.35, dy: 0.35))
        selectedBorder.lineWidth = 1.5
        selectedBorder.stroke()

        NSColor.white.withAlphaComponent(0.32).setStroke()
        let previewBorder = NSBezierPath(rect: rect)
        previewBorder.lineWidth = 1
        previewBorder.stroke()
    }

    private func copyPixelColor(at globalPoint: CGPoint) {
        guard let sample = pixelSample(at: globalPoint) else {
            NSSound.beep()
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(sample.color.clipboardString, forType: .string) else {
            NSSound.beep()
            return
        }

        colorCopyFeedback = L10n.tr("已复制 %@", sample.color.hexString)
        colorFeedbackTask?.cancel()
        colorFeedbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            self?.colorCopyFeedback = nil
            self?.needsDisplay = true
        }
        needsDisplay = true
    }
}

final class ScreenshotOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
