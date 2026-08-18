import CoreGraphics
import Foundation

/// 纵向拼接器。纯像素入口不依赖窗口或屏幕 API，便于对行序、接缝和尺寸上限做测试。
struct VerticalImageStitcher: Sendable {
    func stitch(
        images: [CGImage],
        overlaps: [Int],
        limits: ScrollStitchLimits = .init()
    ) throws -> CGImage {
        let buffers = try images.map(ScrollPixelBuffer.init(cgImage:))
        return try stitch(pixelBuffers: buffers, overlaps: overlaps, limits: limits).makeCGImage()
    }

    func stitch(
        pixelBuffers: [ScrollPixelBuffer],
        overlaps: [Int],
        limits: ScrollStitchLimits = .init()
    ) throws -> ScrollPixelBuffer {
        try limits.validate()
        guard let first = pixelBuffers.first else {
            throw ScrollCaptureError.emptyCapture
        }
        guard overlaps.count == max(0, pixelBuffers.count - 1) else {
            throw ScrollCaptureError.overlapCountMismatch
        }

        var outputHeight = first.height
        for index in pixelBuffers.indices.dropFirst() {
            let frame = pixelBuffers[index]
            guard frame.width == first.width,
                  frame.height == first.height else {
                throw ScrollCaptureError.incompatibleFrames
            }
            let overlap = overlaps[index - 1]
            guard overlap >= 0, overlap < frame.height else {
                throw ScrollCaptureError.overlapCountMismatch
            }
            let (newHeight, overflow) = outputHeight.addingReportingOverflow(frame.height - overlap)
            guard !overflow else {
                throw ScrollCaptureError.outputTooLarge(width: first.width, height: .max)
            }
            outputHeight = newHeight
        }

        let (pixelCount, pixelOverflow) = first.width.multipliedReportingOverflow(by: outputHeight)
        guard !pixelOverflow,
              outputHeight <= limits.maximumOutputHeightPixels,
              pixelCount <= limits.maximumOutputPixels else {
            throw ScrollCaptureError.outputTooLarge(width: first.width, height: outputHeight)
        }

        let outputBytesPerRow = first.width * 4
        let (outputByteCount, byteOverflow) = outputBytesPerRow.multipliedReportingOverflow(
            by: outputHeight
        )
        guard !byteOverflow else {
            throw ScrollCaptureError.outputTooLarge(width: first.width, height: outputHeight)
        }

        var outputData = Data(count: outputByteCount)
        try outputData.withUnsafeMutableBytes { outputRawBuffer in
            guard let outputBase = outputRawBuffer.baseAddress else {
                throw ScrollCaptureError.invalidPixelBuffer
            }

            var destinationRow = 0
            for index in pixelBuffers.indices {
                let frame = pixelBuffers[index]
                let sourceStartRow = index == 0 ? 0 : overlaps[index - 1]
                let rowsToCopy = frame.height - sourceStartRow

                try frame.rgbaData.withUnsafeBytes { sourceRawBuffer in
                    guard let sourceBase = sourceRawBuffer.baseAddress else {
                        throw ScrollCaptureError.invalidPixelBuffer
                    }
                    for sourceRow in sourceStartRow ..< frame.height {
                        let sourceOffset = sourceRow * frame.bytesPerRow
                        let destinationOffset = destinationRow * outputBytesPerRow
                        outputBase
                            .advanced(by: destinationOffset)
                            .copyMemory(
                                from: sourceBase.advanced(by: sourceOffset),
                                byteCount: outputBytesPerRow
                            )
                        destinationRow += 1
                    }
                }

                assert(rowsToCopy >= 0)
            }
            assert(destinationRow == outputHeight)
        }

        return try ScrollPixelBuffer(
            width: first.width,
            height: outputHeight,
            bytesPerRow: outputBytesPerRow,
            rgbaData: outputData
        )
    }
}
