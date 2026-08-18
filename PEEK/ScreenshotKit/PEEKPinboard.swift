import AppKit
import SwiftUI

/// A lightweight description of a pinned image exposed to SwiftUI callers.
struct PEEKPinnedImage: Identifiable, Equatable {
    let id: UUID
    let sourceURL: URL?
    let createdAt: Date
    var opacity: Double
    var quarterTurns: Int
}

/// Owns every pinned-image window. Keep one instance in the app environment, or use `shared`.
@MainActor
final class PEEKPinboard: ObservableObject {
    static let shared = PEEKPinboard()

    @Published private(set) var items: [PEEKPinnedImage] = []

    private var controllers: [UUID: PEEKPinWindowController] = [:]

    /// Creates a new, independent, borderless floating window. Calling this repeatedly pins
    /// multiple images instead of replacing the previous one.
    @discardableResult
    func pin(
        image: NSImage,
        sourceURL: URL? = nil,
        initialFrame: NSRect? = nil
    ) -> UUID {
        let id = UUID()
        let item = PEEKPinnedImage(
            id: id,
            sourceURL: sourceURL,
            createdAt: Date(),
            opacity: 1,
            quarterTurns: 0
        )

        let controller = PEEKPinWindowController(
            id: id,
            image: image,
            sourceURL: sourceURL,
            initialFrame: initialFrame,
            onChange: { [weak self] opacity, quarterTurns in
                self?.updateItem(id: id, opacity: opacity, quarterTurns: quarterTurns)
            },
            onClose: { [weak self] in
                self?.didClose(id: id)
            }
        )

        controllers[id] = controller
        items.append(item)
        controller.showWindow(nil)
        controller.window?.orderFrontRegardless()
        return id
    }

    func close(id: UUID) {
        controllers[id]?.close()
    }

    func closeAll() {
        // Copy first because closing a window mutates `controllers` through its delegate.
        Array(controllers.values).forEach { $0.close() }
    }

    func setOpacity(_ opacity: Double, for id: UUID) {
        controllers[id]?.setOpacity(opacity)
    }

    func rotateClockwise(id: UUID) {
        controllers[id]?.rotate(by: 1)
    }

    func rotateCounterclockwise(id: UUID) {
        controllers[id]?.rotate(by: -1)
    }

    @discardableResult
    func copy(id: UUID) -> Bool {
        controllers[id]?.copyDisplayedImage() ?? false
    }

    /// Saves the currently displayed orientation as PNG without showing a panel.
    func save(id: UUID, to url: URL) throws {
        guard let controller = controllers[id] else {
            throw PEEKPinboardError.pinNotFound
        }
        try controller.saveDisplayedImage(to: url)
    }

    private func updateItem(id: UUID, opacity: Double, quarterTurns: Int) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].opacity = opacity
        items[index].quarterTurns = quarterTurns
    }

    private func didClose(id: UUID) {
        controllers.removeValue(forKey: id)
        items.removeAll { $0.id == id }
    }
}

enum PEEKPinboardError: LocalizedError {
    case pinNotFound
    case imageEncodingFailed

    var errorDescription: String? {
        switch self {
        case .pinNotFound:
            return L10n.tr("钉图不存在或已经关闭")
        case .imageEncodingFailed:
            return L10n.tr("无法将图片编码为 PNG")
        }
    }
}

@MainActor
private final class PEEKPinWindowController: NSWindowController, NSWindowDelegate {
    private let id: UUID
    private let sourceURL: URL?
    private let model: PEEKPinWindowModel
    private let onClose: () -> Void
    private var didNotifyClose = false

    init(
        id: UUID,
        image: NSImage,
        sourceURL: URL?,
        initialFrame: NSRect?,
        onChange: @escaping (Double, Int) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.model = PEEKPinWindowModel(image: image, onChange: onChange)
        self.onClose = onClose

        let frame = initialFrame ?? Self.defaultFrame(for: image)
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.minSize = NSSize(width: 180, height: 120)
        panel.maxSize = NSSize(width: 2_400, height: 2_400)
        panel.title = sourceURL?.lastPathComponent ?? L10n.tr("钉图")
        panel.setAccessibilityLabel(L10n.tr("钉图窗口"))

        super.init(window: panel)
        panel.delegate = self

        let rootView = PEEKPinWindowView(
            model: model,
            onRotate: { [weak self] turns in self?.rotate(by: turns) },
            onCopy: { [weak self] in _ = self?.copyDisplayedImage() },
            onSave: { [weak self] in self?.presentSavePanel() },
            onClose: { [weak self] in self?.close() }
        )
        panel.contentView = PEEKPinHostingView(
            rootView: rootView,
            model: model,
            onRotate: { [weak self] turns in self?.rotate(by: turns) }
        )
    }

    required init?(coder: NSCoder) {
        nil
    }

    func setOpacity(_ opacity: Double) {
        model.opacity = min(max(opacity, 0.2), 1)
    }

    func rotate(by quarterTurns: Int) {
        model.rotate(by: quarterTurns)
        resizeForCurrentOrientation()
    }

    @discardableResult
    func copyDisplayedImage() -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.writeObjects([model.displayedImage])
    }

    func saveDisplayedImage(to url: URL) throws {
        guard let tiff = model.displayedImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:]) else {
            throw PEEKPinboardError.imageEncodingFailed
        }
        try data.write(to: url, options: .atomic)
    }

    func windowWillClose(_ notification: Notification) {
        notifyClosedOnce()
    }

    override func close() {
        super.close()
        notifyClosedOnce()
    }

    private func presentSavePanel() {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = Self.suggestedFilename(sourceURL: sourceURL)
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try self?.saveDisplayedImage(to: url)
            } catch {
                let alert = NSAlert(error: error)
                alert.beginSheetModal(for: window)
            }
        }
    }

    private func resizeForCurrentOrientation() {
        guard let window else { return }
        let oldFrame = window.frame
        let center = NSPoint(x: oldFrame.midX, y: oldFrame.midY)
        let proposedSize = NSSize(width: oldFrame.height, height: oldFrame.width)
        let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? oldFrame
        let width = min(max(proposedSize.width, window.minSize.width), visibleFrame.width)
        let height = min(max(proposedSize.height, window.minSize.height), visibleFrame.height)
        let origin = NSPoint(x: center.x - width / 2, y: center.y - height / 2)
        window.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true, animate: true)
    }

    private func notifyClosedOnce() {
        guard !didNotifyClose else { return }
        didNotifyClose = true
        onClose()
    }

    private static func defaultFrame(for image: NSImage) -> NSRect {
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 100, y: 100, width: 1_200, height: 800)
        let imageSize = image.size.width > 0 && image.size.height > 0
            ? image.size
            : NSSize(width: 480, height: 320)
        let maxWidth = min(visibleFrame.width * 0.48, 720)
        let maxHeight = min(visibleFrame.height * 0.56, 620)
        let scale = min(maxWidth / imageSize.width, maxHeight / imageSize.height, 1)
        let size = NSSize(
            width: max(imageSize.width * scale, 220),
            height: max(imageSize.height * scale, 160)
        )
        let cascadeOffset = CGFloat(Int.random(in: -36...36))
        return NSRect(
            x: visibleFrame.midX - size.width / 2 + cascadeOffset,
            y: visibleFrame.midY - size.height / 2 - cascadeOffset,
            width: size.width,
            height: size.height
        )
    }

    private static func suggestedFilename(sourceURL: URL?) -> String {
        if let sourceURL {
            return sourceURL.deletingPathExtension().lastPathComponent + "_pinned.png"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "PEEK_Pin_\(formatter.string(from: Date())).png"
    }
}

@MainActor
private final class PEEKPinWindowModel: ObservableObject {
    let originalImage: NSImage
    @Published private(set) var quarterTurns = 0
    @Published var opacity: Double = 1 {
        didSet {
            opacity = min(max(opacity, 0.2), 1)
            notifyChange()
        }
    }
    @Published private(set) var isControlBarVisible = true

    private let onChange: (Double, Int) -> Void

    init(image: NSImage, onChange: @escaping (Double, Int) -> Void) {
        self.originalImage = image
        self.onChange = onChange
    }

    var displayedImage: NSImage {
        PEEKPinImageRenderer.rotated(originalImage, quarterTurns: quarterTurns)
    }

    func rotate(by turns: Int) {
        quarterTurns = Self.normalized(quarterTurns + turns)
        notifyChange()
    }

    func adjustOpacity(by delta: Double) {
        opacity += delta
    }

    func toggleControlBar() {
        isControlBarVisible.toggle()
    }

    private func notifyChange() {
        onChange(opacity, quarterTurns)
    }

    private static func normalized(_ value: Int) -> Int {
        let remainder = value % 4
        return remainder >= 0 ? remainder : remainder + 4
    }
}

private struct PEEKPinWindowView: View {
    @ObservedObject var model: PEEKPinWindowModel
    let onRotate: (Int) -> Void
    let onCopy: () -> Void
    let onSave: () -> Void
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.001)
            Image(nsImage: model.displayedImage)
                .resizable()
                .interpolation(.high)
                .antialiased(true)
                .scaledToFit()
                .opacity(model.opacity)
                .padding(1)

            if model.isControlBarVisible {
                controlBar
                    .padding(8)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .background(Color.clear)
        .accessibilityLabel(L10n.tr("钉图"))
    }

    private var controlBar: some View {
        HStack(spacing: 8) {
            Button(action: { onRotate(-1) }) {
                Image(systemName: "rotate.left")
            }
            .help(L10n.tr("向左旋转"))

            Button(action: { onRotate(1) }) {
                Image(systemName: "rotate.right")
            }
            .help(L10n.tr("向右旋转"))

            Image(systemName: "circle.lefthalf.filled")
                .foregroundStyle(.secondary)
            Slider(value: $model.opacity, in: 0.2...1)
                .frame(width: 82)
                .help(L10n.tr("透明度"))

            Button(action: onCopy) {
                Image(systemName: "doc.on.doc")
            }
            .help(L10n.tr("复制"))

            Button(action: onSave) {
                Image(systemName: "square.and.arrow.down")
            }
            .help(L10n.tr("保存 PNG"))

            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .help(L10n.tr("关闭"))
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(radius: 4, y: 2)
    }
}

/// Makes the image area draggable while leaving the bottom control bar interactive.
@MainActor
private final class PEEKPinHostingView<Content: View>: NSHostingView<Content> {
    private let model: PEEKPinWindowModel
    private let onRotate: (Int) -> Void

    init(rootView: Content, model: PEEKPinWindowModel, onRotate: @escaping (Int) -> Void) {
        self.model = model
        self.onRotate = onRotate
        super.init(rootView: rootView)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init(rootView: Content) {
        fatalError("init(rootView:) has not been implemented")
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2 {
            model.toggleControlBar()
            return
        }

        // The controls occupy the lower strip; send those events into SwiftUI.
        let distanceFromBottom = isFlipped ? bounds.height - location.y : location.y
        if distanceFromBottom <= 58, model.isControlBarVisible {
            super.mouseDown(with: event)
        } else {
            window?.performDrag(with: event)
        }
    }

    override func magnify(with event: NSEvent) {
        guard let window else { return }
        let current = window.frame
        let factor = max(0.75, min(1.25, 1 + event.magnification))
        let newWidth = min(max(current.width * factor, window.minSize.width), window.maxSize.width)
        let newHeight = min(max(current.height * factor, window.minSize.height), window.maxSize.height)
        let newOrigin = NSPoint(
            x: current.midX - newWidth / 2,
            y: current.midY - newHeight / 2
        )
        window.setFrame(NSRect(x: newOrigin.x, y: newOrigin.y, width: newWidth, height: newHeight), display: true)
    }

    override func rotate(with event: NSEvent) {
        guard event.phase == .ended || event.phase == .cancelled else { return }
        onRotate(event.rotation >= 0 ? 1 : -1)
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.option) {
            model.adjustOpacity(by: Double(event.scrollingDeltaY) / 250)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

enum PEEKPinImageRenderer {
    static func rotated(_ image: NSImage, quarterTurns: Int) -> NSImage {
        let normalized = ((quarterTurns % 4) + 4) % 4
        guard normalized != 0 else { return image }

        let sourceSize = image.size
        let targetSize = normalized.isMultiple(of: 2)
            ? sourceSize
            : NSSize(width: sourceSize.height, height: sourceSize.width)
        let sourceRepresentation = image.representations.max {
            $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh
        }
        let sourcePixelsWide = max(1, sourceRepresentation?.pixelsWide ?? Int(ceil(sourceSize.width)))
        let sourcePixelsHigh = max(1, sourceRepresentation?.pixelsHigh ?? Int(ceil(sourceSize.height)))
        let targetPixelsWide = normalized.isMultiple(of: 2) ? sourcePixelsWide : sourcePixelsHigh
        let targetPixelsHigh = normalized.isMultiple(of: 2) ? sourcePixelsHigh : sourcePixelsWide

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: targetPixelsWide,
            pixelsHigh: targetPixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return image
        }
        bitmap.size = targetSize

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        graphicsContext.imageInterpolation = .high
        let context = graphicsContext.cgContext
        context.translateBy(x: targetSize.width / 2, y: targetSize.height / 2)
        context.rotate(by: CGFloat(normalized) * .pi / 2)
        image.draw(
            in: NSRect(
                x: -sourceSize.width / 2,
                y: -sourceSize.height / 2,
                width: sourceSize.width,
                height: sourceSize.height
            ),
            from: .zero,
            operation: .copy,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        graphicsContext.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        let output = NSImage(size: targetSize)
        output.addRepresentation(bitmap)
        return output
    }
}
