import CoreGraphics
import Foundation

/// 像素缓冲区中的整数矩形，原点位于左上角。
struct ScrollPixelRect: Sendable, Equatable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int

    var maxX: Int { x + width }
    var maxY: Int { y + height }

    static func full(width: Int, height: Int) -> ScrollPixelRect {
        ScrollPixelRect(x: 0, y: 0, width: width, height: height)
    }
}

/// 可测试的纯像素表示。数据按从上到下的 RGBA8 行序排列。
struct ScrollPixelBuffer: Sendable, Equatable {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let rgbaData: Data

    init(width: Int, height: Int, bytesPerRow: Int? = nil, rgbaData: Data) throws {
        let (minimumRowBytes, rowOverflow) = width.multipliedReportingOverflow(by: 4)
        guard !rowOverflow else { throw ScrollCaptureError.invalidPixelBuffer }
        let resolvedBytesPerRow = bytesPerRow ?? minimumRowBytes
        let (minimumDataCount, dataOverflow) = resolvedBytesPerRow.multipliedReportingOverflow(by: height)
        guard width > 0,
              height > 0,
              !dataOverflow,
              resolvedBytesPerRow >= minimumRowBytes,
              rgbaData.count >= minimumDataCount else {
            throw ScrollCaptureError.invalidPixelBuffer
        }

        self.width = width
        self.height = height
        self.bytesPerRow = resolvedBytesPerRow
        self.rgbaData = rgbaData
    }

    init(cgImage: CGImage) throws {
        let width = cgImage.width
        let height = cgImage.height
        let (bytesPerRow, rowOverflow) = width.multipliedReportingOverflow(by: 4)
        let (byteCount, dataOverflow) = bytesPerRow.multipliedReportingOverflow(by: height)
        guard width > 0, height > 0, !rowOverflow, !dataOverflow else {
            throw ScrollCaptureError.invalidPixelBuffer
        }

        var data = Data(count: byteCount)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue

        let rendered = data.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress,
                  let context = CGContext(
                      data: baseAddress,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: bytesPerRow,
                      space: colorSpace,
                      bitmapInfo: bitmapInfo
                  ) else {
                return false
            }

            // CGBitmapContext 的内存首行与 CGImage 数据提供者的首行一致。
            // 不翻转坐标可保持 RGBA 数据在 CGImage 往返转换后的行序不变。
            context.interpolationQuality = .none
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }

        guard rendered else {
            throw ScrollCaptureError.bitmapContextCreationFailed
        }
        try self.init(width: width, height: height, bytesPerRow: bytesPerRow, rgbaData: data)
    }

    func makeCGImage() throws -> CGImage {
        guard let provider = CGDataProvider(data: rgbaData as CFData) else {
            throw ScrollCaptureError.imageCreationFailed
        }
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue
        )
        guard let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            throw ScrollCaptureError.imageCreationFailed
        }
        return image
    }

    func cropped(to rect: ScrollPixelRect) throws -> ScrollPixelBuffer {
        guard rect.x >= 0,
              rect.y >= 0,
              rect.width > 0,
              rect.height > 0,
              rect.maxX <= width,
              rect.maxY <= height else {
            throw ScrollCaptureError.invalidPixelBuffer
        }
        if rect == .full(width: width, height: height) {
            return self
        }

        let outputBytesPerRow = rect.width * 4
        var output = Data(count: outputBytesPerRow * rect.height)
        try output.withUnsafeMutableBytes { outputRawBuffer in
            try rgbaData.withUnsafeBytes { sourceRawBuffer in
                guard let outputBase = outputRawBuffer.baseAddress,
                      let sourceBase = sourceRawBuffer.baseAddress else {
                    throw ScrollCaptureError.invalidPixelBuffer
                }
                for row in 0 ..< rect.height {
                    let sourceOffset = (rect.y + row) * bytesPerRow + rect.x * 4
                    let destinationOffset = row * outputBytesPerRow
                    outputBase.advanced(by: destinationOffset).copyMemory(
                        from: sourceBase.advanced(by: sourceOffset),
                        byteCount: outputBytesPerRow
                    )
                }
            }
        }
        return try ScrollPixelBuffer(
            width: rect.width,
            height: rect.height,
            bytesPerRow: outputBytesPerRow,
            rgbaData: output
        )
    }
}
