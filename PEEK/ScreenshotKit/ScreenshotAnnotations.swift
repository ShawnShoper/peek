import AppKit
import Foundation

enum ScreenshotAnnotationTool: Int, CaseIterable {
    case select
    case rectangle
    case ellipse
    case arrow
    case line
    case pen
    case highlighter
    case mosaic
    case text
    case counter

    var title: String {
        switch self {
        case .select: return L10n.tr("选择")
        case .rectangle: return L10n.tr("矩形")
        case .ellipse: return L10n.tr("椭圆")
        case .arrow: return L10n.tr("箭头")
        case .line: return L10n.tr("直线")
        case .pen: return L10n.tr("画笔")
        case .highlighter: return L10n.tr("荧光笔")
        case .mosaic: return L10n.tr("马赛克")
        case .text: return L10n.tr("文字")
        case .counter: return L10n.tr("序号")
        }
    }
}

struct ScreenshotAnnotationStyle {
    enum ShapeFill: Int {
        case filled
        case outline
    }

    var color: NSColor = .systemRed
    var lineWidth: CGFloat = 3
    var fontSize: CGFloat = 22
    var shapeFill: ShapeFill = .outline
}

enum ScreenshotAnnotation {
    case rectangle(CGRect, ScreenshotAnnotationStyle)
    case ellipse(CGRect, ScreenshotAnnotationStyle)
    case arrow(CGPoint, CGPoint, ScreenshotAnnotationStyle)
    case line(CGPoint, CGPoint, ScreenshotAnnotationStyle)
    case pen([CGPoint], ScreenshotAnnotationStyle)
    case highlighter([CGPoint], ScreenshotAnnotationStyle)
    case mosaic([CGPoint], ScreenshotAnnotationStyle)
    case text(CGPoint, String, ScreenshotAnnotationStyle)
    case counter(CGPoint, Int, ScreenshotAnnotationStyle)

    var isMosaic: Bool {
        if case .mosaic = self { return true }
        return false
    }

    var bounds: CGRect {
        switch self {
        case let .rectangle(rect, style), let .ellipse(rect, style):
            return rect.standardized.insetBy(dx: -style.lineWidth, dy: -style.lineWidth)
        case let .arrow(start, end, style), let .line(start, end, style):
            return CGRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: abs(start.x - end.x),
                height: abs(start.y - end.y)
            ).insetBy(dx: -max(8, style.lineWidth * 3), dy: -max(8, style.lineWidth * 3))
        case let .pen(points, style), let .highlighter(points, style),
             let .mosaic(points, style):
            guard let first = points.first else { return .zero }
            let rawBounds = points.dropFirst().reduce(CGRect(origin: first, size: .zero)) {
                $0.union(CGRect(origin: $1, size: .zero))
            }
            return rawBounds.insetBy(dx: -max(5, style.lineWidth), dy: -max(5, style.lineWidth))
        case let .text(origin, value, style):
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: style.fontSize, weight: .medium)
            ]
            let size = value.size(withAttributes: attributes)
            return CGRect(origin: origin, size: size).insetBy(dx: -4, dy: -4)
        case let .counter(center, _, style):
            let radius = max(11, style.fontSize * 0.62)
            return CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            )
        }
    }

    func translated(by delta: CGSize) -> ScreenshotAnnotation {
        func move(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x + delta.width, y: point.y + delta.height)
        }

        switch self {
        case let .rectangle(rect, style):
            return .rectangle(rect.offsetBy(dx: delta.width, dy: delta.height), style)
        case let .ellipse(rect, style):
            return .ellipse(rect.offsetBy(dx: delta.width, dy: delta.height), style)
        case let .arrow(start, end, style):
            return .arrow(move(start), move(end), style)
        case let .line(start, end, style):
            return .line(move(start), move(end), style)
        case let .pen(points, style):
            return .pen(points.map(move), style)
        case let .highlighter(points, style):
            return .highlighter(points.map(move), style)
        case let .mosaic(points, style):
            return .mosaic(points.map(move), style)
        case let .text(origin, value, style):
            return .text(move(origin), value, style)
        case let .counter(center, value, style):
            return .counter(move(center), value, style)
        }
    }

    func draw(effectSource: NSImage? = nil, imageBounds: CGRect = .zero) {
        switch self {
        case let .rectangle(rect, style):
            applyStroke(style)
            let path = NSBezierPath(rect: rect.standardized)
            path.lineWidth = style.lineWidth
            path.lineJoinStyle = .round
            if style.shapeFill == .filled {
                style.color.withAlphaComponent(0.22).setFill()
                path.fill()
                applyStroke(style)
            }
            path.stroke()

        case let .ellipse(rect, style):
            applyStroke(style)
            let path = NSBezierPath(ovalIn: rect.standardized)
            path.lineWidth = style.lineWidth
            if style.shapeFill == .filled {
                style.color.withAlphaComponent(0.22).setFill()
                path.fill()
                applyStroke(style)
            }
            path.stroke()

        case let .arrow(start, end, style):
            applyStroke(style)
            drawLine(from: start, to: end, style: style)
            drawArrowHead(from: start, to: end, style: style)

        case let .line(start, end, style):
            applyStroke(style)
            drawLine(from: start, to: end, style: style)

        case let .pen(points, style):
            applyStroke(style)
            drawStroke(points, width: style.lineWidth)

        case let .highlighter(points, style):
            style.color.withAlphaComponent(0.34).setStroke()
            drawStroke(points, width: max(10, style.lineWidth * 4))

        case let .mosaic(points, style):
            guard let effectSource,
                  let context = NSGraphicsContext.current?.cgContext,
                  let first = points.first else {
                return
            }
            let path = CGMutablePath()
            path.move(to: first)
            points.dropFirst().forEach { path.addLine(to: $0) }
            if points.count == 1 {
                path.addLine(to: CGPoint(x: first.x + 0.01, y: first.y + 0.01))
            }

            context.saveGState()
            context.addPath(path)
            context.setLineWidth(max(18, style.lineWidth * 6))
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.replacePathWithStrokedPath()
            context.clip()
            effectSource.draw(
                in: imageBounds,
                from: .zero,
                operation: .copy,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.none]
            )
            context.restoreGState()

        case let .text(origin, value, style):
            value.draw(
                at: origin,
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: style.fontSize, weight: .semibold),
                    .foregroundColor: style.color
                ]
            )

        case let .counter(center, value, style):
            let radius = max(11, style.fontSize * 0.62)
            let circle = CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            style.color.setFill()
            NSBezierPath(ovalIn: circle).fill()

            let string = String(value)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(
                    ofSize: max(11, style.fontSize * 0.72),
                    weight: .bold
                ),
                .foregroundColor: NSColor.white
            ]
            let size = string.size(withAttributes: attributes)
            string.draw(
                at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2),
                withAttributes: attributes
            )
        }
    }

    private func applyStroke(_ style: ScreenshotAnnotationStyle) {
        style.color.setStroke()
    }

    private func drawLine(
        from start: CGPoint,
        to end: CGPoint,
        style: ScreenshotAnnotationStyle
    ) {
        let path = NSBezierPath()
        path.move(to: start)
        path.line(to: end)
        path.lineWidth = style.lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }

    private func drawStroke(_ points: [CGPoint], width: CGFloat) {
        guard let first = points.first else { return }
        let path = NSBezierPath()
        path.move(to: first)
        if points.count == 1 {
            path.line(to: CGPoint(x: first.x + 0.01, y: first.y + 0.01))
        } else {
            points.dropFirst().forEach(path.line)
        }
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }

    private func drawArrowHead(
        from start: CGPoint,
        to end: CGPoint,
        style: ScreenshotAnnotationStyle
    ) {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let length = max(12, style.lineWidth * 4.5)
        let spread: CGFloat = .pi / 6
        let first = CGPoint(
            x: end.x - length * cos(angle - spread),
            y: end.y - length * sin(angle - spread)
        )
        let second = CGPoint(
            x: end.x - length * cos(angle + spread),
            y: end.y - length * sin(angle + spread)
        )
        let path = NSBezierPath()
        path.move(to: first)
        path.line(to: end)
        path.line(to: second)
        path.lineWidth = style.lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }
}

@MainActor
final class ScreenshotAnnotationDocument {
    let baseImage: NSImage
    private(set) var annotations: [ScreenshotAnnotation] = []
    private var undoStack: [[ScreenshotAnnotation]] = []
    private var redoStack: [[ScreenshotAnnotation]] = []
    private var cachedPixelatedBaseImage: NSImage?

    var onChange: (() -> Void)?

    init(baseImage: NSImage) {
        self.baseImage = baseImage
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var containsMosaic: Bool { annotations.contains(where: \.isMosaic) }

    var nextCounterValue: Int {
        let maximum = annotations.compactMap { annotation -> Int? in
            if case let .counter(_, value, _) = annotation { return value }
            return nil
        }.max() ?? 0
        return maximum + 1
    }

    func add(_ annotation: ScreenshotAnnotation) {
        registerUndoState()
        annotations.append(annotation)
        changed()
    }

    func replace(at index: Int, with annotation: ScreenshotAnnotation) {
        guard annotations.indices.contains(index) else { return }
        registerUndoState()
        annotations[index] = annotation
        changed()
    }

    func remove(at index: Int) {
        guard annotations.indices.contains(index) else { return }
        registerUndoState()
        annotations.remove(at: index)
        changed()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(annotations)
        annotations = previous
        changed()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(annotations)
        annotations = next
        changed()
    }

    func renderedImage() -> NSImage? {
        let effectImage = containsMosaic ? pixelatedBaseImageIfNeeded() : nil
        return ScreenshotAnnotationRenderer.render(
            baseImage: baseImage,
            pixelatedBaseImage: effectImage,
            annotations: annotations
        )
    }

    /// Creates the full-resolution mosaic source only when a mosaic annotation
    /// is present or the canvas is actively previewing one.
    func pixelatedBaseImageIfNeeded() -> NSImage {
        if let cachedPixelatedBaseImage {
            return cachedPixelatedBaseImage
        }
        let generated = ScreenshotAnnotationRenderer.pixelatedImage(
            from: baseImage,
            blockSize: 12
        ) ?? baseImage
        cachedPixelatedBaseImage = generated
        return generated
    }

    func discardPixelatedBaseImageIfUnused() {
        guard !containsMosaic else { return }
        cachedPixelatedBaseImage = nil
    }

    private func registerUndoState() {
        undoStack.append(annotations)
        if undoStack.count > 100 {
            undoStack.removeFirst(undoStack.count - 100)
        }
        redoStack.removeAll()
    }

    private func changed() {
        discardPixelatedBaseImageIfUnused()
        onChange?()
    }
}

enum ScreenshotAnnotationRenderer {
    static func render(
        baseImage: NSImage,
        pixelatedBaseImage: NSImage? = nil,
        annotations: [ScreenshotAnnotation]
    ) -> NSImage? {
        let logicalSize = baseImage.size
        guard logicalSize.width > 0, logicalSize.height > 0 else { return nil }

        let bestRepresentation = baseImage.representations.max {
            $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh
        }
        let pixelsWide = max(1, bestRepresentation?.pixelsWide ?? Int(ceil(logicalSize.width)))
        let pixelsHigh = max(1, bestRepresentation?.pixelsHigh ?? Int(ceil(logicalSize.height)))

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
            return nil
        }
        bitmap.size = logicalSize

        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        NSColor.clear.setFill()
        CGRect(origin: .zero, size: logicalSize).fill()
        baseImage.draw(
            in: CGRect(origin: .zero, size: logicalSize),
            from: .zero,
            operation: .copy,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        let containsMosaic = annotations.contains(where: \.isMosaic)
        let effectImage: NSImage?
        if containsMosaic {
            effectImage = pixelatedBaseImage
                ?? pixelatedImage(from: baseImage, blockSize: 12)
                ?? baseImage
        } else {
            effectImage = nil
        }
        annotations.forEach {
            $0.draw(
                effectSource: effectImage,
                imageBounds: CGRect(origin: .zero, size: logicalSize)
            )
        }
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        let output = NSImage(size: logicalSize)
        output.addRepresentation(bitmap)
        return output
    }

    static func pixelatedImage(from image: NSImage, blockSize: CGFloat) -> NSImage? {
        let logicalSize = image.size
        guard logicalSize.width > 0, logicalSize.height > 0 else { return nil }

        let bestRepresentation = image.representations.max {
            $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh
        }
        let outputWidth = max(1, bestRepresentation?.pixelsWide ?? Int(logicalSize.width))
        let outputHeight = max(1, bestRepresentation?.pixelsHigh ?? Int(logicalSize.height))
        let scale = CGFloat(outputWidth) / logicalSize.width
        let smallWidth = max(1, Int(ceil(CGFloat(outputWidth) / (blockSize * scale))))
        let smallHeight = max(1, Int(ceil(CGFloat(outputHeight) / (blockSize * scale))))

        guard let smallRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: smallWidth,
            pixelsHigh: smallHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        smallRep.size = logicalSize
        guard let smallContext = NSGraphicsContext(bitmapImageRep: smallRep) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = smallContext
        smallContext.imageInterpolation = .low
        image.draw(in: CGRect(origin: .zero, size: logicalSize))
        smallContext.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        let smallImage = NSImage(size: logicalSize)
        smallImage.addRepresentation(smallRep)
        guard let outputRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: outputWidth,
            pixelsHigh: outputHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        outputRep.size = logicalSize
        guard let outputContext = NSGraphicsContext(bitmapImageRep: outputRep) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = outputContext
        outputContext.imageInterpolation = .none
        smallImage.draw(in: CGRect(origin: .zero, size: logicalSize))
        outputContext.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        let output = NSImage(size: logicalSize)
        output.addRepresentation(outputRep)
        return output
    }
}
