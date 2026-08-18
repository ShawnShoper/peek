import AppKit
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import Vision

enum PEEKQRCodePayload: Equatable, Sendable {
    case text(String)
    case url(URL)
    case image(data: Data, mimeType: String?)

    var kindTitle: String {
        switch self {
        case .text: return L10n.tr("文本")
        case .url: return L10n.tr("网址")
        case .image: return L10n.tr("图片")
        }
    }

    var stringValue: String? {
        switch self {
        case .text(let value): return value
        case .url(let url): return url.absoluteString
        case .image: return nil
        }
    }
}

struct PEEKQRCodeObservation: Identifiable, Equatable, Sendable {
    let id: UUID
    let payload: PEEKQRCodePayload
    let confidence: Float
    let normalizedBoundingBox: CGRect
}

struct PEEKQRCodeResult: Sendable {
    let observations: [PEEKQRCodeObservation]
    let imageSize: CGSize
}

enum PEEKQRCodeError: LocalizedError {
    case imageConversionFailed
    case imageTooLarge(width: Int, height: Int)
    case noQRCodeRecognized
    case unsupportedPayload

    var errorDescription: String? {
        switch self {
        case .imageConversionFailed:
            return L10n.tr("无法读取图片像素数据")
        case let .imageTooLarge(width, height):
            return L10n.tr("图片过大（%d×%d 像素），请截取较小区域后重试", width, height)
        case .noQRCodeRecognized:
            return L10n.tr("选区中没有识别到二维码")
        case .unsupportedPayload:
            return L10n.tr("识别到二维码，但其中没有可显示的文本、网址或图片内容")
        }
    }
}

/// Pure payload classification shared by Vision and unit tests.
enum PEEKQRCodePayloadClassifier {
    private static let maximumEmbeddedImageBytes = 20 * 1_024 * 1_024

    static func classify(string: String?, data: Data? = nil) -> PEEKQRCodePayload? {
        if let data, let image = imagePayload(data: data, mimeHint: nil) {
            return image
        }

        let trimmed = string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            if let embeddedImage = imageDataURLPayload(trimmed) {
                return embeddedImage
            }
            if let url = safeWebURL(trimmed) {
                return .url(url)
            }
            return .text(trimmed)
        }

        if let data,
           let decoded = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !decoded.isEmpty {
            return classify(string: decoded)
        }
        return nil
    }

    private static func safeWebURL(_ string: String) -> URL? {
        guard let components = URLComponents(string: string),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host?.isEmpty == false,
              let url = components.url else {
            return nil
        }
        return url
    }

    private static func imageDataURLPayload(_ string: String) -> PEEKQRCodePayload? {
        guard string.lowercased().hasPrefix("data:image/"),
              let comma = string.firstIndex(of: ",") else {
            return nil
        }
        let metadata = String(string[string.startIndex..<comma])
        let payloadStart = string.index(after: comma)
        let encodedPayload = String(string[payloadStart...])
        let mimeType = metadata
            .dropFirst("data:".count)
            .split(separator: ";", maxSplits: 1)
            .first
            .map(String.init)

        let data: Data?
        if metadata.lowercased().contains(";base64") {
            data = Data(base64Encoded: encodedPayload, options: .ignoreUnknownCharacters)
        } else {
            data = encodedPayload.removingPercentEncoding?.data(using: .utf8)
        }
        guard let data else { return nil }
        return imagePayload(data: data, mimeHint: mimeType)
    }

    private static func imagePayload(
        data: Data,
        mimeHint: String?
    ) -> PEEKQRCodePayload? {
        guard !data.isEmpty, data.count <= maximumEmbeddedImageBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let typeIdentifier = CGImageSourceGetType(source),
              let detectedType = UTType(typeIdentifier as String),
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
            return nil
        }
        let detectedMIME = detectedType.preferredMIMEType
        return .image(data: data, mimeType: detectedMIME ?? mimeHint)
    }
}

/// QR recognition backed only by Apple's Vision framework. No image leaves the Mac.
final class PEEKQRCodeService: @unchecked Sendable {
    typealias QRCodeProbe = @Sendable (CGImage) async throws -> Bool

    private static let defaultQRCodeProbe: QRCodeProbe = { image in
        try await visionQRCodeProbe(image: image)
    }

    private let qrCodeProbe: QRCodeProbe

    init(
        qrCodeProbe: @escaping QRCodeProbe = PEEKQRCodeService.defaultQRCodeProbe
    ) {
        self.qrCodeProbe = qrCodeProbe
    }

    /// Performs a lightweight, local-only probe used by the screenshot
    /// toolbar. It only reports whether a QR code exists; payload parsing and
    /// result presentation still require an explicit user action.
    func containsQRCode(image: NSImage) async throws -> Bool {
        let validated = try validatedImage(from: image)
        return try await qrCodeProbe(validated.image)
    }

    private static func visionQRCodeProbe(image: CGImage) async throws -> Bool {
        let work = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let request = VNDetectBarcodesRequest()
            request.symbologies = [.qr]
            let handler = VNImageRequestHandler(
                cgImage: image,
                orientation: .up
            )
            try handler.perform([request])
            try Task.checkCancellation()
            return request.results?.isEmpty == false
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    func recognize(image: NSImage) async throws -> PEEKQRCodeResult {
        let validated = try validatedImage(from: image)

        return try await Task.detached(priority: .userInitiated) {
            let request = VNDetectBarcodesRequest()
            request.symbologies = [.qr]
            let handler = VNImageRequestHandler(
                cgImage: validated.image,
                orientation: .up
            )
            try handler.perform([request])

            let detected = request.results ?? []
            guard !detected.isEmpty else {
                throw PEEKQRCodeError.noQRCodeRecognized
            }

            let observations = detected.compactMap { observation -> PEEKQRCodeObservation? in
                let payloadData: Data?
                if #available(macOS 14.0, *) {
                    payloadData = observation.payloadData
                } else {
                    payloadData = nil
                }
                guard let payload = PEEKQRCodePayloadClassifier.classify(
                    string: observation.payloadStringValue,
                    data: payloadData
                ) else {
                    return nil
                }
                return PEEKQRCodeObservation(
                    id: UUID(),
                    payload: payload,
                    confidence: observation.confidence,
                    normalizedBoundingBox: observation.boundingBox
                )
            }.sorted(by: Self.readingOrder)

            guard !observations.isEmpty else {
                throw PEEKQRCodeError.unsupportedPayload
            }
            return PEEKQRCodeResult(
                observations: observations,
                imageSize: CGSize(width: validated.width, height: validated.height)
            )
        }.value
    }

    private struct ValidatedImage: @unchecked Sendable {
        let image: CGImage
        let width: Int
        let height: Int
    }

    private func validatedImage(from image: NSImage) throws -> ValidatedImage {
        var proposedRect = NSRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(
            forProposedRect: &proposedRect,
            context: nil,
            hints: nil
        ) else {
            throw PEEKQRCodeError.imageConversionFailed
        }

        let width = cgImage.width
        let height = cgImage.height
        let (pixelCount, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixelCount <= 40_000_000, width <= 20_000, height <= 40_000 else {
            throw PEEKQRCodeError.imageTooLarge(width: width, height: height)
        }
        return ValidatedImage(image: cgImage, width: width, height: height)
    }

    private static func readingOrder(
        _ lhs: PEEKQRCodeObservation,
        _ rhs: PEEKQRCodeObservation
    ) -> Bool {
        let verticalDifference = abs(
            lhs.normalizedBoundingBox.midY - rhs.normalizedBoundingBox.midY
        )
        if verticalDifference <= 0.08 {
            return lhs.normalizedBoundingBox.minX < rhs.normalizedBoundingBox.minX
        }
        return lhs.normalizedBoundingBox.midY > rhs.normalizedBoundingBox.midY
    }
}

@MainActor
final class PEEKQRCodeResultPresenter {
    static let shared = PEEKQRCodeResultPresenter()

    private var controllers: [UUID: PEEKQRCodeResultWindowController] = [:]

    @discardableResult
    func present(
        result: PEEKQRCodeResult,
        image: NSImage,
        title: String = L10n.tr("二维码识别结果")
    ) -> UUID {
        let id = UUID()
        let controller = PEEKQRCodeResultWindowController(
            result: result,
            image: image,
            title: title,
            onClose: { [weak self] in self?.controllers.removeValue(forKey: id) }
        )
        controllers[id] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return id
    }

    func closeAll() {
        Array(controllers.values).forEach { $0.close() }
    }
}

@MainActor
private final class PEEKQRCodeResultWindowController: NSWindowController, NSWindowDelegate {
    private let onClose: () -> Void
    private var didNotifyClose = false

    init(
        result: PEEKQRCodeResult,
        image: NSImage,
        title: String,
        onClose: @escaping () -> Void
    ) {
        self.onClose = onClose
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_220, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1)
        window.minSize = NSSize(width: 860, height: 420)
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(
            rootView: PEEKQRCodeResultView(
                result: result,
                sourceImage: image,
                window: window
            )
        )
    }

    required init?(coder: NSCoder) { nil }

    func windowWillClose(_ notification: Notification) {
        notifyClosedOnce()
    }

    override func close() {
        super.close()
        notifyClosedOnce()
    }

    private func notifyClosedOnce() {
        guard !didNotifyClose else { return }
        didNotifyClose = true
        onClose()
    }
}

private struct PEEKQRCodeResultView: View {
    let result: PEEKQRCodeResult
    let sourceImage: NSImage
    weak var window: NSWindow?

    @State private var selectedIndex = 0
    @State private var editableText: String
    @State private var zoomMultiplier: CGFloat = 1
    @State private var statusMessage = ""
    @State private var isPinned = false

    init(result: PEEKQRCodeResult, sourceImage: NSImage, window: NSWindow) {
        self.result = result
        self.sourceImage = sourceImage
        self.window = window
        _editableText = State(initialValue: result.observations.first?.payload.stringValue ?? "")
    }

    private var selectedObservation: PEEKQRCodeObservation {
        result.observations[min(max(0, selectedIndex), result.observations.count - 1)]
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            HSplitView {
                PEEKQRCodeSourceCanvas(
                    image: sourceImage,
                    observations: result.observations,
                    selectedObservationID: selectedObservation.id,
                    zoomMultiplier: zoomMultiplier
                )
                .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: NSColor(calibratedWhite: 0.115, alpha: 1)))

                resultPanel
                    .frame(minWidth: 280, idealWidth: 310, maxWidth: 360, maxHeight: .infinity)
                    .background(Color(nsColor: NSColor(calibratedWhite: 0.135, alpha: 1)))
            }
        }
        .background(Color(nsColor: NSColor(calibratedWhite: 0.12, alpha: 1)))
        .overlay(alignment: .bottomTrailing) {
            if !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(14)
            }
        }
        .frame(minWidth: 860, minHeight: 420)
        .ignoresSafeArea(.container, edges: .top)
        .onChange(of: selectedIndex) { _ in
            editableText = selectedObservation.payload.stringValue ?? ""
        }
    }

    @ViewBuilder
    private var resultPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Label(selectedObservation.payload.kindTitle, systemImage: payloadSymbol)
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("\(selectedIndex + 1) / \(result.observations.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 14)

            Divider().opacity(0.35)

            switch selectedObservation.payload {
            case .text, .url:
                TextEditor(text: $editableText)
                    .font(.system(size: 16, weight: .regular, design: .monospaced))
                    .foregroundColor(Color(nsColor: .labelColor))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)

                Divider().opacity(0.35)
                HStack(spacing: 10) {
                    Button(L10n.tr("复制"), action: copyCurrent)
                    if case .url = selectedObservation.payload {
                        Button(L10n.tr("打开地址"), action: openCurrentURL)
                            .buttonStyle(.borderedProminent)
                    }
                    Spacer()
                }
                .padding(16)
            case .image(let data, _):
                if let image = NSImage(data: data) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .padding(20)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.system(size: 38, weight: .light))
                        Text(L10n.tr("图片无法显示"))
                            .font(.callout)
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                Divider().opacity(0.35)
                HStack(spacing: 10) {
                    Button(L10n.tr("复制图片"), action: copyCurrent)
                    Button(L10n.tr("保存图片…"), action: saveCurrentImage)
                        .buttonStyle(.borderedProminent)
                    Spacer()
                }
                .padding(16)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 80, height: 1)

            toolbarButton("chevron.left", help: L10n.tr("上一个二维码")) {
                selectedIndex = (selectedIndex - 1 + result.observations.count)
                    % result.observations.count
            }
            .disabled(result.observations.count < 2)
            toolbarButton("chevron.right", help: L10n.tr("下一个二维码")) {
                selectedIndex = (selectedIndex + 1) % result.observations.count
            }
            .disabled(result.observations.count < 2)

            toolbarDivider

            toolbarButton("minus.magnifyingglass", help: L10n.tr("缩小")) {
                zoomMultiplier = max(0.35, zoomMultiplier / 1.25)
            }
            toolbarButton("plus.magnifyingglass", help: L10n.tr("放大")) {
                zoomMultiplier = min(5, zoomMultiplier * 1.25)
            }
            toolbarButton("rectangle.center.inset.filled", help: L10n.tr("适合窗口")) {
                zoomMultiplier = 1
            }

            toolbarDivider

            toolbarButton("doc.on.doc", help: L10n.tr("复制当前结果"), action: copyCurrent)
            if case .url = selectedObservation.payload {
                toolbarButton("arrow.up.right.square", help: L10n.tr("打开地址"), action: openCurrentURL)
            }
            if case .image = selectedObservation.payload {
                toolbarButton("square.and.arrow.down", help: L10n.tr("保存图片"), action: saveCurrentImage)
            }

            Spacer(minLength: 12)

            toolbarButton(
                "pin",
                help: isPinned ? L10n.tr("取消窗口置顶") : L10n.tr("窗口置顶"),
                tint: isPinned ? Color(nsColor: .systemGreen) : .secondary
            ) {
                isPinned.toggle()
                window?.level = isPinned ? .floating : .normal
                showStatus(isPinned ? L10n.tr("窗口已置顶") : L10n.tr("已取消置顶"))
            }
            .padding(.trailing, 8)
        }
        .frame(height: 40)
        .background(Color(nsColor: NSColor(calibratedWhite: 0.23, alpha: 1)))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.055)).frame(height: 1)
        }
    }

    private var payloadSymbol: String {
        switch selectedObservation.payload {
        case .text: return "text.alignleft"
        case .url: return "link"
        case .image: return "photo"
        }
    }

    private func toolbarButton(
        _ symbol: String,
        help: String,
        tint: Color = .secondary,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16.5, weight: .regular))
                .foregroundStyle(tint)
                .frame(width: 42, height: 38)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(help)
    }

    private var toolbarDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(width: 1, height: 24)
            .padding(.horizontal, 7)
    }

    private func copyCurrent() {
        let pasteboard = NSPasteboard.general
        switch selectedObservation.payload {
        case .text, .url:
            pasteboard.clearContents()
            guard pasteboard.setString(editableText, forType: .string) else {
                NSSound.beep()
                return
            }
            showStatus(L10n.tr("已复制"))
        case .image(let data, _):
            guard let image = NSImage(data: data),
                  writeScreenshotImageToPasteboard(image) else {
                NSSound.beep()
                return
            }
            showStatus(L10n.tr("图片已复制"))
        }
    }

    private func openCurrentURL() {
        guard let url = URL(string: editableText),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host?.isEmpty == false else {
            showStatus(L10n.tr("网址格式无效"))
            NSSound.beep()
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func saveCurrentImage() {
        guard case let .image(data, mimeType) = selectedObservation.payload,
              let window else {
            return
        }
        let filenameExtension: String = switch mimeType?.lowercased() {
        case "image/jpeg": "jpg"
        case "image/gif": "gif"
        case "image/heic", "image/heif": "heic"
        case "image/tiff": "tiff"
        case "image/webp": "webp"
        default: "png"
        }
        let contentType = UTType(filenameExtension: filenameExtension) ?? .png
        let panel = NSSavePanel()
        panel.allowedContentTypes = [contentType]
        panel.nameFieldStringValue = "PEEK_QR_Image.\(contentType.preferredFilenameExtension ?? "png")"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url, options: .atomic)
                showStatus(L10n.tr("图片已保存"))
            } catch {
                NSSound.beep()
                showStatus(L10n.tr("保存失败：%@", error.localizedDescription))
            }
        }
    }

    private func showStatus(_ message: String) {
        withAnimation(.easeOut(duration: 0.16)) { statusMessage = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if statusMessage == message {
                withAnimation(.easeIn(duration: 0.16)) { statusMessage = "" }
            }
        }
    }
}

private struct PEEKQRCodeSourceCanvas: View {
    let image: NSImage
    let observations: [PEEKQRCodeObservation]
    let selectedObservationID: UUID
    let zoomMultiplier: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let imageSize = CGSize(
                width: max(1, image.size.width),
                height: max(1, image.size.height)
            )
            let available = proxy.size
            let fitScale = min(
                available.width / imageSize.width,
                available.height / imageSize.height
            ) * zoomMultiplier
            let renderedSize = CGSize(
                width: imageSize.width * fitScale,
                height: imageSize.height * fitScale
            )
            let origin = CGPoint(
                x: (available.width - renderedSize.width) / 2,
                y: (available.height - renderedSize.height) / 2
            )

            ZStack(alignment: .topLeading) {
                Color(nsColor: NSColor(calibratedWhite: 0.115, alpha: 1))
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: renderedSize.width, height: renderedSize.height)
                    .position(
                        x: origin.x + renderedSize.width / 2,
                        y: origin.y + renderedSize.height / 2
                    )

                ForEach(observations) { observation in
                    let box = observation.normalizedBoundingBox
                    let rect = CGRect(
                        x: origin.x + box.minX * renderedSize.width,
                        y: origin.y + (1 - box.maxY) * renderedSize.height,
                        width: box.width * renderedSize.width,
                        height: box.height * renderedSize.height
                    )
                    Rectangle()
                        .stroke(
                            observation.id == selectedObservationID
                                ? Color(nsColor: .systemGreen)
                                : Color.white.opacity(0.55),
                            lineWidth: observation.id == selectedObservationID ? 2 : 1
                        )
                        .frame(width: max(2, rect.width), height: max(2, rect.height))
                        .position(x: rect.midX, y: rect.midY)
                }
            }
            .clipped()
        }
    }
}
