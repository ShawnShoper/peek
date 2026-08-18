import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
func configureScreenshotPaletteButtonFocus(_ button: NSButton) {
    button.focusRingType = .none
    button.refusesFirstResponder = true
}

func screenshotFloatingColorPanelLevel(
    toolbarLevel: NSWindow.Level
) -> NSWindow.Level {
    NSWindow.Level(rawValue: toolbarLevel.rawValue + 1)
}

private extension ScreenshotAnnotationTool {
    var supportsInlineStylePalette: Bool {
        switch self {
        case .rectangle, .ellipse, .counter, .arrow, .line, .pen,
             .highlighter, .mosaic, .text:
            return true
        case .select:
            return false
        }
    }
}

enum ScreenshotEditorAction {
    case pinRequested(NSImage)
    case ocrRequested(NSImage)
    case qrCodeRequested(NSImage)
    case scrollCaptureRequested(NSImage)
    case scrollCaptureRequestedInSelection(NSImage, CGRect)
    case copied(NSImage)
    case saved(NSImage, URL)
}

/// Writes eager PNG/TIFF payloads so the clipboard remains valid after the
/// transient screenshot editor and its NSImage are released.
@MainActor
@discardableResult
func writeScreenshotImageToPasteboard(
    _ image: NSImage,
    pasteboard: NSPasteboard = .general
) -> Bool {
    let payloads = screenshotPasteboardPayloads(for: image)
    guard !payloads.isEmpty else { return false }
    pasteboard.clearContents()
    pasteboard.declareTypes(payloads.map(\.type), owner: nil)
    return payloads.reduce(false) { wroteAny, payload in
        pasteboard.setData(payload.data, forType: payload.type) || wroteAny
    }
}

@MainActor
func screenshotPasteboardPayloads(
    for image: NSImage
) -> [(type: NSPasteboard.PasteboardType, data: Data)] {
    guard let tiff = image.tiffRepresentation else { return [] }
    var payloads: [(type: NSPasteboard.PasteboardType, data: Data)] = [(.tiff, tiff)]
    if let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
        payloads.insert((.png, png), at: 0)
    }
    return payloads
}

/// AppKit screenshot editor entry point. The editor owns no persistence and
/// reports toolbar side effects to its caller through `onAction`.
@MainActor
final class ScreenshotEditorController {
    private var sessions: [UUID: ScreenshotEditorWindowController] = [:]
    private var inlineSessions: [UUID: ScreenshotInlineEditorSession] = [:]

    func edit(
        image: NSImage,
        onAction: ((ScreenshotEditorAction) -> Void)? = nil
    ) async -> NSImage? {
        await withCheckedContinuation { continuation in
            edit(image: image, onAction: onAction) { editedImage in
                continuation.resume(returning: editedImage)
            }
        }
    }

    func edit(
        image: NSImage,
        onAction: ((ScreenshotEditorAction) -> Void)? = nil,
        completion: @escaping (NSImage?) -> Void
    ) {
        let id = UUID()
        let session = ScreenshotEditorWindowController(
            image: image,
            onAction: onAction
        ) { [weak self] editedImage in
            self?.sessions[id] = nil
            completion(editedImage)
        }
        sessions[id] = session
        session.showWindow(nil)
    }

    func closeAll() {
        let currentSessions = Array(sessions.values)
        currentSessions.forEach { $0.cancelEditing() }
        let currentInlineSessions = Array(inlineSessions.values)
        currentInlineSessions.forEach { $0.cancelEditing() }
    }

    /// Presents the annotation canvas directly over the frozen selection and
    /// anchors one compact horizontal toolbar to its lower edge. No titled
    /// editor window is created.
    func editInline(
        image: NSImage,
        selectionRect: CGRect,
        screenFrame: CGRect,
        onAction: ((ScreenshotEditorAction) -> Void)? = nil,
        initialTool: ScreenshotAnnotationTool = .select,
        focusToolbarForUITesting: Bool = false,
        completion: @escaping (NSImage?) -> Void
    ) {
        let id = UUID()
        let session = ScreenshotInlineEditorSession(
            image: image,
            selectionRect: selectionRect,
            screenFrame: screenFrame,
            onAction: onAction,
            initialTool: initialTool,
            focusToolbarForUITesting: focusToolbarForUITesting
        ) { [weak self] editedImage in
            self?.inlineSessions[id] = nil
            completion(editedImage)
        }
        inlineSessions[id] = session
        session.show()
    }
}

/// Resolves a toolbar frame next to the bottom edge of a selection while
/// keeping the full toolbar on its owning display. AppKit screen coordinates
/// use a lower-left origin, so "below" means a smaller y value.
func screenshotInlineToolbarFrame(
    selectionRect: CGRect,
    toolbarSize: CGSize,
    screenFrame: CGRect,
    gap: CGFloat = 8,
    screenInset: CGFloat = 8
) -> CGRect {
    let safeFrame = screenFrame.insetBy(dx: screenInset, dy: screenInset)
    let width = min(max(1, toolbarSize.width), max(1, safeFrame.width))
    let height = min(max(1, toolbarSize.height), max(1, safeFrame.height))

    var x = selectionRect.maxX - width
    x = min(max(safeFrame.minX, x), safeFrame.maxX - width)

    let belowY = selectionRect.minY - gap - height
    let aboveY = selectionRect.maxY + gap
    let y: CGFloat
    if belowY >= safeFrame.minY {
        y = belowY
    } else if aboveY + height <= safeFrame.maxY {
        y = aboveY
    } else {
        y = min(max(safeFrame.minY, belowY), safeFrame.maxY - height)
    }

    return CGRect(x: x, y: y, width: width, height: height).integral
}

/// Centers the QR hint below its toolbar button while keeping the entire hint
/// inside the toolbar panel. Extracted as a pure function for boundary tests.
func screenshotQRCodeHintLeadingOffset(
    buttonMidX: CGFloat,
    hintWidth: CGFloat,
    toolbarWidth: CGFloat
) -> CGFloat {
    let availableWidth = max(0, toolbarWidth)
    let clampedHintWidth = min(max(0, hintWidth), availableWidth)
    return min(
        max(0, buttonMidX - clampedHintWidth / 2),
        max(0, availableWidth - clampedHintWidth)
    )
}

@MainActor
private final class ScreenshotInlineEditorSession: NSObject, NSWindowDelegate {
    private let annotationDocument: ScreenshotAnnotationDocument
    private let sourceImage: NSImage
    private let canvas: ScreenshotEditorCanvas
    private let canvasPanel: ScreenshotOverlayPanel
    private let toolbarPanel: ScreenshotOverlayPanel
    private let screenFrame: CGRect
    private let onAction: ((ScreenshotEditorAction) -> Void)?
    private let completion: (NSImage?) -> Void
    private let focusToolbarForUITesting: Bool

    private let selectionRect: CGRect
    private let toolbarRoot = NSStackView()
    private let mainToolbarEffect = NSVisualEffectView()
    private let contextPaletteEffect = NSVisualEffectView()
    private let contextPaletteRow = NSStackView()
    private let contextPaletteContainer = NSView()
    private let contextPointer = NSImageView()
    private let qrCodeButton = NSButton()
    private let qrHintRow = NSStackView()
    private let qrHintContainer = NSView()
    private let qrHintEffect = NSVisualEffectView()
    private let qrHintPointer = NSImageView()
    private let qrHintLeadingSpacer = NSView()
    private var qrHintLeadingConstraint: NSLayoutConstraint?
    private var qrDetectionTask: Task<Void, Never>?
    private var toolButtons: [ScreenshotAnnotationTool: NSButton] = [:]
    private var toolMenuButtons: [ScreenshotToolMenuButton] = []
    private var toolControls: [ScreenshotAnnotationTool: NSView] = [:]
    private let undoButton = NSButton()
    private let redoButton = NSButton()
    private let colorWheelButton = NSButton()
    private var colorSwatchButtons: [ScreenshotColorSwatchButton] = []
    private var widthButtons: [ScreenshotStyleOptionButton] = []
    private var fillButtons: [ScreenshotStyleOptionButton] = []
    private var contextPointerLeadingConstraint: NSLayoutConstraint?
    private let lineWidths: [CGFloat] = [1, 2, 4, 7, 10]
    private var selectedWidthIndex = 2
    private var selectedShapeFill: ScreenshotAnnotationStyle.ShapeFill = .filled
    private var selectedColor: NSColor = .black
    private var selectedTool: ScreenshotAnnotationTool = .select
    private var ownsColorPanel = false
    private var originalColorPanelLevel: NSWindow.Level?
    private var didComplete = false

    private static let qrHintWidth: CGFloat = 224

    init(
        image: NSImage,
        selectionRect: CGRect,
        screenFrame: CGRect,
        onAction: ((ScreenshotEditorAction) -> Void)?,
        initialTool: ScreenshotAnnotationTool,
        focusToolbarForUITesting: Bool,
        completion: @escaping (NSImage?) -> Void
    ) {
        annotationDocument = ScreenshotAnnotationDocument(baseImage: image)
        sourceImage = (image.copy() as? NSImage) ?? image
        canvas = ScreenshotEditorCanvas(document: annotationDocument)
        self.selectionRect = selectionRect
        self.screenFrame = screenFrame
        self.onAction = onAction
        self.selectedTool = initialTool
        self.focusToolbarForUITesting = focusToolbarForUITesting
        self.completion = completion

        canvasPanel = ScreenshotOverlayPanel(
            contentRect: selectionRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        toolbarPanel = ScreenshotOverlayPanel(
            contentRect: CGRect(x: 0, y: 0, width: 640, height: 92),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        super.init()

        configureCanvasPanel(selectionRect: selectionRect)
        configureToolbarPanel(selectionRect: selectionRect)
        bindActions()
    }

    func show() {
        canvasPanel.orderFrontRegardless()
        toolbarPanel.orderFrontRegardless()
        if focusToolbarForUITesting {
            toolbarPanel.makeKeyAndOrderFront(nil)
            toolbarPanel.makeFirstResponder(nil)
        } else {
            canvasPanel.makeKeyAndOrderFront(nil)
            canvasPanel.makeFirstResponder(canvas)
        }
        startQRCodeHintDetection()
    }

    func cancelEditing() {
        finish(with: nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as AnyObject === toolbarPanel
                || notification.object as AnyObject === canvasPanel else {
            return
        }
        finish(with: nil, closePanels: false)
    }

    private func configureCanvasPanel(selectionRect: CGRect) {
        canvas.imageContentInset = 0
        canvas.drawsImageShadow = false
        canvas.canvasBackgroundColor = .clear
        canvas.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView(frame: CGRect(origin: .zero, size: selectionRect.size))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.clear.cgColor
        root.layer?.borderColor = NSColor.systemBlue.cgColor
        root.layer?.borderWidth = 1.5
        root.addSubview(canvas)
        NSLayoutConstraint.activate([
            canvas.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: root.topAnchor),
            canvas.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        canvasPanel.contentView = root
        canvasPanel.setFrame(selectionRect.integral, display: false)
        canvasPanel.level = NSWindow.Level(
            rawValue: NSWindow.Level.screenSaver.rawValue + 1
        )
        canvasPanel.backgroundColor = .clear
        canvasPanel.isOpaque = false
        canvasPanel.hasShadow = false
        canvasPanel.hidesOnDeactivate = false
        canvasPanel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        canvasPanel.delegate = self
    }

    private func configureToolbarPanel(selectionRect: CGRect) {
        let darkAppearance = NSAppearance(named: .darkAqua)
        toolbarPanel.appearance = darkAppearance
        toolbarRoot.appearance = darkAppearance

        configureHUDEffect(mainToolbarEffect, cornerRadius: 10)
        configureHUDEffect(contextPaletteEffect, cornerRadius: 9)

        let mainStack = NSStackView()
        mainStack.orientation = .horizontal
        mainStack.alignment = .centerY
        mainStack.spacing = 3
        mainStack.edgeInsets = NSEdgeInsets(top: 5, left: 7, bottom: 5, right: 7)
        mainStack.translatesAutoresizingMaskIntoConstraints = false

        let rectangleButton = makeToolButton(
            tool: .rectangle,
            symbolName: "square",
            accessibilityLabel: L10n.tr("矩形")
        )
        let ellipseButton = makeToolButton(
            tool: .ellipse,
            symbolName: "circle",
            accessibilityLabel: L10n.tr("椭圆")
        )
        let counterButton = makeToolButton(
            tool: .counter,
            symbolName: "1.circle",
            accessibilityLabel: L10n.tr("序号")
        )
        let arrowButton = makeToolButton(
            tool: .arrow,
            symbolName: "arrow.up.right",
            accessibilityLabel: L10n.tr("箭头（右键可选择直线）")
        )
        let penButton = makeToolButton(
            tool: .pen,
            symbolName: "pencil",
            accessibilityLabel: L10n.tr("画笔（右键可选择荧光笔）")
        )
        let mosaicButton = makeToolButton(
            tool: .mosaic,
            symbolName: "square.grid.3x3.fill",
            accessibilityLabel: L10n.tr("马赛克")
        )
        let textButton = makeToolTitleButton(
            tool: .text,
            title: "T",
            accessibilityLabel: L10n.tr("文字")
        )
        installAlternateToolMenu(
            on: arrowButton,
            tools: [.arrow, .line],
            symbols: [.arrow: "arrow.up.right", .line: "line.diagonal"]
        )
        installAlternateToolMenu(
            on: penButton,
            tools: [.pen, .highlighter],
            symbols: [.pen: "pencil", .highlighter: "highlighter"]
        )

        let toolStack = NSStackView()
        toolStack.orientation = .horizontal
        toolStack.alignment = .centerY
        toolStack.spacing = 2
        [
            rectangleButton,
            ellipseButton,
            counterButton,
            arrowButton,
            penButton,
            mosaicButton,
            textButton
        ].forEach(toolStack.addArrangedSubview)
        mainStack.addArrangedSubview(toolStack)

        mainStack.addArrangedSubview(makeToolbarSeparator())
        mainStack.addArrangedSubview(
            makeIconButton(
                symbolName: "rectangle.dashed",
                accessibilityLabel: L10n.tr("滚动截图"),
                action: #selector(requestScrollCapture)
            )
        )
        mainStack.addArrangedSubview(
            makeIconButton(
                symbolName: "text.viewfinder",
                accessibilityLabel: L10n.tr("识别文字"),
                action: #selector(recognizeText)
            )
        )
        configureIconButton(
            qrCodeButton,
            symbolName: "qrcode.viewfinder",
            accessibilityLabel: L10n.tr("识别二维码"),
            action: #selector(recognizeQRCode)
        )
        mainStack.addArrangedSubview(qrCodeButton)
        mainStack.addArrangedSubview(makeToolbarSeparator())
        mainStack.addArrangedSubview(
            makeIconButton(
                symbolName: "minus.magnifyingglass",
                accessibilityLabel: L10n.tr("缩小（⌘-）"),
                action: #selector(zoomOut)
            )
        )
        mainStack.addArrangedSubview(
            makeIconButton(
                symbolName: "plus.magnifyingglass",
                accessibilityLabel: L10n.tr("放大（⌘+，⌘0 适应选区）"),
                action: #selector(zoomIn)
            )
        )
        mainStack.addArrangedSubview(
            makeIconButton(
                symbolName: "square.on.square",
                accessibilityLabel: L10n.tr("复制"),
                action: #selector(copyImage)
            )
        )

        mainStack.addArrangedSubview(makeToolbarSeparator())
        configureIconButton(
            undoButton,
            symbolName: "arrow.uturn.backward",
            accessibilityLabel: L10n.tr("撤销"),
            action: #selector(undo)
        )
        mainStack.addArrangedSubview(undoButton)
        mainStack.addArrangedSubview(
            makeIconButton(
                symbolName: "pin",
                accessibilityLabel: L10n.tr("钉图"),
                action: #selector(pinImage)
            )
        )
        let shareButton = makeIconButton(
            symbolName: "square.and.arrow.up",
            accessibilityLabel: L10n.tr("分享（右键可保存）"),
            action: #selector(shareImage(_:))
        )
        let shareMenu = NSMenu()
        let saveItem = NSMenuItem(
            title: L10n.tr("保存为 PNG…"),
            action: #selector(saveImage),
            keyEquivalent: ""
        )
        saveItem.image = NSImage(
            systemSymbolName: "square.and.arrow.down",
            accessibilityDescription: L10n.tr("保存")
        )
        saveItem.target = self
        shareMenu.addItem(saveItem)
        shareButton.menu = shareMenu
        mainStack.addArrangedSubview(shareButton)

        mainStack.addArrangedSubview(makeToolbarSeparator())
        mainStack.addArrangedSubview(
            makeIconButton(
                symbolName: "xmark",
                accessibilityLabel: L10n.tr("取消"),
                action: #selector(cancelButtonPressed),
                tintColor: .systemRed
            )
        )
        let doneButton = makeIconButton(
            symbolName: "checkmark",
            accessibilityLabel: L10n.tr("完成并复制"),
            action: #selector(doneButtonPressed),
            tintColor: .systemGreen
        )
        doneButton.keyEquivalent = "\r"
        mainStack.addArrangedSubview(doneButton)

        mainToolbarEffect.addSubview(mainStack)
        NSLayoutConstraint.activate([
            mainStack.leadingAnchor.constraint(equalTo: mainToolbarEffect.leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: mainToolbarEffect.trailingAnchor),
            mainStack.topAnchor.constraint(equalTo: mainToolbarEffect.topAnchor),
            mainStack.bottomAnchor.constraint(equalTo: mainToolbarEffect.bottomAnchor)
        ])

        configureContextPalette()
        configureQRCodeHint()

        toolbarRoot.orientation = .vertical
        toolbarRoot.alignment = .leading
        toolbarRoot.spacing = 5
        toolbarRoot.detachesHiddenViews = true
        toolbarRoot.addArrangedSubview(contextPaletteRow)
        toolbarRoot.addArrangedSubview(mainToolbarEffect)
        toolbarRoot.addArrangedSubview(qrHintRow)
        contextPaletteRow.isHidden = !selectedTool.supportsInlineStylePalette
        qrHintRow.isHidden = true

        toolbarPanel.contentView = toolbarRoot
        toolbarPanel.setFrame(
            screenshotInlineToolbarFrame(
                selectionRect: selectionRect,
                toolbarSize: CGSize(width: 640, height: 44),
                screenFrame: screenFrame
            ),
            display: false
        )
        toolbarPanel.level = NSWindow.Level(
            rawValue: NSWindow.Level.screenSaver.rawValue + 2
        )
        toolbarPanel.backgroundColor = .clear
        toolbarPanel.isOpaque = false
        toolbarPanel.hasShadow = true
        toolbarPanel.hidesOnDeactivate = false
        toolbarPanel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        toolbarPanel.delegate = self
        updateToolSelection()
        updateToolbarFrame()
    }

    private func configureQRCodeHint() {
        configureHUDEffect(qrHintEffect, cornerRadius: 8)

        let icon = NSImageView(image: NSImage(
            systemSymbolName: "qrcode.viewfinder",
            accessibilityDescription: nil
        ) ?? NSImage())
        icon.contentTintColor = .controlAccentColor
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: L10n.tr("检测到二维码，点击上方按钮识别"))
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail

        let content = NSStackView(views: [icon, label])
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 6
        content.edgeInsets = NSEdgeInsets(top: 5, left: 9, bottom: 5, right: 9)
        content.translatesAutoresizingMaskIntoConstraints = false
        qrHintEffect.addSubview(content)

        qrHintPointer.image = NSImage(
            systemSymbolName: "arrowtriangle.up.fill",
            accessibilityDescription: nil
        )
        qrHintPointer.contentTintColor = NSColor(calibratedWhite: 0.11, alpha: 0.97)
        qrHintPointer.imageScaling = .scaleProportionallyDown
        qrHintPointer.translatesAutoresizingMaskIntoConstraints = false
        qrHintEffect.translatesAutoresizingMaskIntoConstraints = false
        qrHintContainer.translatesAutoresizingMaskIntoConstraints = false
        qrHintContainer.addSubview(qrHintPointer)
        qrHintContainer.addSubview(qrHintEffect)

        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 15),
            icon.heightAnchor.constraint(equalToConstant: 15),
            content.leadingAnchor.constraint(equalTo: qrHintEffect.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: qrHintEffect.trailingAnchor),
            content.topAnchor.constraint(equalTo: qrHintEffect.topAnchor),
            content.bottomAnchor.constraint(equalTo: qrHintEffect.bottomAnchor),
            qrHintEffect.leadingAnchor.constraint(equalTo: qrHintContainer.leadingAnchor),
            qrHintEffect.trailingAnchor.constraint(equalTo: qrHintContainer.trailingAnchor),
            qrHintEffect.bottomAnchor.constraint(equalTo: qrHintContainer.bottomAnchor),
            qrHintEffect.heightAnchor.constraint(equalToConstant: 28),
            qrHintPointer.widthAnchor.constraint(equalToConstant: 12),
            qrHintPointer.heightAnchor.constraint(equalToConstant: 7),
            qrHintPointer.centerXAnchor.constraint(equalTo: qrHintContainer.centerXAnchor),
            qrHintPointer.topAnchor.constraint(equalTo: qrHintContainer.topAnchor),
            qrHintPointer.bottomAnchor.constraint(equalTo: qrHintEffect.topAnchor, constant: 1),
            qrHintContainer.widthAnchor.constraint(equalToConstant: Self.qrHintWidth)
        ])

        qrHintLeadingSpacer.translatesAutoresizingMaskIntoConstraints = false
        qrHintLeadingConstraint = qrHintLeadingSpacer.widthAnchor.constraint(equalToConstant: 0)
        qrHintLeadingConstraint?.isActive = true
        qrHintRow.orientation = .horizontal
        qrHintRow.alignment = .top
        qrHintRow.spacing = 0
        qrHintRow.setAccessibilityElement(true)
        qrHintRow.setAccessibilityLabel(L10n.tr("检测到二维码，请点击上方识别二维码按钮"))
        qrHintRow.addArrangedSubview(qrHintLeadingSpacer)
        qrHintRow.addArrangedSubview(qrHintContainer)
    }

    private func configureHUDEffect(
        _ effect: NSVisualEffectView,
        cornerRadius: CGFloat
    ) {
        effect.appearance = NSAppearance(named: .darkAqua)
        effect.material = .hudWindow
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.backgroundColor = NSColor(
            calibratedWhite: 0.11,
            alpha: 0.97
        ).cgColor
        effect.layer?.cornerRadius = cornerRadius
        effect.layer?.borderWidth = 1
        effect.layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
        effect.layer?.masksToBounds = true
    }

    private func configureContextPalette() {
        let styleStack = NSStackView()
        styleStack.orientation = .horizontal
        styleStack.alignment = .centerY
        styleStack.spacing = 4
        styleStack.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        styleStack.translatesAutoresizingMaskIntoConstraints = false

        let colors: [NSColor] = [
            .black,
            .systemRed,
            .systemYellow,
            .systemGreen,
            .systemPurple,
            .white
        ]
        colorSwatchButtons = colors.enumerated().map { index, color in
            let button = ScreenshotColorSwatchButton(color: color)
            button.tag = index
            button.target = self
            button.action = #selector(colorSwatchSelected(_:))
            button.toolTip = L10n.tr("选择颜色")
            button.setAccessibilityLabel(L10n.tr("颜色 %d", index + 1))
            return button
        }
        colorSwatchButtons.forEach(styleStack.addArrangedSubview)

        colorWheelButton.image = NSImage(named: "ToolbarColorWheel")
        colorWheelButton.imagePosition = .imageOnly
        colorWheelButton.isBordered = false
        configureScreenshotPaletteButtonFocus(colorWheelButton)
        colorWheelButton.target = self
        colorWheelButton.action = #selector(showColorPanel)
        colorWheelButton.toolTip = L10n.tr("更多颜色")
        colorWheelButton.setAccessibilityLabel(L10n.tr("更多颜色"))
        colorWheelButton.wantsLayer = true
        colorWheelButton.layer?.cornerRadius = 9
        colorWheelButton.translatesAutoresizingMaskIntoConstraints = false
        styleStack.addArrangedSubview(colorWheelButton)
        styleStack.addArrangedSubview(makeToolbarSeparator(height: 20))

        let widthStack = NSStackView()
        widthStack.orientation = .horizontal
        widthStack.alignment = .centerY
        widthStack.spacing = 2
        widthButtons = lineWidths.enumerated().map { index, width in
            let button = ScreenshotStyleOptionButton(
                image: lineWidthImage(width),
                accessibilityLabel: L10n.tr("线宽 %d", Int(width))
            )
            button.tag = index
            button.target = self
            button.action = #selector(widthOptionSelected(_:))
            button.isOptionSelected = index == selectedWidthIndex
            return button
        }
        widthButtons.forEach(widthStack.addArrangedSubview)
        widthStack.setAccessibilityLabel(L10n.tr("标注粗细"))
        styleStack.addArrangedSubview(widthStack)
        styleStack.addArrangedSubview(makeToolbarSeparator(height: 20))

        let fillStack = NSStackView()
        fillStack.orientation = .horizontal
        fillStack.alignment = .centerY
        fillStack.spacing = 2
        let fillOptions: [(ScreenshotAnnotationStyle.ShapeFill, String, String)] = [
            (.filled, "circle.fill", L10n.tr("填充形状")),
            (.outline, "circle.dashed", L10n.tr("仅描边"))
        ]
        fillButtons = fillOptions.enumerated().map { index, option in
            let button = ScreenshotStyleOptionButton(
                image: NSImage(
                    systemSymbolName: option.1,
                    accessibilityDescription: option.2
                ) ?? NSImage(),
                accessibilityLabel: option.2,
                width: 28
            )
            button.tag = index
            button.target = self
            button.action = #selector(fillOptionSelected(_:))
            button.isOptionSelected = option.0 == selectedShapeFill
            return button
        }
        fillButtons.forEach(fillStack.addArrangedSubview)
        fillStack.setAccessibilityLabel(L10n.tr("形状填充方式"))
        styleStack.addArrangedSubview(fillStack)

        contextPaletteEffect.addSubview(styleStack)
        NSLayoutConstraint.activate([
            styleStack.leadingAnchor.constraint(equalTo: contextPaletteEffect.leadingAnchor),
            styleStack.trailingAnchor.constraint(equalTo: contextPaletteEffect.trailingAnchor),
            styleStack.topAnchor.constraint(equalTo: contextPaletteEffect.topAnchor),
            styleStack.bottomAnchor.constraint(equalTo: contextPaletteEffect.bottomAnchor),
            colorWheelButton.widthAnchor.constraint(equalToConstant: 18),
            colorWheelButton.heightAnchor.constraint(equalToConstant: 18)
        ])

        contextPaletteRow.orientation = .horizontal
        contextPaletteRow.alignment = .centerY
        contextPaletteRow.spacing = 0
        let indent = NSView()
        indent.translatesAutoresizingMaskIntoConstraints = false
        indent.widthAnchor.constraint(equalToConstant: 120).isActive = true

        contextPaletteContainer.translatesAutoresizingMaskIntoConstraints = false
        contextPaletteEffect.translatesAutoresizingMaskIntoConstraints = false
        contextPaletteContainer.addSubview(contextPaletteEffect)
        contextPointer.image = NSImage(
            systemSymbolName: "arrowtriangle.down.fill",
            accessibilityDescription: nil
        )
        contextPointer.contentTintColor = NSColor(calibratedWhite: 0.11, alpha: 0.97)
        contextPointer.imageScaling = .scaleProportionallyDown
        contextPointer.translatesAutoresizingMaskIntoConstraints = false
        contextPaletteContainer.addSubview(contextPointer)

        contextPointerLeadingConstraint = contextPointer.leadingAnchor.constraint(
            equalTo: contextPaletteContainer.leadingAnchor,
            constant: 116
        )
        NSLayoutConstraint.activate([
            contextPointer.widthAnchor.constraint(equalToConstant: 14),
            contextPointer.heightAnchor.constraint(equalToConstant: 8),
            contextPointerLeadingConstraint!,
            contextPaletteEffect.leadingAnchor.constraint(equalTo: contextPaletteContainer.leadingAnchor),
            contextPaletteEffect.trailingAnchor.constraint(equalTo: contextPaletteContainer.trailingAnchor),
            contextPaletteEffect.topAnchor.constraint(equalTo: contextPaletteContainer.topAnchor),
            contextPaletteEffect.bottomAnchor.constraint(equalTo: contextPointer.topAnchor, constant: 1),
            contextPointer.bottomAnchor.constraint(equalTo: contextPaletteContainer.bottomAnchor)
        ])

        contextPaletteRow.addArrangedSubview(indent)
        contextPaletteRow.addArrangedSubview(contextPaletteContainer)
    }

    private func bindActions() {
        canvas.onTextRequested = { [weak self] point in
            self?.requestText(at: point)
        }
        canvas.onDoubleClick = { [weak self] in
            self?.completeAndCopy()
        }
        canvas.onCommitRequested = { [weak self] in
            self?.completeAndCopy()
        }
        canvas.onCancelRequested = { [weak self] in
            self?.finish(with: nil)
        }
        annotationDocument.onChange = { [weak self] in
            self?.refreshDocumentState()
        }
        canvas.tool = selectedTool
        applyStyle()
        refreshColorSelection()
        refreshDocumentState()
    }

    private func makeToolButton(
        tool: ScreenshotAnnotationTool,
        symbolName: String,
        accessibilityLabel: String
    ) -> NSButton {
        let button = makeIconButton(
            symbolName: symbolName,
            accessibilityLabel: accessibilityLabel,
            action: #selector(toolButtonPressed(_:))
        )
        button.tag = tool.rawValue
        toolButtons[tool] = button
        toolControls[tool] = button
        return button
    }

    private func installAlternateToolMenu(
        on button: NSButton,
        tools: [ScreenshotAnnotationTool],
        symbols: [ScreenshotAnnotationTool: String]
    ) {
        let menu = NSMenu()
        for tool in tools {
            let item = NSMenuItem(
                title: tool.title,
                action: #selector(toolMenuItemSelected(_:)),
                keyEquivalent: ""
            )
            item.tag = tool.rawValue
            item.target = self
            item.image = symbols[tool].flatMap {
                NSImage(systemSymbolName: $0, accessibilityDescription: tool.title)
            }
            menu.addItem(item)
            toolControls[tool] = button
        }
        button.menu = menu
    }

    private func makeToolTitleButton(
        tool: ScreenshotAnnotationTool,
        title: String,
        accessibilityLabel: String
    ) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(toolButtonPressed(_:)))
        button.tag = tool.rawValue
        button.isBordered = false
        button.font = .systemFont(ofSize: 18, weight: .medium)
        button.wantsLayer = true
        button.layer?.cornerRadius = 7
        button.toolTip = accessibilityLabel
        button.setAccessibilityLabel(accessibilityLabel)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 34).isActive = true
        button.heightAnchor.constraint(equalToConstant: 34).isActive = true
        toolButtons[tool] = button
        toolControls[tool] = button
        return button
    }

    private func makeToolMenuButton(
        tools: [ScreenshotAnnotationTool],
        symbols: [ScreenshotAnnotationTool: String],
        accessibilityLabel: String
    ) -> ScreenshotToolMenuButton {
        let button = ScreenshotToolMenuButton(
            tools: tools,
            symbols: symbols,
            selectedTool: tools[0]
        )
        let menu = NSMenu()
        for tool in tools {
            let item = NSMenuItem(
                title: tool.title,
                action: #selector(toolMenuItemSelected(_:)),
                keyEquivalent: ""
            )
            item.tag = tool.rawValue
            item.target = self
            item.image = symbols[tool].flatMap {
                NSImage(systemSymbolName: $0, accessibilityDescription: tool.title)
            }
            menu.addItem(item)
            toolControls[tool] = button
        }
        button.menu = menu
        button.target = self
        button.action = #selector(toolMenuButtonPressed(_:))
        button.toolTip = accessibilityLabel
        button.setAccessibilityLabel(accessibilityLabel)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 62).isActive = true
        button.heightAnchor.constraint(equalToConstant: 42).isActive = true
        toolMenuButtons.append(button)
        return button
    }

    private func makeIconButton(
        symbolName: String,
        accessibilityLabel: String,
        action: Selector,
        tintColor: NSColor = .labelColor
    ) -> NSButton {
        let button = NSButton(
            image: NSImage(
                systemSymbolName: symbolName,
                accessibilityDescription: accessibilityLabel
            ) ?? NSImage(),
            target: self,
            action: action
        )
        configureIconButton(
            button,
            symbolName: symbolName,
            accessibilityLabel: accessibilityLabel,
            action: action,
            tintColor: tintColor
        )
        return button
    }

    private func configureIconButton(
        _ button: NSButton,
        symbolName: String,
        accessibilityLabel: String,
        action: Selector,
        tintColor: NSColor = .labelColor
    ) {
        let symbol = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: accessibilityLabel
        )
        let symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 18,
            weight: .medium
        ).applying(
            NSImage.SymbolConfiguration(hierarchicalColor: tintColor)
        )
        button.image = symbol?.withSymbolConfiguration(
            symbolConfiguration
        )
        button.image?.isTemplate = tintColor == .labelColor
        button.title = ""
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.target = self
        button.action = action
        button.wantsLayer = true
        button.layer?.cornerRadius = 7
        button.contentTintColor = tintColor
        button.toolTip = accessibilityLabel
        button.setAccessibilityLabel(accessibilityLabel)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 34).isActive = true
        button.heightAnchor.constraint(equalToConstant: 34).isActive = true
    }

    private func makeUndoRedoGroup() -> NSView {
        let stack = NSStackView(views: [undoButton, redoButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.075).cgColor
        container.layer?.cornerRadius = 10
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 3),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -3),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(equalToConstant: 86),
            container.heightAnchor.constraint(equalToConstant: 42)
        ])
        return container
    }

    private func applyActionButtonBackground(_ button: NSButton) {
        button.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.075).cgColor
        button.layer?.borderWidth = 1
        button.layer?.borderColor = NSColor.white.withAlphaComponent(0.055).cgColor
        button.layer?.cornerRadius = 10
    }

    private func makeTextButton(
        title: String,
        symbolName: String?,
        accessibilityLabel: String,
        action: Selector
    ) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.isBordered = false
        button.font = .systemFont(ofSize: 14, weight: .semibold)
        button.image = symbolName.flatMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: accessibilityLabel)
        }
        button.imagePosition = symbolName == nil ? .noImage : .imageLeading
        button.imageHugsTitle = true
        button.contentTintColor = .labelColor
        button.wantsLayer = true
        button.layer?.cornerRadius = 8
        button.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.075).cgColor
        button.layer?.borderWidth = 1
        button.layer?.borderColor = NSColor.white.withAlphaComponent(0.06).cgColor
        button.toolTip = accessibilityLabel
        button.setAccessibilityLabel(accessibilityLabel)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 42).isActive = true
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: title == "OCR" ? 54 : 76)
            .isActive = true
        return button
    }

    private func makeCompletionControl() -> NSView {
        let doneButton = NSButton(
            title: L10n.tr("完成"),
            target: self,
            action: #selector(doneButtonPressed)
        )
        doneButton.keyEquivalent = "\r"
        doneButton.isBordered = false
        doneButton.font = .systemFont(ofSize: 14, weight: .semibold)
        doneButton.contentTintColor = .white
        doneButton.attributedTitle = NSAttributedString(
            string: L10n.tr("完成"),
            attributes: [
                .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
                .foregroundColor: NSColor.white
            ]
        )
        doneButton.wantsLayer = true
        doneButton.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        doneButton.layer?.cornerRadius = 8
        doneButton.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        doneButton.toolTip = L10n.tr("完成并复制")
        doneButton.setAccessibilityLabel(L10n.tr("完成并复制"))
        doneButton.translatesAutoresizingMaskIntoConstraints = false
        doneButton.widthAnchor.constraint(equalToConstant: 58).isActive = true
        doneButton.heightAnchor.constraint(equalToConstant: 42).isActive = true

        let moreButton = NSButton(
            image: NSImage(
                systemSymbolName: "chevron.down",
                accessibilityDescription: L10n.tr("更多完成操作")
            ) ?? NSImage(),
            target: self,
            action: #selector(completionMenuButtonPressed(_:))
        )
        let completionMenu = NSMenu()
        let saveItem = NSMenuItem(
            title: L10n.tr("保存为 PNG…"),
            action: #selector(saveImage),
            keyEquivalent: "s"
        )
        saveItem.keyEquivalentModifierMask = [.command, .shift]
        saveItem.image = NSImage(
            systemSymbolName: "square.and.arrow.down",
            accessibilityDescription: L10n.tr("保存")
        )
        saveItem.target = self
        completionMenu.addItem(saveItem)
        completionMenu.addItem(.separator())
        let cancelItem = NSMenuItem(
            title: L10n.tr("取消截图"),
            action: #selector(cancelButtonPressed),
            keyEquivalent: "\u{1b}"
        )
        cancelItem.image = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: L10n.tr("取消截图")
        )
        cancelItem.target = self
        completionMenu.addItem(cancelItem)
        moreButton.menu = completionMenu
        moreButton.imagePosition = .imageOnly
        moreButton.isBordered = false
        moreButton.contentTintColor = .white
        moreButton.wantsLayer = true
        moreButton.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        moreButton.layer?.cornerRadius = 8
        moreButton.layer?.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        moreButton.toolTip = L10n.tr("保存或取消")
        moreButton.setAccessibilityLabel(L10n.tr("更多完成操作"))
        moreButton.translatesAutoresizingMaskIntoConstraints = false
        moreButton.widthAnchor.constraint(equalToConstant: 28).isActive = true
        moreButton.heightAnchor.constraint(equalToConstant: 42).isActive = true

        let stack = NSStackView(views: [doneButton, moreButton])
        stack.orientation = .horizontal
        stack.spacing = 1
        stack.alignment = .centerY
        return stack
    }

    private func makeToolbarSeparator(height: CGFloat = 20) -> NSBox {
        let separator = NSBox.verticalSeparator()
        separator.heightAnchor.constraint(equalToConstant: height).isActive = true
        separator.alphaValue = 0.58
        return separator
    }

    private func lineWidthImage(_ width: CGFloat) -> NSImage {
        let size = CGSize(width: 16, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            let diameter = min(14, max(3, width * 1.5 + 1))
            NSColor.labelColor.setFill()
            NSBezierPath(
                ovalIn: CGRect(
                    x: rect.midX - diameter / 2,
                    y: rect.midY - diameter / 2,
                    width: diameter,
                    height: diameter
                )
            ).fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    @objc private func toolButtonPressed(_ sender: NSButton) {
        guard let tool = ScreenshotAnnotationTool(rawValue: sender.tag) else { return }
        selectTool(tool)
    }

    @objc private func toolMenuButtonPressed(_ sender: ScreenshotToolMenuButton) {
        sender.menu?.popUp(
            positioning: sender.menu?.item(withTag: sender.selectedTool.rawValue),
            at: CGPoint(x: 0, y: sender.bounds.maxY + 4),
            in: sender
        )
    }

    @objc private func toolMenuItemSelected(_ sender: NSMenuItem) {
        guard let tool = ScreenshotAnnotationTool(rawValue: sender.tag) else { return }
        selectTool(tool)
    }

    private func selectTool(_ tool: ScreenshotAnnotationTool) {
        selectedTool = tool
        canvas.tool = tool
        updateToolSelection()
        contextPaletteRow.isHidden = !tool.supportsInlineStylePalette
        updateToolbarFrame()
        canvasPanel.makeKeyAndOrderFront(nil)
        canvasPanel.makeFirstResponder(canvas)
    }

    private func updateToolSelection() {
        for (tool, button) in toolButtons {
            let selected = tool == selectedTool
            button.state = .off
            button.setAccessibilityValue(selected ? L10n.tr("已选择") : L10n.tr("未选择"))
            button.contentTintColor = selected
                ? .controlAccentColor
                : .labelColor
            if tool == .text {
                button.attributedTitle = NSAttributedString(
                    string: "T",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 18, weight: .medium),
                        .foregroundColor: selected
                            ? NSColor.white
                            : NSColor.labelColor
                    ]
                )
            }
            button.layer?.backgroundColor = selected
                ? NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
                : NSColor.clear.cgColor
            button.layer?.borderWidth = selected ? 1.5 : 0
            button.layer?.borderColor = selected
                ? NSColor.controlAccentColor.cgColor
                : NSColor.clear.cgColor
            button.contentTintColor = selected ? .white : .labelColor
        }
        for button in toolMenuButtons {
            let selected = button.tools.contains(selectedTool)
            if selected {
                button.selectedTool = selectedTool
            }
            button.contentTintColor = .labelColor
            button.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.075).cgColor
            button.layer?.borderWidth = selected ? 1.5 : 1
            button.layer?.borderColor = selected
                ? NSColor.controlAccentColor.cgColor
                : NSColor.white.withAlphaComponent(0.055).cgColor
        }
    }

    private func updateToolbarFrame() {
        toolbarRoot.needsLayout = true
        toolbarRoot.layoutSubtreeIfNeeded()
        mainToolbarEffect.layoutSubtreeIfNeeded()
        contextPaletteEffect.layoutSubtreeIfNeeded()
        let fitting = toolbarRoot.fittingSize
        let requestedSize = CGSize(
            width: max(1, fitting.width),
            height: max(44, fitting.height)
        )
        let frame = screenshotInlineToolbarFrame(
            selectionRect: selectionRect,
            toolbarSize: requestedSize,
            screenFrame: screenFrame
        )
        toolbarPanel.setFrame(frame, display: toolbarPanel.isVisible, animate: false)
        toolbarRoot.frame = CGRect(origin: .zero, size: frame.size)
        toolbarRoot.layoutSubtreeIfNeeded()
        updateContextPointerPosition()
        updateQRCodeHintPosition(toolbarWidth: frame.width)
    }

    private func updateContextPointerPosition() {
        guard selectedTool.supportsInlineStylePalette,
              let control = toolControls[selectedTool],
              let constraint = contextPointerLeadingConstraint else {
            return
        }
        let controlFrame = control.convert(control.bounds, to: toolbarRoot)
        let paletteFrame = contextPaletteEffect.convert(
            contextPaletteEffect.bounds,
            to: toolbarRoot
        )
        let desired = controlFrame.midX - paletteFrame.minX - 8
        constraint.constant = min(
            max(12, desired),
            max(12, paletteFrame.width - 28)
        )
    }

    private func updateQRCodeHintPosition(toolbarWidth: CGFloat) {
        guard !qrHintRow.isHidden, let qrHintLeadingConstraint else { return }
        let buttonFrame = qrCodeButton.convert(qrCodeButton.bounds, to: toolbarRoot)
        qrHintLeadingConstraint.constant = screenshotQRCodeHintLeadingOffset(
            buttonMidX: buttonFrame.midX,
            hintWidth: Self.qrHintWidth,
            toolbarWidth: toolbarWidth
        )
        toolbarRoot.layoutSubtreeIfNeeded()
    }

    private func startQRCodeHintDetection() {
        qrDetectionTask?.cancel()
        let image = sourceImage
        qrDetectionTask = Task { [weak self] in
            do {
                let containsQRCode = try await PEEKQRCodeService()
                    .containsQRCode(image: image)
                try Task.checkCancellation()
                guard containsQRCode, let self, !self.didComplete else { return }
                self.showQRCodeHint()
            } catch is CancellationError {
                // Closing or completing the transient screenshot editor should
                // silently cancel the advisory probe.
            } catch {
                // A hint is optional. Recognition errors remain visible only
                // after the user explicitly presses the QR button.
            }
        }
    }

    private func showQRCodeHint() {
        guard qrHintRow.isHidden, !didComplete else { return }
        qrHintRow.isHidden = false
        qrCodeButton.toolTip = L10n.tr("检测到二维码，点击识别")
        qrCodeButton.setAccessibilityHelp(L10n.tr("选区中检测到二维码，点击后查看识别结果"))
        qrCodeButton.layer?.backgroundColor = NSColor.controlAccentColor
            .withAlphaComponent(0.16)
            .cgColor
        qrCodeButton.layer?.borderWidth = 1
        qrCodeButton.layer?.borderColor = NSColor.controlAccentColor.cgColor
        updateToolbarFrame()
    }

    @objc private func colorSwatchSelected(_ sender: ScreenshotColorSwatchButton) {
        selectedColor = sender.swatchColor
        applyStyle()
        refreshColorSelection()
        canvasPanel.makeFirstResponder(canvas)
    }

    @objc private func showColorPanel() {
        let panel = NSColorPanel.shared
        ownsColorPanel = true
        if originalColorPanelLevel == nil {
            originalColorPanelLevel = panel.level
        }
        panel.color = selectedColor
        panel.setTarget(self)
        panel.setAction(#selector(customColorChanged(_:)))
        panel.level = screenshotFloatingColorPanelLevel(
            toolbarLevel: toolbarPanel.level
        )
        panel.hidesOnDeactivate = false
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func customColorChanged(_ sender: NSColorPanel) {
        selectedColor = sender.color
        applyStyle()
        refreshColorSelection()
    }

    @objc private func widthOptionSelected(_ sender: ScreenshotStyleOptionButton) {
        guard lineWidths.indices.contains(sender.tag) else { return }
        selectedWidthIndex = sender.tag
        widthButtons.enumerated().forEach { index, button in
            button.isOptionSelected = index == selectedWidthIndex
        }
        applyStyle()
        canvasPanel.makeFirstResponder(canvas)
    }

    @objc private func fillOptionSelected(_ sender: ScreenshotStyleOptionButton) {
        selectedShapeFill = sender.tag == 0 ? .filled : .outline
        fillButtons.enumerated().forEach { index, button in
            button.isOptionSelected = index == sender.tag
        }
        applyStyle()
        canvasPanel.makeFirstResponder(canvas)
    }

    @objc private func undo() {
        annotationDocument.undo()
        canvasPanel.makeFirstResponder(canvas)
    }

    @objc private func redo() {
        annotationDocument.redo()
        canvasPanel.makeFirstResponder(canvas)
    }

    @objc private func zoomIn() {
        canvas.zoomIn()
        canvasPanel.makeKeyAndOrderFront(nil)
        canvasPanel.makeFirstResponder(canvas)
    }

    @objc private func zoomOut() {
        canvas.zoomOut()
        canvasPanel.makeKeyAndOrderFront(nil)
        canvasPanel.makeFirstResponder(canvas)
    }

    @objc private func pinImage() {
        guard let image = annotationDocument.renderedImage() else { return }
        onAction?(.pinRequested(image))
        finish(with: nil)
    }

    @objc private func recognizeText() {
        guard let image = annotationDocument.renderedImage() else { return }
        onAction?(.ocrRequested(image))
        finish(with: nil)
    }

    @objc private func recognizeQRCode() {
        qrDetectionTask?.cancel()
        qrDetectionTask = nil
        guard let image = annotationDocument.renderedImage() else { return }
        onAction?(.qrCodeRequested(image))
        finish(with: nil)
    }

    @objc private func requestScrollCapture() {
        guard let image = annotationDocument.renderedImage() else { return }
        onAction?(.scrollCaptureRequestedInSelection(image, selectionRect))
        finish(with: nil)
    }

    @objc private func copyImage() {
        guard let image = annotationDocument.renderedImage(), copyToPasteboard(image) else {
            NSSound.beep()
            return
        }
        onAction?(.copied(image))
        finish(with: nil)
    }

    @objc private func saveImage() {
        guard let image = annotationDocument.renderedImage() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "PEEK_\(Self.filenameTimestamp()).png"
        panel.beginSheetModal(for: toolbarPanel) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try Self.writePNG(image, to: url)
                self?.onAction?(.saved(image, url))
                self?.finish(with: nil)
            } catch {
                self?.presentSaveError(error)
            }
        }
    }

    @objc private func shareImage(_ sender: NSButton) {
        guard let image = annotationDocument.renderedImage() else { return }
        let picker = NSSharingServicePicker(items: [image])
        picker.show(
            relativeTo: sender.bounds,
            of: sender,
            preferredEdge: .maxY
        )
    }

    @objc private func cancelButtonPressed() {
        finish(with: nil)
    }

    @objc private func completionMenuButtonPressed(_ sender: NSButton) {
        sender.menu?.popUp(
            positioning: nil,
            at: CGPoint(x: sender.bounds.minX, y: sender.bounds.maxY + 4),
            in: sender
        )
    }

    @objc private func doneButtonPressed() {
        completeAndCopy()
    }

    private func completeAndCopy() {
        guard let image = annotationDocument.renderedImage() else {
            NSSound.beep()
            return
        }
        guard copyToPasteboard(image) else {
            NSSound.beep()
            return
        }
        onAction?(.copied(image))
        finish(with: image)
    }

    private func copyToPasteboard(_ image: NSImage) -> Bool {
        writeScreenshotImageToPasteboard(image)
    }

    private func applyStyle() {
        let selectedWidth: CGFloat
        if lineWidths.indices.contains(selectedWidthIndex) {
            selectedWidth = lineWidths[selectedWidthIndex]
        } else {
            selectedWidth = 3
        }
        canvas.style = ScreenshotAnnotationStyle(
            color: selectedColor,
            lineWidth: selectedWidth,
            fontSize: max(16, selectedWidth * 5 + 8),
            shapeFill: selectedShapeFill
        )
    }

    private func refreshColorSelection() {
        guard let selected = selectedColor.usingColorSpace(.deviceRGB) else {
            colorSwatchButtons.forEach { $0.isSwatchSelected = false }
            return
        }
        for button in colorSwatchButtons {
            button.isSwatchSelected = button.swatchColor
                .usingColorSpace(.deviceRGB)?
                .isEqual(selected) == true
        }
        colorWheelButton.layer?.borderWidth = colorSwatchButtons.contains { $0.isSwatchSelected }
            ? 0
            : 2
        colorWheelButton.layer?.borderColor = NSColor.controlAccentColor.cgColor
    }

    private func refreshDocumentState() {
        undoButton.isEnabled = annotationDocument.canUndo
        redoButton.isEnabled = annotationDocument.canRedo
        canvas.needsDisplay = true
    }

    private func requestText(at point: CGPoint) {
        let alert = NSAlert()
        alert.messageText = L10n.tr("添加文字")
        alert.informativeText = L10n.tr("输入要显示在截图上的文字。")
        alert.addButton(withTitle: L10n.tr("添加"))
        alert.addButton(withTitle: L10n.tr("取消"))
        let field = NSTextField(frame: CGRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = L10n.tr("文字内容")
        alert.accessoryView = field
        alert.beginSheetModal(for: toolbarPanel) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.canvas.addText(field.stringValue, at: point)
            self?.canvasPanel.makeKeyAndOrderFront(nil)
            self?.canvasPanel.makeFirstResponder(self?.canvas)
        }
        DispatchQueue.main.async {
            alert.window.makeFirstResponder(field)
        }
    }

    private func presentSaveError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.beginSheetModal(for: toolbarPanel)
    }

    private func finish(with image: NSImage?, closePanels: Bool = true) {
        guard !didComplete else { return }
        didComplete = true
        qrDetectionTask?.cancel()
        qrDetectionTask = nil
        annotationDocument.onChange = nil
        canvas.onTextRequested = nil
        canvas.onDoubleClick = nil
        canvas.onCommitRequested = nil
        canvas.onCancelRequested = nil
        if ownsColorPanel {
            NSColorPanel.shared.setTarget(nil)
            NSColorPanel.shared.setAction(nil)
            NSColorPanel.shared.orderOut(nil)
            if let originalColorPanelLevel {
                NSColorPanel.shared.level = originalColorPanelLevel
            }
        }
        canvasPanel.delegate = nil
        toolbarPanel.delegate = nil
        if closePanels {
            canvasPanel.orderOut(nil)
            toolbarPanel.orderOut(nil)
            canvasPanel.close()
            toolbarPanel.close()
        }
        completion(image)
    }

    private static func writePNG(_ image: NSImage, to url: URL) throws {
        guard let tiff = image.tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiff),
              let data = representation.representation(using: .png, properties: [:]) else {
            throw ScreenshotCaptureError.imageRenderingFailed
        }
        try data.write(to: url, options: .atomic)
    }

    private static func filenameTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: Date())
    }
}

@MainActor
private final class ScreenshotStyleOptionButton: NSButton {
    var isOptionSelected = false {
        didSet { updateAppearance() }
    }

    init(
        image: NSImage,
        accessibilityLabel: String,
        width: CGFloat = 24
    ) {
        super.init(frame: .zero)
        self.image = image
        imagePosition = .imageOnly
        isBordered = false
        configureScreenshotPaletteButtonFocus(self)
        contentTintColor = .labelColor
        toolTip = accessibilityLabel
        setAccessibilityLabel(accessibilityLabel)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: width).isActive = true
        heightAnchor.constraint(equalToConstant: 24).isActive = true
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        layer?.cornerRadius = 6
        layer?.backgroundColor = isOptionSelected
            ? NSColor.white.withAlphaComponent(0.07).cgColor
            : NSColor.clear.cgColor
        layer?.borderWidth = isOptionSelected ? 1.5 : 0
        layer?.borderColor = isOptionSelected
            ? NSColor.controlAccentColor.cgColor
            : NSColor.clear.cgColor
    }
}

@MainActor
private final class ScreenshotToolMenuButton: NSButton {
    let tools: [ScreenshotAnnotationTool]
    private let symbols: [ScreenshotAnnotationTool: String]

    var selectedTool: ScreenshotAnnotationTool {
        didSet { updateSymbol() }
    }

    init(
        tools: [ScreenshotAnnotationTool],
        symbols: [ScreenshotAnnotationTool: String],
        selectedTool: ScreenshotAnnotationTool
    ) {
        self.tools = tools
        self.symbols = symbols
        self.selectedTool = selectedTool
        super.init(frame: .zero)
        title = ""
        imagePosition = .imageOnly
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.075).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.055).cgColor
        updateSymbol()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSymbol()
    }

    private func updateSymbol() {
        guard let symbolName = symbols[selectedTool],
              let primary = NSImage(
                systemSymbolName: symbolName,
                accessibilityDescription: selectedTool.title
              ),
              let chevron = NSImage(
                systemSymbolName: "chevron.down",
                accessibilityDescription: nil
              ) else {
            image = nil
            return
        }

        let composed = NSImage(size: CGSize(width: 36, height: 22), flipped: false) { rect in
            primary.draw(
                in: CGRect(x: rect.minX, y: rect.minY + 1, width: 20, height: 20),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
            chevron.draw(
                in: CGRect(x: rect.maxX - 9, y: rect.midY - 4, width: 9, height: 8),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
            return true
        }
        composed.isTemplate = true
        image = composed
        setAccessibilityValue(selectedTool.title)
    }
}

@MainActor
private final class ScreenshotColorSwatchButton: NSButton {
    let swatchColor: NSColor

    var isSwatchSelected = false {
        didSet { updateAppearance() }
    }

    init(color: NSColor) {
        swatchColor = color
        super.init(frame: .zero)
        title = ""
        isBordered = false
        configureScreenshotPaletteButtonFocus(self)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 18).isActive = true
        heightAnchor.constraint(equalToConstant: 18).isActive = true
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        layer?.cornerRadius = 9
        layer?.backgroundColor = swatchColor.cgColor
        layer?.borderWidth = isSwatchSelected ? 2.5 : 1
        layer?.borderColor = isSwatchSelected
            ? NSColor.controlAccentColor.cgColor
            : NSColor.white.withAlphaComponent(0.35).cgColor
    }
}

@MainActor
private final class ScreenshotEditorWindowController: NSWindowController, NSWindowDelegate {
    private let annotationDocument: ScreenshotAnnotationDocument
    private let canvas: ScreenshotEditorCanvas
    private let onAction: ((ScreenshotEditorAction) -> Void)?
    private let completion: (NSImage?) -> Void

    private let toolControl: NSSegmentedControl
    private let undoButton = NSButton(title: L10n.tr("撤销"), target: nil, action: nil)
    private let redoButton = NSButton(title: L10n.tr("重做"), target: nil, action: nil)
    private let colorWell = NSColorWell()
    private let widthSlider = NSSlider(value: 3, minValue: 1, maxValue: 12, target: nil, action: nil)
    private var didComplete = false

    init(
        image: NSImage,
        onAction: ((ScreenshotEditorAction) -> Void)?,
        completion: @escaping (NSImage?) -> Void
    ) {
        annotationDocument = ScreenshotAnnotationDocument(baseImage: image)
        canvas = ScreenshotEditorCanvas(document: annotationDocument)
        self.onAction = onAction
        self.completion = completion
        toolControl = NSSegmentedControl(
            labels: ScreenshotAnnotationTool.allCases.map(\.title),
            trackingMode: .selectOne,
            target: nil,
            action: nil
        )

        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.tr("截图编辑")
        window.minSize = CGSize(width: 920, height: 600)
        window.isReleasedWhenClosed = false
        super.init(window: window)

        window.delegate = self
        configureInterface(in: window)
        bindActions()
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(canvas)
    }

    func cancelEditing() {
        finish(with: nil)
    }

    func windowWillClose(_ notification: Notification) {
        finish(with: nil, closeWindow: false)
    }

    private func configureInterface(in window: NSWindow) {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = root

        let annotationBar = NSStackView()
        annotationBar.orientation = .horizontal
        annotationBar.alignment = .centerY
        annotationBar.spacing = 10
        annotationBar.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        annotationBar.translatesAutoresizingMaskIntoConstraints = false

        toolControl.selectedSegment = ScreenshotAnnotationTool.rectangle.rawValue
        toolControl.segmentStyle = .rounded
        toolControl.setContentHuggingPriority(.defaultLow, for: .horizontal)
        annotationBar.addArrangedSubview(toolControl)
        annotationBar.addArrangedSubview(NSBox.verticalSeparator())
        annotationBar.addArrangedSubview(undoButton)
        annotationBar.addArrangedSubview(redoButton)
        annotationBar.addArrangedSubview(colorWell)
        annotationBar.addArrangedSubview(widthSlider)
        annotationBar.addArrangedSubview(NSBox.verticalSeparator())
        annotationBar.addArrangedSubview(makeButton(L10n.tr("缩小"), action: #selector(zoomOut)))
        annotationBar.addArrangedSubview(makeButton(L10n.tr("适应"), action: #selector(resetZoom)))
        annotationBar.addArrangedSubview(makeButton(L10n.tr("放大"), action: #selector(zoomIn)))

        let actionBar = NSStackView()
        actionBar.orientation = .horizontal
        actionBar.alignment = .centerY
        actionBar.spacing = 10
        actionBar.edgeInsets = NSEdgeInsets(top: 9, left: 14, bottom: 9, right: 14)
        actionBar.translatesAutoresizingMaskIntoConstraints = false

        let pinButton = makeButton(L10n.tr("钉图"), action: #selector(pinImage))
        let ocrButton = makeButton("OCR", action: #selector(recognizeText))
        let qrCodeButton = makeButton(L10n.tr("二维码"), action: #selector(recognizeQRCode))
        let scrollButton = makeButton(L10n.tr("滚动截图"), action: #selector(startScrollCapture))
        let copyButton = makeButton(L10n.tr("复制"), action: #selector(copyImage))
        let saveButton = makeButton(L10n.tr("保存…"), action: #selector(saveImage))
        let cancelButton = makeButton(L10n.tr("取消"), action: #selector(cancelButtonPressed))
        let doneButton = makeButton(L10n.tr("完成"), action: #selector(doneButtonPressed))
        doneButton.keyEquivalent = "\r"
        doneButton.bezelStyle = .rounded

        [pinButton, ocrButton, qrCodeButton, scrollButton].forEach(actionBar.addArrangedSubview)
        actionBar.addArrangedSubview(NSView.flexibleSpacer())
        [copyButton, saveButton, cancelButton, doneButton].forEach(actionBar.addArrangedSubview)

        canvas.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(annotationBar)
        root.addSubview(canvas)
        root.addSubview(actionBar)

        NSLayoutConstraint.activate([
            annotationBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            annotationBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            annotationBar.topAnchor.constraint(equalTo: root.topAnchor),
            annotationBar.heightAnchor.constraint(greaterThanOrEqualToConstant: 50),

            canvas.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: annotationBar.bottomAnchor),
            canvas.bottomAnchor.constraint(equalTo: actionBar.topAnchor),

            actionBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            actionBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            actionBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            actionBar.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),

            colorWell.widthAnchor.constraint(equalToConstant: 38),
            widthSlider.widthAnchor.constraint(equalToConstant: 100)
        ])
    }

    private func bindActions() {
        toolControl.target = self
        toolControl.action = #selector(toolChanged)
        undoButton.target = self
        undoButton.action = #selector(undo)
        redoButton.target = self
        redoButton.action = #selector(redo)
        colorWell.color = .systemRed
        colorWell.target = self
        colorWell.action = #selector(styleChanged)
        widthSlider.target = self
        widthSlider.action = #selector(styleChanged)
        canvas.onTextRequested = { [weak self] point in
            self?.requestText(at: point)
        }
        annotationDocument.onChange = { [weak self] in
            self?.refreshDocumentState()
        }
        applyStyle()
        refreshDocumentState()
    }

    private func makeButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    @objc private func toolChanged() {
        guard let tool = ScreenshotAnnotationTool(rawValue: toolControl.selectedSegment) else { return }
        canvas.tool = tool
        window?.makeFirstResponder(canvas)
    }

    @objc private func styleChanged() {
        applyStyle()
        window?.makeFirstResponder(canvas)
    }

    @objc private func undo() {
        annotationDocument.undo()
        window?.makeFirstResponder(canvas)
    }

    @objc private func redo() {
        annotationDocument.redo()
        window?.makeFirstResponder(canvas)
    }

    @objc private func zoomIn() {
        canvas.zoomIn()
        window?.makeFirstResponder(canvas)
    }

    @objc private func zoomOut() {
        canvas.zoomOut()
        window?.makeFirstResponder(canvas)
    }

    @objc private func resetZoom() {
        canvas.resetZoom()
        window?.makeFirstResponder(canvas)
    }

    @objc private func pinImage() {
        guard let image = annotationDocument.renderedImage() else { return }
        onAction?(.pinRequested(image))
    }

    @objc private func recognizeText() {
        guard let image = annotationDocument.renderedImage() else { return }
        onAction?(.ocrRequested(image))
    }

    @objc private func recognizeQRCode() {
        guard let image = annotationDocument.renderedImage() else { return }
        onAction?(.qrCodeRequested(image))
    }

    @objc private func startScrollCapture() {
        guard let image = annotationDocument.renderedImage() else { return }
        onAction?(.scrollCaptureRequested(image))
        // The editor must leave the captured desktop before the scrolling
        // session starts, otherwise its own window contaminates every frame.
        finish(with: nil)
    }

    @objc private func copyImage() {
        guard let image = annotationDocument.renderedImage() else { return }
        guard writeScreenshotImageToPasteboard(image) else {
            NSSound.beep()
            return
        }
        onAction?(.copied(image))
    }

    @objc private func saveImage() {
        guard let window, let image = annotationDocument.renderedImage() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "PEEK_\(Self.filenameTimestamp()).png"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try Self.writePNG(image, to: url)
                self?.onAction?(.saved(image, url))
                self?.finish(with: nil)
            } catch {
                self?.presentSaveError(error)
            }
        }
    }

    @objc private func cancelButtonPressed() {
        finish(with: nil)
    }

    @objc private func doneButtonPressed() {
        guard let image = annotationDocument.renderedImage() else {
            NSSound.beep()
            return
        }
        finish(with: image)
    }

    private func applyStyle() {
        canvas.style = ScreenshotAnnotationStyle(
            color: colorWell.color,
            lineWidth: CGFloat(widthSlider.doubleValue),
            fontSize: max(16, CGFloat(widthSlider.doubleValue) * 5 + 8)
        )
    }

    private func refreshDocumentState() {
        undoButton.isEnabled = annotationDocument.canUndo
        redoButton.isEnabled = annotationDocument.canRedo
        canvas.needsDisplay = true
    }

    private func requestText(at point: CGPoint) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = L10n.tr("添加文字")
        alert.informativeText = L10n.tr("输入要显示在截图上的文字。")
        alert.addButton(withTitle: L10n.tr("添加"))
        alert.addButton(withTitle: L10n.tr("取消"))
        let field = NSTextField(frame: CGRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = L10n.tr("文字内容")
        alert.accessoryView = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.canvas.addText(field.stringValue, at: point)
            self?.window?.makeFirstResponder(self?.canvas)
        }
        DispatchQueue.main.async {
            alert.window.makeFirstResponder(field)
        }
    }

    private func presentSaveError(_ error: Error) {
        guard let window else { return }
        let alert = NSAlert(error: error)
        alert.beginSheetModal(for: window)
    }

    private func finish(with image: NSImage?, closeWindow: Bool = true) {
        guard !didComplete else { return }
        didComplete = true
        annotationDocument.onChange = nil
        canvas.onTextRequested = nil
        if closeWindow {
            window?.orderOut(nil)
            window?.close()
        }
        completion(image)
    }

    private static func writePNG(_ image: NSImage, to url: URL) throws {
        guard let tiff = image.tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiff),
              let data = representation.representation(using: .png, properties: [:]) else {
            throw ScreenshotCaptureError.imageRenderingFailed
        }
        try data.write(to: url, options: .atomic)
    }

    private static func filenameTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: Date())
    }
}

private extension NSBox {
    static func verticalSeparator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: 1).isActive = true
        return box
    }
}

private extension NSView {
    static func flexibleSpacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }
}
