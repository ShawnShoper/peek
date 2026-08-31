import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import PEEK

final class ScreenshotOutputPipelineTests: XCTestCase {
    func testBackgroundEncoderProducesDecodableClipboardPayloads() async throws {
        let image = try XCTUnwrap(makeImage(width: 24, height: 16))

        let payloads = try await ScreenshotImageEncodingWorker.shared
            .encodeClipboardPayloads(from: image)

        XCTAssertEqual(imageType(for: payloads.png), UTType.png.identifier)
        let tiff = try XCTUnwrap(payloads.tiff)
        XCTAssertEqual(imageType(for: tiff), UTType.tiff.identifier)
    }

    func testLargeClipboardPayloadSkipsSecondFullSizeTIFFEncoding() {
        XCTAssertTrue(
            ScreenshotImageEncodingWorker.shouldEncodeTIFF(
                pixelWidth: 4_000,
                pixelHeight: 4_000
            )
        )
        XCTAssertFalse(
            ScreenshotImageEncodingWorker.shouldEncodeTIFF(
                pixelWidth: 4_001,
                pixelHeight: 4_000
            )
        )
        XCTAssertFalse(
            ScreenshotImageEncodingWorker.shouldEncodeTIFF(
                pixelWidth: Int.max,
                pixelHeight: 2
            )
        )
    }

    func testPNGWriterStreamsToTemporaryFileAndAtomicallyReplacesDestination() async throws {
        let image = try XCTUnwrap(makeImage(width: 24, height: 16))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PEEK-ScreenshotOutputTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("capture.png")
        try Data("old payload".utf8).write(to: destination)

        try await ScreenshotImageEncodingWorker.shared.writePNG(image, to: destination)

        let data = try Data(contentsOf: destination)
        XCTAssertEqual(imageType(for: data), UTType.png.identifier)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).contains { $0.lastPathComponent.hasSuffix(".partial") }
        )
    }

    @MainActor
    func testRenderWorkerPreservesFullResolutionDimensions() async throws {
        let source = try XCTUnwrap(makeImage(width: 48, height: 32))
        let image = NSImage(cgImage: source, size: NSSize(width: 24, height: 16))
        let document = ScreenshotAnnotationDocument(baseImage: image)
        let work = screenshotRenderWork(baseImage: image, document: document)

        let rendered = try await ScreenshotAnnotationRenderWorker.shared.render(work)

        XCTAssertEqual(rendered.cgImage.width, 48)
        XCTAssertEqual(rendered.cgImage.height, 32)
    }

    private func makeImage(width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.setFillColor(CGColor(red: 0.18, green: 0.52, blue: 0.86, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private func imageType(for data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        return CGImageSourceGetType(source) as String?
    }
}
