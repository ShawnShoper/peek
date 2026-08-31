import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Immutable work item handed to the rendering actor. AppKit image and color
/// objects are copied before crossing the actor boundary and are only read by
/// the worker. Keeping the unchecked conformance in this small wrapper avoids
/// spreading concurrency exceptions throughout the editor.
struct ScreenshotAnnotationRenderWork: @unchecked Sendable {
    let baseImage: NSImage
    let annotations: [ScreenshotAnnotation]
}

/// Carries the rendered AppKit image together with the immutable CGImage used
/// for background encoding. Both values are created and then treated as
/// immutable for the remainder of the export operation.
struct ScreenshotRenderedImage: @unchecked Sendable {
    let image: NSImage
    let cgImage: CGImage
}

struct ScreenshotEncodedPayloads: Sendable {
    let png: Data
    let tiff: Data?
}

actor ScreenshotAnnotationRenderWorker {
    static let shared = ScreenshotAnnotationRenderWorker()

    func render(_ work: ScreenshotAnnotationRenderWork) throws -> ScreenshotRenderedImage {
        try Task.checkCancellation()
        // Most captures are copied without annotations. Reuse the immutable
        // backing pixels instead of allocating and redrawing another full-size
        // bitmap (especially important for long scrolling captures).
        if work.annotations.isEmpty,
           let cgImage = highestResolutionCGImage(from: work.baseImage) {
            return ScreenshotRenderedImage(image: work.baseImage, cgImage: cgImage)
        }
        guard let image = ScreenshotAnnotationRenderer.render(
            baseImage: work.baseImage,
            annotations: work.annotations
        ) else {
            throw ScreenshotCaptureError.imageRenderingFailed
        }
        try Task.checkCancellation()
        // `NSImage.size` is expressed in logical points. Supplying that rect to
        // `NSImage.cgImage(forProposedRect:)` rasterizes a Retina screenshot at
        // 1x and silently discards half of its pixels. The renderer already
        // owns a full-resolution bitmap representation, so export that backing
        // image directly and fall back to an unscaled representation request.
        guard let cgImage = highestResolutionCGImage(from: image) else {
            throw ScreenshotCaptureError.imageRenderingFailed
        }
        return ScreenshotRenderedImage(image: image, cgImage: cgImage)
    }

    private func highestResolutionCGImage(from image: NSImage) -> CGImage? {
        let bestRepresentation = image.representations.max {
            $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh
        }
        return (bestRepresentation as? NSBitmapImageRep)?.cgImage
            ?? bestRepresentation?.cgImage(
                forProposedRect: nil,
                context: nil,
                hints: nil
            )
            ?? image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}

/// ImageIO encoding and file I/O are intentionally isolated from MainActor.
/// Large screenshots can take hundreds of milliseconds to encode; keeping the
/// work here leaves global shortcuts, menus and editor interaction responsive.
actor ScreenshotImageEncodingWorker {
    static let shared = ScreenshotImageEncodingWorker()
    static let maximumTIFFPixelCount = 16_000_000

    func encodeClipboardPayloads(from image: CGImage) throws -> ScreenshotEncodedPayloads {
        try Task.checkCancellation()
        let png = try encodedData(from: image, type: .png)
        try Task.checkCancellation()
        // TIFF is useful for compatibility but often much larger than PNG. Do
        // not materialize a second full payload for large/long screenshots.
        let tiff = Self.shouldEncodeTIFF(
            pixelWidth: image.width,
            pixelHeight: image.height
        ) ? try? encodedData(from: image, type: .tiff) : nil
        return ScreenshotEncodedPayloads(png: png, tiff: tiff)
    }

    func writePNG(_ image: CGImage, to url: URL) throws {
        try Task.checkCancellation()
        let fileManager = FileManager.default
        let temporaryURL = url.deletingLastPathComponent().appendingPathComponent(
            ".PEEK-(UUID().uuidString)-(url.lastPathComponent).partial"
        )
        defer { try? fileManager.removeItem(at: temporaryURL) }

        guard let destination = CGImageDestinationCreateWithURL(
            temporaryURL as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw ScreenshotCaptureError.imageRenderingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ScreenshotCaptureError.imageRenderingFailed
        }
        try Task.checkCancellation()
        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(url, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: url)
        }
    }

    nonisolated static func shouldEncodeTIFF(
        pixelWidth: Int,
        pixelHeight: Int
    ) -> Bool {
        guard pixelWidth > 0, pixelHeight > 0,
              pixelWidth <= Int.max / pixelHeight else {
            return false
        }
        return pixelWidth * pixelHeight <= maximumTIFFPixelCount
    }

    private func encodedData(from image: CGImage, type: UTType) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            type.identifier as CFString,
            1,
            nil
        ) else {
            throw ScreenshotCaptureError.imageRenderingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ScreenshotCaptureError.imageRenderingFailed
        }
        return data as Data
    }
}

@MainActor
func screenshotRenderWork(
    baseImage: NSImage,
    document: ScreenshotAnnotationDocument
) -> ScreenshotAnnotationRenderWork {
    ScreenshotAnnotationRenderWork(
        baseImage: (baseImage.copy() as? NSImage) ?? baseImage,
        annotations: document.annotations
    )
}

@MainActor
func writeScreenshotPayloadsToPasteboard(
    _ payloads: ScreenshotEncodedPayloads,
    pasteboard: NSPasteboard = .general
) -> Bool {
    var values: [(NSPasteboard.PasteboardType, Data)] = [(.png, payloads.png)]
    if let tiff = payloads.tiff {
        values.append((.tiff, tiff))
    }
    pasteboard.clearContents()
    pasteboard.declareTypes(values.map(\.0), owner: nil)
    return values.reduce(false) { wroteAny, value in
        pasteboard.setData(value.1, forType: value.0) || wroteAny
    }
}
