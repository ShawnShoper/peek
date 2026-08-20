import AppKit
import Foundation

enum ScreenshotEditorCursorKind: Equatable {
    case move
    case drawing
    case mosaic
    case text
}

func screenshotEditorCursorKind(
    for tool: ScreenshotAnnotationTool
) -> ScreenshotEditorCursorKind {
    switch tool {
    case .select:
        return .move
    case .text:
        return .text
    case .mosaic:
        return .mosaic
    case .rectangle, .ellipse, .counter, .arrow, .line, .pen,
         .highlighter:
        return .drawing
    }
}

func screenshotMosaicCursorDiameter(
    lineWidth: CGFloat,
    displayedImageScale: CGFloat
) -> CGFloat {
    let imageDiameter = max(18, lineWidth * 6)
    return min(64, max(18, imageDiameter * max(0.01, displayedImageScale)))
}

@MainActor
func makeScreenshotMosaicCursorImage(diameter: CGFloat) -> NSImage {
    let cursorDiameter = min(64, max(18, diameter))
    let canvasSize = cursorDiameter + 8
    let image = NSImage(
        size: CGSize(width: canvasSize, height: canvasSize),
        flipped: false
    ) { rect in
        let circle = rect.insetBy(dx: 4, dy: 4)
        let outline = NSBezierPath(ovalIn: circle)
        NSColor.white.withAlphaComponent(0.98).setStroke()
        outline.lineWidth = 4
        outline.stroke()
        NSColor.black.withAlphaComponent(0.92).setStroke()
        outline.lineWidth = 1.5
        outline.stroke()

        let center = CGPoint(x: rect.midX, y: rect.midY)
        let pixel: CGFloat = max(1.5, min(3, cursorDiameter / 10))
        NSColor.black.withAlphaComponent(0.9).setFill()
        for (column, row) in [(-1, 1), (0, 0), (1, -1), (1, 1), (-1, -1)] {
            CGRect(
                x: center.x + CGFloat(column) * pixel - pixel / 2,
                y: center.y + CGFloat(row) * pixel - pixel / 2,
                width: pixel,
                height: pixel
            ).fill()
        }
        return true
    }
    image.isTemplate = false
    return image
}

@MainActor
private final class ScreenshotInlineTextView: NSTextView {
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
            return
        }
        if event.keyCode == 36 || event.keyCode == 76 {
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if !modifiers.contains(.shift) {
                onCommit?()
                return
            }
        }
        super.keyDown(with: event)
    }
}

@MainActor
private final class ScreenshotInlineTextEditorView: NSView, NSTextViewDelegate {
    let textView = ScreenshotInlineTextView(frame: .zero)
    var onTextChanged: (() -> Void)?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 2
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.12).cgColor

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.delegate = self
        textView.isRichText = false
        textView.importsGraphics = false
        textView.drawsBackground = false
        textView.textContainerInset = CGSize(width: 6, height: 5)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        addSubview(textView)
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            textView.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func textDidChange(_ notification: Notification) {
        onTextChanged?()
    }

    func desiredSize(maxWidth: CGFloat, font: NSFont) -> CGSize {
        let value = textView.string.isEmpty ? "M" : textView.string
        let maximumTextWidth = max(36, maxWidth - 24)
        let measured = (value as NSString).boundingRect(
            with: CGSize(width: maximumTextWidth, height: 2_000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        ).integral.size
        return CGSize(
            width: min(maxWidth, max(52, measured.width + 24)),
            height: max(42, measured.height + 18)
        )
    }
}

@MainActor
func makeScreenshotFourWayMoveCursorImage() -> NSImage {
    let size = CGSize(width: 24, height: 24)
    let image = NSImage(size: size, flipped: false) { _ in
        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        path.move(to: CGPoint(x: 12, y: 3))
        path.line(to: CGPoint(x: 12, y: 21))
        path.move(to: CGPoint(x: 3, y: 12))
        path.line(to: CGPoint(x: 21, y: 12))

        path.move(to: CGPoint(x: 8, y: 7))
        path.line(to: CGPoint(x: 12, y: 3))
        path.line(to: CGPoint(x: 16, y: 7))
        path.move(to: CGPoint(x: 8, y: 17))
        path.line(to: CGPoint(x: 12, y: 21))
        path.line(to: CGPoint(x: 16, y: 17))
        path.move(to: CGPoint(x: 7, y: 8))
        path.line(to: CGPoint(x: 3, y: 12))
        path.line(to: CGPoint(x: 7, y: 16))
        path.move(to: CGPoint(x: 17, y: 8))
        path.line(to: CGPoint(x: 21, y: 12))
        path.line(to: CGPoint(x: 17, y: 16))

        NSColor.white.setStroke()
        path.lineWidth = 5
        path.stroke()

        NSColor.black.setStroke()
        path.lineWidth = 2
        path.stroke()
        return true
    }
    image.isTemplate = false
    return image
}

func screenshotSelectionPreviewSourceRect(
    selectionRect: CGRect,
    screenFrame: CGRect
) -> CGRect {
    let screenFrame = screenFrame.standardized
    let selection = selectionRect.standardized.intersection(screenFrame)
    guard !selection.isNull else { return .zero }
    return CGRect(
        x: selection.minX - screenFrame.minX,
        y: selection.minY - screenFrame.minY,
        width: selection.width,
        height: selection.height
    )
}

/// Draws a moving selection directly from the immutable display snapshot.
/// The full-resolution `CGImage` is wrapped once and every drag frame changes
/// only the logical source rectangle, avoiding a Retina-sized bitmap allocation
/// for every mouse event.
@MainActor
final class ScreenshotFrozenSelectionPreviewView: NSView {
    let display: ScreenshotFrozenDisplay
    private(set) var selectionRect: CGRect

    private let frozenImage: NSImage
    private lazy var pixelatedFrozenImage: NSImage? = makePixelatedFrozenImage()

    init(display: ScreenshotFrozenDisplay, selectionRect: CGRect) {
        self.display = display
        self.selectionRect = selectionRect
        frozenImage = NSImage(cgImage: display.image, size: display.screenFrame.size)
        super.init(frame: CGRect(origin: .zero, size: selectionRect.size))
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool { false }

    func updateSelection(_ rect: CGRect) {
        guard rect != selectionRect else { return }
        selectionRect = rect
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard selectionRect.size.width > 0, selectionRect.size.height > 0 else { return }
        drawSelection(in: bounds)
    }

    func drawSelection(in destination: CGRect) {
        frozenImage.draw(
            in: destination,
            from: sourceRect,
            operation: .copy,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.none]
        )
    }

    /// Called while the annotation canvas has already installed its image-space
    /// transform and mosaic stroke clip. The low-resolution full-display image
    /// is created at most once, then sampled without a per-frame output bitmap.
    func drawPixelatedSelection(in destination: CGRect) {
        guard let pixelatedFrozenImage else { return }
        pixelatedFrozenImage.draw(
            in: destination,
            from: sourceRect,
            operation: .copy,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.none]
        )
    }

    private var sourceRect: CGRect {
        screenshotSelectionPreviewSourceRect(
            selectionRect: selectionRect,
            screenFrame: display.screenFrame
        )
    }

    private func makePixelatedFrozenImage(blockSize: CGFloat = 12) -> NSImage? {
        let logicalSize = display.screenFrame.size
        guard logicalSize.width > 0, logicalSize.height > 0 else { return nil }
        let pixelsWide = max(1, Int(ceil(logicalSize.width / blockSize)))
        let pixelsHigh = max(1, Int(ceil(logicalSize.height / blockSize)))
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
        ) else { return nil }
        bitmap.size = logicalSize
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .low
        frozenImage.draw(
            in: CGRect(origin: .zero, size: logicalSize),
            from: .zero,
            operation: .copy,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.low]
        )
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: logicalSize)
        image.addRepresentation(bitmap)
        return image
    }
}

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
        case moveSelection(start: CGPoint, current: CGPoint)
    }

    let document: ScreenshotAnnotationDocument
    var tool: ScreenshotAnnotationTool = .rectangle {
        didSet {
            if oldValue == .text, tool != .text {
                commitInlineTextEditing()
            }
            interaction = nil
            document.discardPixelatedBaseImageIfUnused()
            if let window {
                window.invalidateCursorRects(for: self)
            }
            needsDisplay = true
        }
    }
    var style = ScreenshotAnnotationStyle() {
        didSet {
            if tool == .mosaic, let window {
                window.invalidateCursorRects(for: self)
            }
        }
    }
    var onTextRequested: ((CGPoint) -> Void)?
    var onDoubleClick: (() -> Void)?
    var onCommitRequested: (() -> Void)?
    var onCancelRequested: (() -> Void)?
    var onSelectionMoveBegan: (() -> Void)?
    var onSelectionMoveChanged: ((CGSize) -> Void)?
    var onSelectionMoveEnded: ((CGSize) -> Void)?
    var onZoomChanged: ((CGFloat) -> Void)?
    var drawsBaseImage = true {
        didSet {
            guard drawsBaseImage != oldValue else { return }
            needsDisplay = true
        }
    }
    var liveBaseImageDrawer: ((CGRect) -> Void)? {
        didSet { needsDisplay = true }
    }
    /// The inline selection stays transparent at its normal 1x scale. A live
    /// frozen-image drawer is enabled only while the user explicitly zooms,
    /// because the full-screen frozen overlay already supplies the 1x pixels.
    var showsLiveBaseImage = false {
        didSet {
            guard showsLiveBaseImage != oldValue else { return }
            needsDisplay = true
        }
    }
    var liveMosaicEffectDrawer: ((CGRect) -> Void)? {
        didSet { needsDisplay = true }
    }
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
    private var inlineTextEditor: ScreenshotInlineTextEditorView?
    private var inlineTextOrigin: CGPoint?
    private var inlineTextStyle: ScreenshotAnnotationStyle?

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

    override func resetCursorRects() {
        let cursor: NSCursor
        switch screenshotEditorCursorKind(for: tool) {
        case .move:
            cursor = Self.fourWayMoveCursor
        case .drawing:
            cursor = .crosshair
        case .mosaic:
            let imageRect = displayedImageRect
            let scale = document.baseImage.size.width > 0
                ? imageRect.width / document.baseImage.size.width
                : 1
            let image = makeScreenshotMosaicCursorImage(
                diameter: screenshotMosaicCursorDiameter(
                    lineWidth: style.lineWidth,
                    displayedImageScale: scale
                )
            )
            cursor = NSCursor(
                image: image,
                hotSpot: CGPoint(x: image.size.width / 2, y: image.size.height / 2)
            )
        case .text:
            cursor = .iBeam
        }
        addCursorRect(bounds, cursor: cursor)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if drawsBaseImage {
            canvasBackgroundColor.setFill()
            bounds.fill()
        } else if let context = NSGraphicsContext.current?.cgContext {
            context.saveGState()
            context.setBlendMode(.copy)
            context.setFillColor(NSColor.clear.cgColor)
            context.fill(bounds)
            context.restoreGState()
        }

        let imageRect = displayedImageRect
        if drawsBaseImage, drawsImageShadow {
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 10
            shadow.shadowOffset = CGSize(width: 0, height: -2)
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
            shadow.set()
        }
        if drawsBaseImage {
            document.baseImage.draw(
                in: imageRect,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high]
            )
        } else if showsLiveBaseImage {
            liveBaseImageDrawer?(imageRect)
        }
        if drawsBaseImage, drawsImageShadow {
            NSGraphicsContext.restoreGraphicsState()
        }

        guard imageRect.width > 0, imageRect.height > 0 else { return }
        let requiresMosaicEffect = document.containsMosaic || draftAnnotation?.isMosaic == true
        let mosaicEffectSource = requiresMosaicEffect && liveMosaicEffectDrawer == nil
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
                imageBounds: CGRect(origin: .zero, size: document.baseImage.size),
                effectDrawer: liveMosaicEffectDrawer
            )
        }

        draftAnnotation?.draw(
            effectSource: mosaicEffectSource,
            imageBounds: CGRect(origin: .zero, size: document.baseImage.size),
            effectDrawer: liveMosaicEffectDrawer
        )
        drawSelection()
        NSGraphicsContext.restoreGraphicsState()
    }

    override func mouseDown(with event: NSEvent) {
        if inlineTextEditor != nil {
            commitInlineTextEditing()
        }
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
            } else {
                let location = NSEvent.mouseLocation
                interaction = .moveSelection(start: location, current: location)
                onSelectionMoveBegan?()
            }
        case .rectangle, .ellipse, .arrow, .line:
            selectedAnnotationIndex = nil
            interaction = .shape(tool: tool, start: point, current: point)
        case .pen, .highlighter, .mosaic:
            selectedAnnotationIndex = nil
            interaction = .stroke(tool: tool, points: [point])
        case .text:
            selectedAnnotationIndex = nil
            if let onTextRequested {
                onTextRequested(point)
            } else {
                beginInlineTextEditing(at: point)
            }
        case .counter:
            selectedAnnotationIndex = nil
            document.add(.counter(point, document.nextCounterValue, style))
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if case let .moveSelection(start, _) = interaction {
            let current = NSEvent.mouseLocation
            interaction = .moveSelection(start: start, current: current)
            onSelectionMoveChanged?(
                CGSize(width: current.x - start.x, height: current.y - start.y)
            )
            return
        }
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
        case .moveSelection:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let interaction else { return }

        if case let .moveSelection(start, _) = interaction {
            let current = NSEvent.mouseLocation
            self.interaction = nil
            onSelectionMoveEnded?(
                CGSize(width: current.x - start.x, height: current.y - start.y)
            )
            return
        }

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
        case .moveSelection:
            break
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
        pan(
            by: CGSize(
                width: event.scrollingDeltaX * multiplier,
                height: -event.scrollingDeltaY * multiplier
            )
        )
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

    func beginInlineTextEditing(at point: CGPoint) {
        commitInlineTextEditing()
        let editor = ScreenshotInlineTextEditorView(frame: .zero)
        inlineTextEditor = editor
        inlineTextOrigin = point
        inlineTextStyle = style
        editor.textView.font = inlineTextFont(for: style)
        editor.textView.textColor = style.color
        editor.textView.insertionPointColor = style.color
        editor.textView.onCommit = { [weak self] in
            self?.commitInlineTextEditing()
        }
        editor.textView.onCancel = { [weak self] in
            self?.cancelInlineTextEditing()
        }
        editor.onTextChanged = { [weak self] in
            self?.layoutInlineTextEditor()
        }
        addSubview(editor)
        layoutInlineTextEditor()
        window?.makeFirstResponder(editor.textView)
    }

    func commitInlineTextEditing() {
        guard let editor = inlineTextEditor else { return }
        let value = editor.textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let origin = inlineTextOrigin
        let committedStyle = inlineTextStyle
        clearInlineTextEditor()
        if let origin, let committedStyle, !value.isEmpty {
            document.add(.text(origin, value, committedStyle))
        }
        window?.makeFirstResponder(self)
    }

    func cancelInlineTextEditing() {
        guard inlineTextEditor != nil else { return }
        clearInlineTextEditor()
        window?.makeFirstResponder(self)
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
        layoutInlineTextEditor()
    }

    func pan(by delta: CGSize) {
        guard zoomScale > 1.001 else { return }
        panOffset.width += delta.width
        panOffset.height += delta.height
        needsDisplay = true
        layoutInlineTextEditor()
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
        layoutInlineTextEditor()
    }

    override func layout() {
        super.layout()
        layoutInlineTextEditor()
    }

    private func inlineTextFont(for style: ScreenshotAnnotationStyle) -> NSFont {
        let imageRect = displayedImageRect
        let scale = document.baseImage.size.width > 0
            ? imageRect.width / document.baseImage.size.width
            : 1
        return NSFont.systemFont(
            ofSize: min(120, max(12, style.fontSize * scale)),
            weight: .semibold
        )
    }

    private func layoutInlineTextEditor() {
        guard let editor = inlineTextEditor,
              let origin = inlineTextOrigin,
              let editorStyle = inlineTextStyle else { return }
        let imageRect = displayedImageRect
        guard imageRect.width > 0, imageRect.height > 0,
              document.baseImage.size.width > 0,
              document.baseImage.size.height > 0 else { return }

        let scaleX = imageRect.width / document.baseImage.size.width
        let scaleY = imageRect.height / document.baseImage.size.height
        let anchor = CGPoint(
            x: imageRect.minX + origin.x * scaleX,
            y: imageRect.minY + origin.y * scaleY
        )
        let font = inlineTextFont(for: editorStyle)
        editor.textView.font = font
        let maximumWidth = max(52, min(360, imageRect.maxX - anchor.x + 8))
        let desired = editor.desiredSize(maxWidth: maximumWidth, font: font)
        editor.frame = CGRect(
            x: min(max(imageRect.minX, anchor.x - 8), max(imageRect.minX, imageRect.maxX - desired.width)),
            y: min(max(imageRect.minY, anchor.y - 12), max(imageRect.minY, imageRect.maxY - desired.height)),
            width: min(desired.width, imageRect.width),
            height: min(desired.height, imageRect.height)
        ).integral
    }

    private func clearInlineTextEditor() {
        inlineTextEditor?.removeFromSuperview()
        inlineTextEditor = nil
        inlineTextOrigin = nil
        inlineTextStyle = nil
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
        case .moveSelection:
            return nil
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

    private static let fourWayMoveCursor: NSCursor = {
        let image = makeScreenshotFourWayMoveCursorImage()
        return NSCursor(
            image: image,
            hotSpot: CGPoint(x: image.size.width / 2, y: image.size.height / 2)
        )
    }()
}
