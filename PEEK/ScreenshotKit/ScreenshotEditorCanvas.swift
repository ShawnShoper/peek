import AppKit
import Foundation

func screenshotEditorDisplayedImageRect(
    imageSize: CGSize,
    viewportBounds: CGRect,
    contentInset: CGFloat,
    zoomScale: CGFloat,
    panOffset: CGSize
) -> CGRect {
    guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
    let insetBounds = viewportBounds.insetBy(dx: contentInset, dy: contentInset)
    guard insetBounds.width > 0, insetBounds.height > 0 else { return .zero }

    let fitScale = min(
        insetBounds.width / imageSize.width,
        insetBounds.height / imageSize.height
    )
    let safeZoom = min(max(1, zoomScale), 8)
    let size = CGSize(
        width: imageSize.width * fitScale * safeZoom,
        height: imageSize.height * fitScale * safeZoom
    )
    let maximumPanX = max(0, (size.width - insetBounds.width) / 2)
    let maximumPanY = max(0, (size.height - insetBounds.height) / 2)
    let clampedPan = CGSize(
        width: min(max(-maximumPanX, panOffset.width), maximumPanX),
        height: min(max(-maximumPanY, panOffset.height), maximumPanY)
    )
    return CGRect(
        x: insetBounds.midX - size.width / 2 + clampedPan.width,
        y: insetBounds.midY - size.height / 2 + clampedPan.height,
        width: size.width,
        height: size.height
    )
}

@MainActor
final class ScreenshotEditorCanvas: NSView {
    private enum Interaction {
        case shape(tool: ScreenshotAnnotationTool, start: CGPoint, current: CGPoint)
        case stroke(tool: ScreenshotAnnotationTool, points: [CGPoint])
        case move(index: Int, original: ScreenshotAnnotation, start: CGPoint, current: CGPoint)
    }

    let document: ScreenshotAnnotationDocument
    var tool: ScreenshotAnnotationTool = .rectangle {
        didSet {
            interaction = nil
            document.discardPixelatedBaseImageIfUnused()
            needsDisplay = true
        }
    }
    var style = ScreenshotAnnotationStyle()
    var onTextRequested: ((CGPoint) -> Void)?
    var onDoubleClick: (() -> Void)?
    var onCommitRequested: (() -> Void)?
    var onCancelRequested: (() -> Void)?
    var onZoomChanged: ((CGFloat) -> Void)?
    var imageContentInset: CGFloat = 24 {
        didSet { needsDisplay = true }
    }
    var drawsImageShadow = true {
        didSet { needsDisplay = true }
    }
    var canvasBackgroundColor: NSColor = .windowBackgroundColor {
        didSet {
            layer?.backgroundColor = canvasBackgroundColor.cgColor
            needsDisplay = true
        }
    }

    private(set) var selectedAnnotationIndex: Int?
    private(set) var zoomScale: CGFloat = 1
    private var interaction: Interaction?
    private var panOffset: CGSize = .zero

    init(document: ScreenshotAnnotationDocument) {
        self.document = document
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        canvasBackgroundColor.setFill()
        bounds.fill()

        let imageRect = displayedImageRect
        if drawsImageShadow {
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 10
            shadow.shadowOffset = CGSize(width: 0, height: -2)
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
            shadow.set()
        }
        document.baseImage.draw(
            in: imageRect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        if drawsImageShadow {
            NSGraphicsContext.restoreGraphicsState()
        }

        guard imageRect.width > 0, imageRect.height > 0 else { return }
        let requiresMosaicEffect = document.containsMosaic || draftAnnotation?.isMosaic == true
        let mosaicEffectSource = requiresMosaicEffect
            ? document.pixelatedBaseImageIfNeeded()
            : nil
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: imageRect).addClip()
        imageTransform(for: imageRect).concat()

        for (index, annotation) in document.annotations.enumerated() {
            if case let .move(movingIndex, _, _, _) = interaction,
               movingIndex == index {
                continue
            }
            annotation.draw(
                effectSource: mosaicEffectSource,
                imageBounds: CGRect(origin: .zero, size: document.baseImage.size)
            )
        }

        draftAnnotation?.draw(
            effectSource: mosaicEffectSource,
            imageBounds: CGRect(origin: .zero, size: document.baseImage.size)
        )
        drawSelection()
        NSGraphicsContext.restoreGraphicsState()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount >= 2 {
            onDoubleClick?()
            return
        }
        guard let point = imagePoint(for: event.locationInWindow, clamp: false) else {
            selectedAnnotationIndex = nil
            needsDisplay = true
            return
        }

        switch tool {
        case .select:
            selectedAnnotationIndex = hitTestAnnotation(at: point)
            if let index = selectedAnnotationIndex {
                interaction = .move(
                    index: index,
                    original: document.annotations[index],
                    start: point,
                    current: point
                )
            }
        case .rectangle, .ellipse, .arrow, .line:
            selectedAnnotationIndex = nil
            interaction = .shape(tool: tool, start: point, current: point)
        case .pen, .highlighter, .mosaic:
            selectedAnnotationIndex = nil
            interaction = .stroke(tool: tool, points: [point])
        case .text:
            selectedAnnotationIndex = nil
            onTextRequested?(point)
        case .counter:
            selectedAnnotationIndex = nil
            document.add(.counter(point, document.nextCounterValue, style))
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let point = imagePoint(for: event.locationInWindow, clamp: true),
              let interaction else {
            return
        }

        switch interaction {
        case let .shape(tool, start, _):
            self.interaction = .shape(tool: tool, start: start, current: point)
        case let .stroke(tool, points):
            var updated = points
            if let last = updated.last,
               hypot(last.x - point.x, last.y - point.y) >= 0.75 {
                updated.append(point)
            }
            self.interaction = .stroke(tool: tool, points: updated)
        case let .move(index, original, start, _):
            self.interaction = .move(
                index: index,
                original: original,
                start: start,
                current: point
            )
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let interaction else { return }

        switch interaction {
        case .shape, .stroke:
            if let annotation = draftAnnotation,
               annotation.bounds.width >= 1 || annotation.bounds.height >= 1 {
                document.add(annotation)
            }
        case let .move(index, original, start, current):
            let delta = CGSize(width: current.x - start.x, height: current.y - start.y)
            if abs(delta.width) >= 0.5 || abs(delta.height) >= 0.5 {
                document.replace(at: index, with: original.translated(by: delta))
            }
        }
        self.interaction = nil
        needsDisplay = true
    }

    override func magnify(with event: NSEvent) {
        let multiplier = max(0.2, 1 + event.magnification)
        setZoomScale(
            zoomScale * multiplier,
            around: convert(event.locationInWindow, from: nil)
        )
    }

    override func scrollWheel(with event: NSEvent) {
        guard zoomScale > 1.001 else {
            super.scrollWheel(with: event)
            return
        }
        let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 8
        panOffset.width += event.scrollingDeltaX * multiplier
        panOffset.height -= event.scrollingDeltaY * multiplier
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "+", "=":
                zoomIn()
                return
            case "-", "_":
                zoomOut()
                return
            case "0":
                resetZoom()
                return
            default:
                break
            }
        }
        if modifiers.contains(.command), event.charactersIgnoringModifiers == "z" {
            if modifiers.contains(.shift) {
                document.redo()
            } else {
                document.undo()
            }
            selectedAnnotationIndex = nil
            return
        }

        switch event.keyCode {
        case 36, 76:
            if let onCommitRequested {
                onCommitRequested()
            } else {
                super.keyDown(with: event)
            }
        case 51, 117:
            if let selectedAnnotationIndex {
                document.remove(at: selectedAnnotationIndex)
                self.selectedAnnotationIndex = nil
            }
        case 53:
            if let onCancelRequested {
                onCancelRequested()
            } else {
                interaction = nil
                document.discardPixelatedBaseImageIfUnused()
                selectedAnnotationIndex = nil
                needsDisplay = true
            }
        default:
            super.keyDown(with: event)
        }
    }

    func addText(_ text: String, at point: CGPoint) {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        document.add(.text(point, normalized, style))
    }

    func zoomIn() {
        setZoomScale(
            zoomScale * 1.25,
            around: CGPoint(x: bounds.midX, y: bounds.midY)
        )
    }

    func zoomOut() {
        setZoomScale(
            zoomScale / 1.25,
            around: CGPoint(x: bounds.midX, y: bounds.midY)
        )
    }

    func resetZoom() {
        zoomScale = 1
        panOffset = .zero
        onZoomChanged?(zoomScale)
        needsDisplay = true
    }

    private func setZoomScale(_ proposedScale: CGFloat, around anchor: CGPoint) {
        let oldRect = displayedImageRect
        guard oldRect.width > 0, oldRect.height > 0 else { return }
        let normalizedAnchor = CGPoint(
            x: min(max(0, (anchor.x - oldRect.minX) / oldRect.width), 1),
            y: min(max(0, (anchor.y - oldRect.minY) / oldRect.height), 1)
        )
        let updatedScale = min(max(1, proposedScale), 8)
        guard abs(updatedScale - zoomScale) > 0.0001 else { return }
        zoomScale = updatedScale

        let centeredRect = screenshotEditorDisplayedImageRect(
            imageSize: document.baseImage.size,
            viewportBounds: bounds,
            contentInset: imageContentInset,
            zoomScale: updatedScale,
            panOffset: .zero
        )
        let desiredOrigin = CGPoint(
            x: anchor.x - normalizedAnchor.x * centeredRect.width,
            y: anchor.y - normalizedAnchor.y * centeredRect.height
        )
        panOffset = CGSize(
            width: desiredOrigin.x - centeredRect.minX,
            height: desiredOrigin.y - centeredRect.minY
        )
        onZoomChanged?(zoomScale)
        needsDisplay = true
    }

    private var displayedImageRect: CGRect {
        screenshotEditorDisplayedImageRect(
            imageSize: document.baseImage.size,
            viewportBounds: bounds,
            contentInset: imageContentInset,
            zoomScale: zoomScale,
            panOffset: panOffset
        )
    }

    private func imageTransform(for imageRect: CGRect) -> NSAffineTransform {
        let imageSize = document.baseImage.size
        let transform = NSAffineTransform()
        transform.translateX(by: imageRect.minX, yBy: imageRect.minY)
        transform.scaleX(by: imageRect.width / imageSize.width, yBy: imageRect.height / imageSize.height)
        return transform
    }

    private func imagePoint(for windowPoint: CGPoint, clamp: Bool) -> CGPoint? {
        let local = convert(windowPoint, from: nil)
        let rect = displayedImageRect
        guard clamp || rect.contains(local) else { return nil }
        guard rect.width > 0, rect.height > 0 else { return nil }

        let imageSize = document.baseImage.size
        let x = (local.x - rect.minX) * imageSize.width / rect.width
        let y = (local.y - rect.minY) * imageSize.height / rect.height
        return CGPoint(
            x: min(max(0, x), imageSize.width),
            y: min(max(0, y), imageSize.height)
        )
    }

    private func hitTestAnnotation(at point: CGPoint) -> Int? {
        document.annotations.indices.reversed().first {
            document.annotations[$0].bounds.insetBy(dx: -6, dy: -6).contains(point)
        }
    }

    private var draftAnnotation: ScreenshotAnnotation? {
        guard let interaction else { return nil }
        switch interaction {
        case let .shape(tool, start, current):
            let rect = CGRect(
                x: min(start.x, current.x),
                y: min(start.y, current.y),
                width: abs(start.x - current.x),
                height: abs(start.y - current.y)
            )
            switch tool {
            case .rectangle: return .rectangle(rect, style)
            case .ellipse: return .ellipse(rect, style)
            case .arrow: return .arrow(start, current, style)
            case .line: return .line(start, current, style)
            default: return nil
            }
        case let .stroke(tool, points):
            if tool == .highlighter {
                return .highlighter(points, style)
            }
            if tool == .mosaic {
                return .mosaic(points, style)
            }
            return .pen(points, style)
        case let .move(_, original, start, current):
            return original.translated(
                by: CGSize(width: current.x - start.x, height: current.y - start.y)
            )
        }
    }

    private func drawSelection() {
        guard tool == .select,
              let selectedAnnotationIndex,
              document.annotations.indices.contains(selectedAnnotationIndex) else {
            return
        }

        let selected: ScreenshotAnnotation
        if case let .move(index, _, _, _) = interaction,
           index == selectedAnnotationIndex,
           let draftAnnotation {
            selected = draftAnnotation
        } else {
            selected = document.annotations[selectedAnnotationIndex]
        }

        let border = NSBezierPath(rect: selected.bounds.insetBy(dx: -3, dy: -3))
        border.lineWidth = 1
        border.setLineDash([5, 3], count: 2, phase: 0)
        NSColor.systemBlue.setStroke()
        border.stroke()
    }
}
