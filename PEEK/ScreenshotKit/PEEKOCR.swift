import AppKit
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import Vision

struct PEEKOCRObservation: Identifiable, Sendable {
    let id: UUID
    let text: String
    let confidence: Float

    /// Vision normalized coordinates: origin is at the image's lower-left, values are 0...1.
    let normalizedBoundingBox: CGRect

    /// Converts the Vision bounding box into image coordinates.
    /// With `topLeftOrigin == true`, the returned rectangle is directly usable by most editors.
    func rect(in imageSize: CGSize, topLeftOrigin: Bool = true) -> CGRect {
        var rect = VNImageRectForNormalizedRect(
            normalizedBoundingBox,
            Int(imageSize.width.rounded()),
            Int(imageSize.height.rounded())
        )
        if topLeftOrigin {
            rect.origin.y = imageSize.height - rect.maxY
        }
        return rect
    }
}

struct PEEKOCRResult: Sendable {
    let text: String
    let observations: [PEEKOCRObservation]
    let imageSize: CGSize
    let recognitionLanguages: [String]

    var plainText: String {
        observations.map(\.text).joined(separator: "\n")
    }
}

/// Rebuilds a readable monospaced layout from Vision's text rectangles. Vision
/// does not expose fonts or syntax colors, but its geometry is sufficient to
/// preserve rows, blank lines, indentation and side-by-side columns.
struct PEEKOCRLayoutFormatter {
    private struct Fragment {
        let text: String
        let rect: CGRect
    }

    private struct Row {
        var fragments: [Fragment]

        var minY: CGFloat { fragments.map(\.rect.minY).min() ?? 0 }
        var maxY: CGFloat { fragments.map(\.rect.maxY).max() ?? 0 }
        var midY: CGFloat { (minY + maxY) / 2 }
        var height: CGFloat { max(1, maxY - minY) }
    }

    static func formattedText(
        observations: [PEEKOCRObservation],
        imageSize: CGSize
    ) -> String {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return observations.map(\.text).joined(separator: "\n")
        }

        let fragments = observations.flatMap { observation -> [Fragment] in
            let sourceRect = observation.rect(in: imageSize, topLeftOrigin: true)
            let lines = observation.text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
            guard lines.count > 1 else {
                let text = observation.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? [] : [Fragment(text: text, rect: sourceRect)]
            }

            let lineHeight = sourceRect.height / CGFloat(lines.count)
            return lines.enumerated().compactMap { index, line in
                let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return Fragment(
                    text: text,
                    rect: CGRect(
                        x: sourceRect.minX,
                        y: sourceRect.minY + CGFloat(index) * lineHeight,
                        width: sourceRect.width,
                        height: lineHeight
                    )
                )
            }
        }
        guard !fragments.isEmpty else { return "" }

        var rows: [Row] = []
        for fragment in fragments.sorted(by: fragmentReadingOrder) {
            let candidateIndex = rows.indices
                .filter { rowIndex in
                    let row = rows[rowIndex]
                    let tolerance = max(row.height, fragment.rect.height) * 0.52
                    return abs(row.midY - fragment.rect.midY) <= tolerance
                }
                .min { lhs, rhs in
                    abs(rows[lhs].midY - fragment.rect.midY)
                        < abs(rows[rhs].midY - fragment.rect.midY)
                }
            if let candidateIndex {
                rows[candidateIndex].fragments.append(fragment)
            } else {
                rows.append(Row(fragments: [fragment]))
            }
        }
        rows.sort { $0.minY < $1.minY }

        let estimatedCharacterWidths = fragments.compactMap { fragment -> CGFloat? in
            let columns = displayColumnCount(fragment.text)
            guard columns > 0, fragment.rect.width > 1 else { return nil }
            return fragment.rect.width / CGFloat(columns)
        }.filter { $0.isFinite && $0 > 0.5 }
        let fallbackCharacterWidth = max(4, imageSize.width / 120)
        let characterWidth = max(
            1,
            median(estimatedCharacterWidths) ?? fallbackCharacterWidth
        )
        let medianRowHeight = median(rows.map(\.height)) ?? max(1, imageSize.height / 40)
        let leftEdge = fragments.map(\.rect.minX).min() ?? 0

        var outputLines: [String] = []
        var previousRow: Row?
        for row in rows {
            if let previousRow {
                let gap = row.minY - previousRow.maxY
                if gap > medianRowHeight * 1.55 {
                    outputLines.append("")
                }
                if gap > medianRowHeight * 3.1 {
                    outputLines.append("")
                }
            }

            let orderedFragments = row.fragments.sorted { $0.rect.minX < $1.rect.minX }
            guard let first = orderedFragments.first else { continue }
            let leadingColumns = clampedSpaceCount(
                Int(((first.rect.minX - leftEdge) / characterWidth).rounded()),
                maximum: 120
            )
            var line = String(repeating: " ", count: leadingColumns) + first.text
            var previousRect = first.rect

            for fragment in orderedFragments.dropFirst() {
                let pixelGap = max(0, fragment.rect.minX - previousRect.maxX)
                let spaces = max(
                    1,
                    clampedSpaceCount(
                        Int((pixelGap / characterWidth).rounded()),
                        maximum: 80
                    )
                )
                line += String(repeating: " ", count: spaces) + fragment.text
                previousRect = fragment.rect
            }
            outputLines.append(line.trimmingCharacters(in: .newlines))
            previousRow = row
        }

        return outputLines.joined(separator: "\n")
    }

    static func richTextData(_ text: String) -> Data? {
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
                .foregroundColor: NSColor.labelColor
            ]
        )
        return try? attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
    }

    private static func fragmentReadingOrder(_ lhs: Fragment, _ rhs: Fragment) -> Bool {
        let tolerance = max(lhs.rect.height, rhs.rect.height) * 0.52
        if abs(lhs.rect.midY - rhs.rect.midY) <= tolerance {
            return lhs.rect.minX < rhs.rect.minX
        }
        return lhs.rect.minY < rhs.rect.minY
    }

    private static func displayColumnCount(_ text: String) -> Int {
        text.unicodeScalars.reduce(into: 0) { count, scalar in
            if scalar.value <= 0x7F {
                count += scalar == "\t" ? 4 : 1
            } else {
                count += 2
            }
        }
    }

    private static func clampedSpaceCount(_ value: Int, maximum: Int) -> Int {
        min(max(0, value), maximum)
    }

    private static func median(_ values: [CGFloat]) -> CGFloat? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }
}

struct PEEKOCROptions: Sendable {
    enum RecognitionLevel: Sendable {
        case fast
        case accurate
    }

    var recognitionLevel: RecognitionLevel = .accurate
    var recognitionLanguages: [String] = ["zh-Hans", "zh-Hant", "en-US"]
    var usesLanguageCorrection = true
    var automaticallyDetectsLanguage = true
    var customWords: [String] = []
    var minimumTextHeight: Float = 0
    var regionOfInterest: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)

    init() {}
}

enum PEEKOCRError: LocalizedError {
    case imageConversionFailed
    case noTextRecognized
    case imageTooLarge(width: Int, height: Int)

    var errorDescription: String? {
        switch self {
        case .imageConversionFailed:
            return L10n.tr("无法读取图片像素数据")
        case .noTextRecognized:
            return L10n.tr("图片中没有识别到文字")
        case let .imageTooLarge(width, height):
            return L10n.tr("图片过大（%d×%d 像素），请截取较小区域后重试 OCR", width, height)
        }
    }
}

private struct PEEKOCRWorkerInput: @unchecked Sendable {
    let image: CGImage
    let orientation: CGImagePropertyOrientation
}

/// Vision requests are synchronous. Keeping them on a dedicated actor avoids
/// blocking AppKit without transferring `NSImage`, Vision requests or mutable
/// service state through an unstructured detached task.
private actor PEEKOCRWorker {
    func recognize(
        input: PEEKOCRWorkerInput,
        options: PEEKOCROptions
    ) throws -> PEEKOCRResult {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = options.recognitionLevel == .accurate ? .accurate : .fast
        request.recognitionLanguages = options.recognitionLanguages
        request.usesLanguageCorrection = options.usesLanguageCorrection
        request.customWords = options.customWords
        request.minimumTextHeight = max(0, min(options.minimumTextHeight, 1))
        request.regionOfInterest = PEEKOCRService.clampedRegion(options.regionOfInterest)
        request.automaticallyDetectsLanguage = options.automaticallyDetectsLanguage

        let handler = VNImageRequestHandler(
            cgImage: input.image,
            orientation: input.orientation,
            options: [:]
        )
        try handler.perform([request])

        let recognized = (request.results ?? []).compactMap { observation -> PEEKOCRObservation? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return PEEKOCRObservation(
                id: UUID(),
                text: candidate.string,
                confidence: candidate.confidence,
                normalizedBoundingBox: observation.boundingBox
            )
        }
        let sorted = PEEKOCRService.readingOrder(recognized)
        guard !sorted.isEmpty else { throw PEEKOCRError.noTextRecognized }

        let imageSize = CGSize(width: input.image.width, height: input.image.height)
        return PEEKOCRResult(
            text: PEEKOCRLayoutFormatter.formattedText(
                observations: sorted,
                imageSize: imageSize
            ),
            observations: sorted,
            imageSize: imageSize,
            recognitionLanguages: request.recognitionLanguages
        )
    }
}

/// Local OCR backed only by Apple's Vision framework. No image or text leaves the Mac.
final class PEEKOCRService: Sendable {
    private let worker = PEEKOCRWorker()

    @MainActor
    func recognize(
        image: NSImage,
        options: PEEKOCROptions = PEEKOCROptions()
    ) async throws -> PEEKOCRResult {
        guard let imageSource = Self.makeImageSource(from: image) else {
            throw PEEKOCRError.imageConversionFailed
        }
        let width = imageSource.image.width
        let height = imageSource.image.height
        let (pixelCount, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixelCount <= 40_000_000, width <= 20_000, height <= 40_000 else {
            throw PEEKOCRError.imageTooLarge(width: width, height: height)
        }

        return try await worker.recognize(
            input: PEEKOCRWorkerInput(
                image: imageSource.image,
                orientation: imageSource.orientation
            ),
            options: options
        )
    }

    @MainActor
    func recognize(
        fileURL: URL,
        options: PEEKOCROptions = PEEKOCROptions()
    ) async throws -> PEEKOCRResult {
        guard let image = NSImage(contentsOf: fileURL) else {
            throw PEEKOCRError.imageConversionFailed
        }
        return try await recognize(image: image, options: options)
    }

    private static func makeImageSource(from image: NSImage) -> (image: CGImage, orientation: CGImagePropertyOrientation)? {
        var proposedRect = NSRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
            return nil
        }
        return (cgImage, .up)
    }

    fileprivate nonisolated static func clampedRegion(_ region: CGRect) -> CGRect {
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let intersection = region.standardized.intersection(unit)
        return intersection.isNull || intersection.isEmpty ? unit : intersection
    }

    /// Vision commonly returns observations in reading order, but this makes the contract stable.
    /// Rows within 35% of their average glyph height are treated as the same line.
    fileprivate nonisolated static func readingOrder(
        _ observations: [PEEKOCRObservation]
    ) -> [PEEKOCRObservation] {
        observations.sorted { lhs, rhs in
            let rowTolerance = max(lhs.normalizedBoundingBox.height, rhs.normalizedBoundingBox.height) * 0.35
            let verticalDifference = abs(lhs.normalizedBoundingBox.midY - rhs.normalizedBoundingBox.midY)
            if verticalDifference <= rowTolerance {
                return lhs.normalizedBoundingBox.minX < rhs.normalizedBoundingBox.minX
            }
            return lhs.normalizedBoundingBox.midY > rhs.normalizedBoundingBox.midY
        }
    }
}

/// Retains OCR result windows so callers can simply call `present`.
@MainActor
final class PEEKOCRResultPresenter {
    static let shared = PEEKOCRResultPresenter()

    private var controllers: [UUID: PEEKOCRResultWindowController] = [:]

    @discardableResult
    func present(
        result: PEEKOCRResult,
        image: NSImage? = nil,
        title: String = L10n.tr("OCR 识别结果")
    ) -> UUID {
        let id = UUID()
        let controller = PEEKOCRResultWindowController(
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

    func close(id: UUID) {
        controllers[id]?.close()
    }

    func closeAll() {
        Array(controllers.values).forEach { $0.close() }
    }
}

@MainActor
private final class PEEKOCRResultWindowController: NSWindowController, NSWindowDelegate {
    private let onClose: () -> Void
    private var didNotifyClose = false

    init(
        result: PEEKOCRResult,
        image: NSImage?,
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
        window.backgroundColor = .windowBackgroundColor
        window.minSize = NSSize(width: 860, height: 420)
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(
            rootView: PEEKOCRResultView(
                result: result,
                sourceImage: image,
                window: window
            )
        )
    }

    required init?(coder: NSCoder) {
        nil
    }

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

private struct PEEKOCRResultView: View {
    let result: PEEKOCRResult
    weak var window: NSWindow?

    @State private var editableText: String
    @State private var sourceImage: NSImage?
    @State private var statusMessage = ""
    @State private var zoomMultiplier: CGFloat = 1
    @State private var rotationQuarterTurns = 0
    @State private var showsTextRegions = true
    @State private var preservesLayout = true
    @State private var selectedObservationID: UUID?
    @State private var isPinned = false

    init(result: PEEKOCRResult, sourceImage: NSImage?, window: NSWindow) {
        self.result = result
        self.window = window
        _editableText = State(initialValue: result.text)
        _sourceImage = State(initialValue: sourceImage)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            HSplitView {
                Group {
                    if let sourceImage {
                        PEEKOCRImageCanvas(
                            image: sourceImage,
                            observations: result.observations,
                            selectedObservationID: selectedObservationID,
                            showsTextRegions: showsTextRegions,
                            zoomMultiplier: zoomMultiplier,
                            rotationQuarterTurns: rotationQuarterTurns
                        )
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "photo")
                                .font(.system(size: 42, weight: .light))
                            Text(L10n.tr("原图不可用"))
                                .font(.callout)
                        }
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .underPageBackgroundColor))

                TextEditor(text: $editableText)
                    .font(.system(size: 16, weight: .regular, design: .monospaced))
                    .foregroundColor(Color(nsColor: .labelColor))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 20)
                    .frame(minWidth: 260, idealWidth: 282, maxWidth: 310, maxHeight: .infinity)
                    .background(Color(nsColor: .controlBackgroundColor))
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottomTrailing) {
            if !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(14)
                    .transition(.opacity)
            }
        }
        .frame(minWidth: 860, minHeight: 420)
        .ignoresSafeArea(.container, edges: .top)
    }

    private var toolbar: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 80, height: 1)

            toolbarButton("chevron.left", help: L10n.tr("上一个文本区域")) {
                moveSelection(by: -1)
            }
            toolbarButton("chevron.right", help: L10n.tr("下一个文本区域")) {
                moveSelection(by: 1)
            }

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

            toolbarButton("rectangle.on.rectangle.angled", help: L10n.tr("向左旋转")) {
                rotationQuarterTurns = (rotationQuarterTurns + 3) % 4
            }
            toolbarButton(
                "square.and.pencil",
                help: showsTextRegions ? L10n.tr("隐藏文本区域") : L10n.tr("显示文本区域"),
                tint: showsTextRegions ? .primary : .secondary
            ) {
                showsTextRegions.toggle()
            }

            toolbarDivider

            toolbarButton(
                "character.book.closed",
                help: preservesLayout ? L10n.tr("切换为普通文本") : L10n.tr("恢复原始排版"),
                tint: preservesLayout ? .primary : .secondary
            ) {
                preservesLayout.toggle()
                editableText = preservesLayout ? result.text : result.plainText
                showStatus(preservesLayout ? L10n.tr("已恢复原始排版") : L10n.tr("已切换普通文本"))
            }
            toolbarButton(
                "viewfinder",
                help: L10n.tr("重新生成版式"),
                tint: Color(nsColor: .systemGreen)
            ) {
                preservesLayout = true
                selectedObservationID = nil
                showsTextRegions = true
                editableText = result.text
                showStatus(L10n.tr("已重新生成版式"))
            }

            toolbarDivider

            toolbarButton("square.and.arrow.down", help: L10n.tr("导出文本")) {
                saveText(preferRichText: false)
            }

            Spacer(minLength: 12)

            Menu {
                Button(L10n.tr("复制保留版式文本"), action: copyAll)
                Button(L10n.tr("复制普通文本")) { copy(result.plainText) }
                Divider()
                Button(L10n.tr("导出 TXT")) { saveText(preferRichText: false) }
                Button(L10n.tr("导出 RTF")) { saveText(preferRichText: true) }
                Divider()
                Button(showsTextRegions ? L10n.tr("隐藏文本区域") : L10n.tr("显示文本区域")) {
                    showsTextRegions.toggle()
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 42, height: 38)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .focusable(false)
            .foregroundStyle(.secondary)
            .help(L10n.tr("更多"))

            toolbarDivider

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
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 1)
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
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1, height: 24)
            .padding(.horizontal, 7)
    }

    private func moveSelection(by offset: Int) {
        guard !result.observations.isEmpty else { return }
        let current = selectedObservationID.flatMap { id in
            result.observations.firstIndex { $0.id == id }
        }
        let next: Int
        if let current {
            next = min(max(0, current + offset), result.observations.count - 1)
        } else {
            next = offset < 0 ? result.observations.count - 1 : 0
        }
        selectedObservationID = result.observations[next].id
        showsTextRegions = true
    }

    private func copyAll() {
        copy(editableText)
    }

    private func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let copiedPlainText = pasteboard.setString(text, forType: .string)
        if let richText = PEEKOCRLayoutFormatter.richTextData(text) {
            pasteboard.setData(richText, forType: .rtf)
        }
        if copiedPlainText {
            showStatus(L10n.tr("已复制"))
        } else {
            showStatus(L10n.tr("复制失败"))
        }
    }

    private func saveText(preferRichText: Bool) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText, .rtf]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = preferRichText ? "PEEK_OCR.rtf" : "PEEK_OCR.txt"

        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                if url.pathExtension.lowercased() == "rtf" {
                    guard let data = PEEKOCRLayoutFormatter.richTextData(editableText) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    try data.write(to: url, options: .atomic)
                } else {
                    try editableText.write(to: url, atomically: true, encoding: .utf8)
                }
                showStatus(L10n.tr("已保存"))
            } catch {
                showStatus(L10n.tr("保存失败：%@", error.localizedDescription))
            }
        }

        if let window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }

    private func showStatus(_ message: String) {
        withAnimation(.easeOut(duration: 0.16)) {
            statusMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            guard statusMessage == message else { return }
            withAnimation(.easeIn(duration: 0.16)) {
                statusMessage = ""
            }
        }
    }
}

private struct PEEKOCRImageCanvas: View {
    let image: NSImage
    let observations: [PEEKOCRObservation]
    let selectedObservationID: UUID?
    let showsTextRegions: Bool
    let zoomMultiplier: CGFloat
    let rotationQuarterTurns: Int

    var body: some View {
        GeometryReader { proxy in
            let imageSize = normalizedImageSize
            let isSideways = rotationQuarterTurns.isMultiple(of: 2) == false
            let orientedSize = isSideways
                ? CGSize(width: imageSize.height, height: imageSize.width)
                : imageSize
            let fitScale = min(
                max(0.01, (proxy.size.width - 28) / max(1, orientedSize.width)),
                max(0.01, (proxy.size.height - 28) / max(1, orientedSize.height))
            )
            let scale = max(0.01, fitScale * zoomMultiplier)
            let innerSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
            let renderedSize = CGSize(
                width: orientedSize.width * scale,
                height: orientedSize.height * scale
            )

            ScrollView([.horizontal, .vertical]) {
                ZStack {
                    ZStack(alignment: .topLeading) {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: innerSize.width, height: innerSize.height)

                        if showsTextRegions, let highlightRect {
                            let rect = CGRect(
                                x: highlightRect.minX * scale,
                                y: highlightRect.minY * scale,
                                width: highlightRect.width * scale,
                                height: highlightRect.height * scale
                            )
                            Rectangle()
                                .fill(Color(nsColor: .systemGreen).opacity(0.12))
                                .overlay {
                                    Rectangle()
                                        .stroke(
                                            Color(nsColor: .systemGreen).opacity(0.76),
                                            lineWidth: max(1, 1.5 / max(scale, 0.01))
                                        )
                                }
                                .frame(width: rect.width, height: rect.height)
                                .offset(x: rect.minX, y: rect.minY)
                        }
                    }
                    .frame(width: innerSize.width, height: innerSize.height)
                    .rotationEffect(.degrees(Double(rotationQuarterTurns) * -90))
                    .frame(width: renderedSize.width, height: renderedSize.height)
                }
                .frame(
                    minWidth: proxy.size.width,
                    minHeight: proxy.size.height,
                    alignment: .center
                )
            }
            .scrollIndicators(.visible)
        }
    }

    private var normalizedImageSize: CGSize {
        CGSize(width: max(1, image.size.width), height: max(1, image.size.height))
    }

    private var highlightRect: CGRect? {
        let rects: [CGRect]
        if let selectedObservationID,
           let selected = observations.first(where: { $0.id == selectedObservationID }) {
            rects = [selected.rect(in: normalizedImageSize, topLeftOrigin: true)]
        } else {
            rects = observations.map { $0.rect(in: normalizedImageSize, topLeftOrigin: true) }
        }
        guard var union = rects.first else { return nil }
        for rect in rects.dropFirst() {
            union = union.union(rect)
        }
        return union.intersection(
            CGRect(origin: .zero, size: normalizedImageSize)
        )
    }
}
