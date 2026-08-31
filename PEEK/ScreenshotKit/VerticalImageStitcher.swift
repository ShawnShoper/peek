import CoreGraphics
import Foundation

/// 纵向拼接器。纯像素入口不依赖窗口或屏幕 API，便于对行序、接缝和尺寸上限做测试。
struct VerticalImageStitcher: Sendable {
    func stitch(
        images: [CGImage],
        overlaps: [Int],
        limits: ScrollStitchLimits = .init()
    ) throws -> CGImage {
        try Task.checkCancellation()
        var buffers: [ScrollPixelBuffer] = []
        buffers.reserveCapacity(images.count)
        for (index, image) in images.enumerated() {
            if index.isMultiple(of: 4) {
                try Task.checkCancellation()
            }
            buffers.append(try ScrollPixelBuffer(cgImage: image))
        }
        return try stitch(pixelBuffers: buffers, overlaps: overlaps, limits: limits).makeCGImage()
    }

    func stitch(
        pixelBuffers: [ScrollPixelBuffer],
        overlaps: [Int],
        fixedOverlayRectsByFrame: [[ScrollPixelRect]] = [],
        limits: ScrollStitchLimits = .init()
    ) throws -> ScrollPixelBuffer {
        try Task.checkCancellation()
        try limits.validate()
        guard let first = pixelBuffers.first else {
            throw ScrollCaptureError.emptyCapture
        }
        guard overlaps.count == max(0, pixelBuffers.count - 1) else {
            throw ScrollCaptureError.overlapCountMismatch
        }
        guard fixedOverlayRectsByFrame.isEmpty
                || fixedOverlayRectsByFrame.count == pixelBuffers.count else {
            throw ScrollCaptureError.incompatibleFrames
        }

        let overlayRects = fixedOverlayRectsByFrame.isEmpty
            ? Array(repeating: [], count: pixelBuffers.count)
            : fixedOverlayRectsByFrame

        var outputHeight = first.height
        for index in pixelBuffers.indices.dropFirst() {
            if index.isMultiple(of: 8) {
                try Task.checkCancellation()
            }
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

        try Task.checkCancellation()
        var outputData = Data(count: outputByteCount)
        try outputData.withUnsafeMutableBytes { outputRawBuffer in
            guard let outputBase = outputRawBuffer.baseAddress else {
                throw ScrollCaptureError.invalidPixelBuffer
            }

            var destinationRow = 0
            var destinationStartRows: [Int] = []
            var sourceStartRows: [Int] = []
            destinationStartRows.reserveCapacity(pixelBuffers.count)
            sourceStartRows.reserveCapacity(pixelBuffers.count)
            for index in pixelBuffers.indices {
                let frame = pixelBuffers[index]
                let sourceStartRow = index == 0 ? 0 : overlaps[index - 1]
                let rowsToCopy = frame.height - sourceStartRow
                destinationStartRows.append(destinationRow)
                sourceStartRows.append(sourceStartRow)

                try frame.rgbaData.withUnsafeBytes { sourceRawBuffer in
                    guard let sourceBase = sourceRawBuffer.baseAddress else {
                        throw ScrollCaptureError.invalidPixelBuffer
                    }
                    for sourceRow in sourceStartRow ..< frame.height {
                        if sourceRow.isMultiple(of: 64) {
                            try Task.checkCancellation()
                        }
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

            // Repair fixed overlays directly in the final output. The former
            // implementation copied every affected full frame before copying
            // it again into `outputData`, which could nearly double the input
            // memory of long captures containing a floating toolbar.
            try repairRepeatedFixedOverlays(
                outputBase: outputBase,
                outputBytesPerRow: outputBytesPerRow,
                frames: pixelBuffers,
                overlaps: overlaps,
                fixedOverlayRectsByFrame: overlayRects,
                destinationStartRows: destinationStartRows,
                sourceStartRows: sourceStartRows
            )
        }

        try Task.checkCancellation()
        return try ScrollPixelBuffer(
            width: first.width,
            height: outputHeight,
            bytesPerRow: outputBytesPerRow,
            rgbaData: outputData
        )
    }

    /// Replaces an earlier occurrence of a fixed floating control with the
    /// same document pixels after they have moved clear of that control in the
    /// following frame. The last viewport is intentionally left untouched, so
    /// a real control can appear at most once at the bottom of the final image.
    private func repairRepeatedFixedOverlays(
        outputBase: UnsafeMutableRawPointer,
        outputBytesPerRow: Int,
        frames: [ScrollPixelBuffer],
        overlaps: [Int],
        fixedOverlayRectsByFrame: [[ScrollPixelRect]],
        destinationStartRows: [Int],
        sourceStartRows: [Int]
    ) throws {
        guard frames.count >= 2,
              fixedOverlayRectsByFrame.contains(where: { !$0.isEmpty }) else {
            return
        }

        for index in 0 ..< (frames.count - 1) {
            try Task.checkCancellation()
            let frame = frames[index]
            let next = frames[index + 1]
            let displacement = next.height - overlaps[index]
            guard displacement > 0 else { continue }

            try next.rgbaData.withUnsafeBytes { sourceRaw in
                guard let source = sourceRaw.baseAddress else {
                    throw ScrollCaptureError.invalidPixelBuffer
                }
                for rect in fixedOverlayRectsByFrame[index] {
                    let sourceRect = ScrollPixelRect(
                        x: rect.x,
                        y: rect.y - displacement,
                        width: rect.width,
                        height: rect.height
                    )
                    guard rect.x >= 0,
                          rect.y >= 0,
                          rect.maxX <= frame.width,
                          rect.maxY <= frame.height,
                          sourceRect.y >= 0,
                          sourceRect.maxX <= next.width,
                          sourceRect.maxY <= next.height,
                          !fixedOverlayRectsByFrame[index + 1].contains(where: {
                              intersects($0, sourceRect)
                          }) else {
                        continue
                    }

                    for row in 0 ..< rect.height {
                        if row.isMultiple(of: 64) {
                            try Task.checkCancellation()
                        }
                        let destinationFrameRow = rect.y + row
                        // Rows in a later frame's overlap were intentionally
                        // discarded and therefore have no output destination.
                        guard destinationFrameRow >= sourceStartRows[index] else {
                            continue
                        }
                        let destinationOutputRow = destinationStartRows[index]
                            + destinationFrameRow - sourceStartRows[index]
                        let destinationOffset = destinationOutputRow * outputBytesPerRow
                            + rect.x * 4
                        let sourceOffset = (sourceRect.y + row) * next.bytesPerRow
                            + sourceRect.x * 4
                        outputBase.advanced(by: destinationOffset).copyMemory(
                            from: source.advanced(by: sourceOffset),
                            byteCount: rect.width * 4
                        )
                    }
                }
            }
        }
    }

    private func intersects(_ first: ScrollPixelRect, _ second: ScrollPixelRect) -> Bool {
        first.x < second.maxX
            && second.x < first.maxX
            && first.y < second.maxY
            && second.y < first.maxY
    }
}
