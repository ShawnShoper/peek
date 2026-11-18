import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A bounded text snapshot used by the clipboard panel. Clipboard payloads can
/// be tens of megabytes, so the UI never turns the complete payload into one
/// Swift `String` merely to draw a preview.
struct ClipboardHistoryTextPreview: Equatable, Sendable {
    let text: String
    let loadedByteCount: Int
    let totalByteCount: Int

    var isTruncated: Bool { loadedByteCount < totalByteCount }
}

struct ClipboardHistoryFilePreviewItem: Identifiable, Equatable, Sendable {
    let url: URL
    let displayName: String
    let parentPath: String
    let kindDescription: String
    let isDirectory: Bool
    let fileSize: Int64?
    let modifiedAt: Date?
    let isAvailable: Bool

    var id: String { url.standardizedFileURL.path }
}

struct ClipboardHistoryFolderEntry: Identifiable, Equatable, Sendable {
    let url: URL
    let displayName: String
    let isDirectory: Bool

    var id: String { url.standardizedFileURL.path }
}

struct ClipboardHistoryFolderPreview: Equatable, Sendable {
    let entries: [ClipboardHistoryFolderEntry]
    /// Exact for small folders; otherwise a lower bound discovered by the
    /// bounded enumerator before it stopped.
    let totalItemCount: Int
    let isTotalItemCountExact: Bool

    var isTruncated: Bool {
        !isTotalItemCountExact || entries.count < totalItemCount
    }
}

/// Core Graphics images are immutable for the lifetime of this value. Wrapping
/// the reference lets image decoding and PDF rendering finish away from the
/// main actor while AppKit conversion remains on the UI actor.
struct ClipboardHistoryPreviewBitmap: @unchecked Sendable {
    let image: CGImage
    let pixelWidth: Int
    let pixelHeight: Int
    let pageCount: Int?
}

enum ClipboardHistoryPayloadPreview: Sendable {
    case text(ClipboardHistoryTextPreview)
    case bitmap(ClipboardHistoryPreviewBitmap)
    case link(URL)
    case unavailable(String)
}

enum ClipboardHistoryPreviewLoader {
    static let maximumTextPreviewBytes = 256 * 1_024
    static let maximumFolderEntries = 80
    static let maximumFileURLs = ClipboardHistoryLimits.maximumFileURLCount
    private static let maximumBitmapDimension = 1_600

    static func payloadPreview(
        record: ClipboardHistoryRecord,
        payload: ClipboardPayloadEnvelope
    ) -> ClipboardHistoryPayloadPreview {
        switch record.kind {
        case .image:
            guard let data = payload.representations.first?.data,
                  let bitmap = imagePreview(data: data) else {
                return .unavailable(L10n.tr("无法读取图片预览"))
            }
            return .bitmap(bitmap)
        case .pdf:
            guard let data = payload.data(
                forType: NSPasteboard.PasteboardType.pdf.rawValue
            ), let bitmap = pdfPreview(data: data) else {
                return .unavailable(L10n.tr("没有可用的文件预览"))
            }
            return .bitmap(bitmap)
        case .link:
            guard let url = linkURL(record: record, payload: payload) else {
                return .unavailable(L10n.tr("当前剪贴板内容类型暂不支持"))
            }
            return .link(url)
        case .text, .richText:
            return .text(textPreview(payload: payload, fallback: record.title))
        case .files:
            return .unavailable(L10n.tr("没有可用的文件预览"))
        }
    }

    static func inspectFiles(_ urls: [URL]) -> [ClipboardHistoryFilePreviewItem] {
        guard !Task.isCancelled else { return [] }
        return urls.prefix(maximumFileURLs).compactMap { url in
            guard !Task.isCancelled else { return nil }
            let keys: Set<URLResourceKey> = [
                .isDirectoryKey,
                .fileSizeKey,
                .contentModificationDateKey,
            ]
            let values = try? url.resourceValues(forKeys: keys)
            var isDirectoryValue: ObjCBool = false
            let exists = FileManager.default.fileExists(
                atPath: url.path,
                isDirectory: &isDirectoryValue
            )
            let isDirectory = values?.isDirectory ?? isDirectoryValue.boolValue
            let kindDescription: String
            if isDirectory {
                kindDescription = L10n.tr("文件夹")
            } else {
                kindDescription = UTType(filenameExtension: url.pathExtension)?
                    .localizedDescription ?? L10n.tr("文件")
            }
            return ClipboardHistoryFilePreviewItem(
                url: url,
                displayName: url.lastPathComponent,
                parentPath: url.deletingLastPathComponent().path,
                kindDescription: kindDescription,
                isDirectory: isDirectory,
                fileSize: values?.fileSize.map(Int64.init),
                modifiedAt: values?.contentModificationDate,
                isAvailable: exists
            )
        }
    }

    /// Only HTTP(S) links receive an offline card. File URLs and custom
    /// schemes are rejected before the user can hand them to another app.
    static func linkURL(
        record: ClipboardHistoryRecord,
        payload: ClipboardPayloadEnvelope
    ) -> URL? {
        let preview = readableText(payload: payload, byteLimit: maximumTextPreviewBytes)
        guard preview?.isTruncated != true else { return nil }
        let value = preview?.text ?? record.title
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count <= 8_192,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = url.host,
              !host.isEmpty else { return nil }
        return url
    }

    static func textFilePreview(at url: URL) -> SearchPanelTextPreview? {
        SearchPanelTextPreviewLoader.load(at: url)
    }

    static func folderPreview(at url: URL) -> ClipboardHistoryFolderPreview? {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isHiddenKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants],
            errorHandler: { _, _ in true }
        ) else { return nil }

        // Enumerate only enough direct children to fill the card and prove that
        // more content exists. This bounds both metadata I/O and memory even for
        // folders containing hundreds of thousands of files.
        var inspected: [(url: URL, isDirectory: Bool)] = []
        inspected.reserveCapacity(maximumFolderEntries)
        var discoveredCount = 0
        var isCountExact = true
        while let childURL = enumerator.nextObject() as? URL {
            guard !Task.isCancelled else { return nil }
            discoveredCount += 1
            guard inspected.count < maximumFolderEntries else {
                isCountExact = false
                break
            }
            let isDirectory = (try? childURL.resourceValues(
                forKeys: [.isDirectoryKey]
            ))?.isDirectory ?? false
            inspected.append((childURL, isDirectory))
        }

        inspected.sort { left, right in
            if left.isDirectory != right.isDirectory { return left.isDirectory }
            return left.url.lastPathComponent.localizedStandardCompare(
                right.url.lastPathComponent
            ) == .orderedAscending
        }
        let entries = inspected.map { entry in
            ClipboardHistoryFolderEntry(
                url: entry.url,
                displayName: entry.url.lastPathComponent,
                isDirectory: entry.isDirectory
            )
        }
        return ClipboardHistoryFolderPreview(
            entries: entries,
            totalItemCount: discoveredCount,
            isTotalItemCountExact: isCountExact
        )
    }

    private static func textPreview(
        payload: ClipboardPayloadEnvelope,
        fallback: String
    ) -> ClipboardHistoryTextPreview {
        if let preview = readableText(payload: payload, byteLimit: maximumTextPreviewBytes) {
            return preview
        }
        let bytes = fallback.utf8.count
        return ClipboardHistoryTextPreview(text: fallback, loadedByteCount: bytes, totalByteCount: bytes)
    }

    // Counts and titles use the complete storable representation. Opening an
    // old or new record reads only a preview-sized prefix into the decoder.
    static func readableText(payload: ClipboardPayloadEnvelope, byteLimit: Int) -> ClipboardHistoryTextPreview? {
        var emptyPreview: ClipboardHistoryTextPreview?
        for type: NSPasteboard.PasteboardType in [.string, .rtf, .html] {
            guard let data = payload.data(forType: type.rawValue) else { continue }
            let prefix = Data(data.prefix(byteLimit))
            let decoded: String?
            switch type {
            case .rtf:
                decoded = rtfText(prefix, isTruncated: prefix.count < data.count)
            case .html:
                decoded = htmlText(prefix)
            default:
                decoded = decodeText(prefix)
            }
            guard let decoded else { continue }
            let preview = ClipboardHistoryTextPreview(text: decoded, loadedByteCount: prefix.count, totalByteCount: data.count)
            if !decoded.isEmpty { return preview }
            emptyPreview = preview
        }
        return emptyPreview
    }

    private static func rtfText(_ prefix: Data, isTruncated: Bool) -> String? {
        if !isTruncated {
            return NSAttributedString(rtf: prefix, documentAttributes: nil)?.string
        }
        // The AppKit importer needs balanced groups, even for a text preview.
        // Closing a copy of the prefix keeps the original rich data intact.
        var boundedRTF = prefix
        var depth = 0
        var escaped = false
        for byte in prefix {
            if escaped { escaped = false; continue }
            switch byte {
            case 0x5C: escaped = true
            case 0x7B: depth += 1
            case 0x7D: depth = max(0, depth - 1)
            default: break
            }
        }
        if escaped { boundedRTF.removeLast() }
        boundedRTF.append(Data(repeating: 0x7D, count: depth))
        return NSAttributedString(rtf: boundedRTF, documentAttributes: nil)?.string
    }

    private static let htmlBlocks: Set<String> = [
        "address", "article", "aside", "blockquote", "dd", "div", "dl", "dt", "figure",
        "figcaption", "footer", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr",
        "li", "main", "nav", "ol", "p", "pre", "section", "table", "tr", "ul"
    ]
    private static let excludedHTML: Set<String> = ["head", "script", "style", "noscript", "iframe", "template", "object"]

    private static func htmlText(_ data: Data) -> String? {
        let options: XMLNode.Options = [.documentTidyHTML, .nodeLoadExternalEntitiesNever]
        let document: XMLDocument?
        if let utf8 = decodeUTF8Prefix(data) {
            document = try? XMLDocument(xmlString: utf8, options: options)
        } else {
            document = try? XMLDocument(data: data, options: options)
        }
        guard let root = document?.rootElement() else { return nil }
        var text = ""
        func collect(_ node: XMLNode) {
            if node.kind == .text {
                if let value = node.stringValue {
                    text += value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                }
                return
            }
            guard let element = node as? XMLElement else { return }
            let tag = element.localName?.lowercased() ?? ""
            guard !excludedHTML.contains(tag), element.attribute(forName: "hidden") == nil else { return }
            if tag == "br" { text += "\n"; return }
            let isBlock = htmlBlocks.contains(tag)
            if isBlock { text += "\n" }
            for child in element.children ?? [] { collect(child) }
            if isBlock { text += "\n" }
            if tag == "td" || tag == "th" { text += " " }
        }
        collect(root)
        return text
            .replacingOccurrences(of: #" *\n[ \n]*"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #" {2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeText(_ data: Data) -> String? {
        decodeUTF8Prefix(data) ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .isoLatin1)
    }

    private static func decodeUTF8Prefix(_ data: Data) -> String? {
        if let text = String(data: data, encoding: .utf8) { return text }
        // The byte limit can split a UTF-8 scalar. Only remove the incomplete
        // suffix; do not fall back to an encoding that would produce mojibake.
        for trailingByteCount in 1 ... min(3, data.count) {
            if let text = String(
                data: data.dropLast(trailingByteCount),
                encoding: .utf8
            ) {
                return text
            }
        }
        return nil
    }

    private static func imagePreview(data: Data) -> ClipboardHistoryPreviewBitmap? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any]
        let pixelWidth = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let pixelHeight = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumBitmapDimension,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else { return nil }
        return ClipboardHistoryPreviewBitmap(
            image: image,
            pixelWidth: pixelWidth > 0 ? pixelWidth : image.width,
            pixelHeight: pixelHeight > 0 ? pixelHeight : image.height,
            pageCount: nil
        )
    }

    private static func pdfPreview(data: Data) -> ClipboardHistoryPreviewBitmap? {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider),
              let page = document.page(at: 1) else { return nil }
        let pageRect = page.getBoxRect(.mediaBox)
        guard pageRect.width > 0, pageRect.height > 0 else { return nil }
        let scale = min(
            CGFloat(maximumBitmapDimension) / pageRect.width,
            CGFloat(maximumBitmapDimension) / pageRect.height,
            2
        )
        let width = max(1, Int((pageRect.width * scale).rounded()))
        let height = max(1, Int((pageRect.height * scale).rounded()))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -pageRect.minX, y: -pageRect.minY)
        context.drawPDFPage(page)
        context.restoreGState()
        guard let image = context.makeImage() else { return nil }
        return ClipboardHistoryPreviewBitmap(
            image: image,
            pixelWidth: width,
            pixelHeight: height,
            pageCount: document.numberOfPages
        )
    }
}
